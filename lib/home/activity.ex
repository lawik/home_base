defmodule Home.Activity do
  @moduledoc """
  When each capability was last active, and how. Records, doesn't interpret.

  Capabilities emit events with `emit/4`; they go to PubSub `"activity"`. Every node keeps
  the latest event per `{cap, kind}` and a bounded ring of recent ones, last writer (by
  `ts`) wins. A node asks peers for a snapshot when they come up.

  Rate limits are per `{cap, kind, event}`: by default `:input` events at most one per
  250 ms, `:display` `:frame` and `:level` one per second; everything else (start/stop,
  lease events) is never throttled. An adapter can set its own with `throttle: ms`.
  Throttling coalesces rather than drops: the first event of a burst goes out at once,
  the last one goes out when the interval is up, so the final state is never lost. Any
  number of processes may emit for the same key. If this server goes down (a crash or a
  shutdown, not a `:kill`), whatever it holds back is sent on the way out.
  """

  use GenServer

  defmodule Event do
    @moduledoc false
    @enforce_keys [:cap, :kind, :event, :ts, :mono]
    defstruct [:cap, :kind, :event, :ts, :mono, :area, data: %{}]

    @type t :: %__MODULE__{
            cap: Home.Capability.ref(),
            kind: atom(),
            event: atom(),
            ts: integer(),
            mono: integer(),
            area: String.t() | nil,
            data: map()
          }
  end

  @topic "activity"
  @last __MODULE__.Last
  @throttle __MODULE__.Throttle
  @ring 64

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Emit an event for a capability on this node. `cap` is a `{node, id}` ref or the
  `Home.Capability` struct an adapter gets in `init/1`. Options: `throttle: ms` overrides
  the default rate limit for this `{cap, kind, event}` (0 disables it).

  Returns `:ok`, or `:throttled` if the event was held back; a held-back event is sent
  when the interval is up unless a newer one replaces it first.

      Home.Activity.emit(cap, :input, :touch, %{session: nil})
      Home.Activity.emit(cap, :audio_in, :level, %{session: pid, level_db: -32.0})
  """
  def emit(cap, kind, event, data \\ %{}, opts \\ []) do
    cap = ref(cap)

    ev = %Event{
      cap: cap,
      kind: kind,
      event: event,
      ts: System.system_time(:millisecond),
      mono: System.monotonic_time(:millisecond),
      area: Home.Registry.area(),
      data: data
    }

    key = {cap, kind, event}

    case Keyword.get_lazy(opts, :throttle, fn -> min_interval(kind, event) end) do
      0 -> publish(ev)
      interval -> throttle(key, ev, interval)
    end
  end

  defp ref(%Home.Capability{id: id}), do: {node(), id}
  defp ref({node, _id} = ref) when is_atom(node), do: ref

  defp publish(ev), do: Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:activity, ev})

  # @throttle rows: {key, mono of the last publish, held-back event or nil, version}.
  # Emitters of the same key race each other and the flush, so every change is a
  # compare-and-swap on the version: whoever loses looks again. Exactly one emitter
  # turns "nothing held back" into "held back" per interval, and that one schedules the
  # flush; at most one event goes out per interval.
  defp throttle(key, ev, interval) do
    case :ets.lookup(@throttle, key) do
      [] ->
        if :ets.insert_new(@throttle, {key, ev.mono, nil, 0}),
          do: publish(ev),
          else: throttle(key, ev, interval)

      [{_, at, pending, v}] when ev.mono - at < interval ->
        if swap(key, v, {key, at, ev, v + 1}) do
          if is_nil(pending),
            do: Process.send_after(__MODULE__, {:flush, key, at}, at + interval - ev.mono)

          :throttled
        else
          throttle(key, ev, interval)
        end

      # The interval is up: this event goes out now (and replaces any held-back one,
      # whose flush then finds nothing to do).
      [{_, _at, _pending, v}] ->
        if swap(key, v, {key, ev.mono, nil, v + 1}),
          do: publish(ev),
          else: throttle(key, ev, interval)
    end
  rescue
    # Activity is restarting and its table is gone: don't hold anything back.
    ArgumentError -> publish(ev)
  end

  defp swap(key, version, row),
    do: :ets.select_replace(@throttle, [{{key, :_, :_, version}, [], [{:const, row}]}]) == 1

  # Send the held-back event for `key` if it is still held back since the publish at `at`.
  defp flush(key, at) do
    case :ets.lookup(@throttle, key) do
      [{_, ^at, %Event{} = ev, v}] ->
        if swap(key, v, {key, System.monotonic_time(:millisecond), nil, v + 1}),
          do: publish(ev),
          else: flush(key, at)

      _ ->
        :ok
    end
  end

  @doc "Latest event for `{cap, kind}`, or nil."
  def last(cap, kind) do
    case :ets.lookup(@last, {cap, kind}) do
      [{_, ev, _ring}] -> ev
      [] -> nil
    end
  end

  @doc """
  Latest event per cap for `kind:`, optionally scoped by `area:` (the event's area).
  Most recent first.
  """
  def last(filters) when is_list(filters) do
    kind = Keyword.fetch!(filters, :kind)
    area = Keyword.get(filters, :area)

    for({{_cap, ^kind}, ev, _} <- :ets.tab2list(@last), is_nil(area) or ev.area == area, do: ev)
    |> Enum.sort_by(&{&1.ts, &1.mono}, :desc)
  end

  @doc "Events for `{cap, kind}` in the last `ms` milliseconds (wall clock), oldest first."
  def since(cap, kind, ms) do
    cutoff = System.system_time(:millisecond) - ms

    case :ets.lookup(@last, {cap, kind}) do
      [{_, _ev, ring}] -> ring |> :queue.to_list() |> Enum.filter(&(&1.ts >= cutoff)) |> sort()
      [] -> []
    end
  end

  @doc "Receive `{:activity, event}` for a kind or a capability ref as events arrive."
  def subscribe(kind) when is_atom(kind),
    do: Phoenix.PubSub.subscribe(Home.PubSub, "activity:kind:#{kind}")

  def subscribe({node, id}),
    do: Phoenix.PubSub.subscribe(Home.PubSub, "activity:cap:#{node}/#{id}")

  @doc "Everything this node holds: `[{{cap, kind}, latest_event, recent_events}]`, oldest first."
  def snapshot do
    for {key, ev, ring} <- :ets.tab2list(@last), do: {key, ev, sort(:queue.to_list(ring))}
  end

  ## Server

  @impl true
  def init(opts) do
    # So terminate/2 also runs on shutdown, and held-back events still go out.
    Process.flag(:trap_exit, true)
    :ets.new(@last, [:named_table, :public, read_concurrency: true])
    :ets.new(@throttle, [:named_table, :public, write_concurrency: true])
    Phoenix.PubSub.subscribe(Home.PubSub, @topic)
    :net_kernel.monitor_nodes(true)
    for peer <- Node.list(), do: ask(peer)
    {:ok, %{ring: Keyword.get(opts, :ring, @ring)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(), state}

  @impl true
  def handle_info({:activity, %Event{} = ev}, state) do
    store(ev, state)
    {node, id} = ev.cap
    Phoenix.PubSub.local_broadcast(Home.PubSub, "activity:kind:#{ev.kind}", {:activity, ev})
    Phoenix.PubSub.local_broadcast(Home.PubSub, "activity:cap:#{node}/#{id}", {:activity, ev})
    {:noreply, state}
  end

  def handle_info({:snapshot, rows}, state) do
    for {key, ev, events} <- rows do
      case :ets.lookup(@last, key) do
        [{_, mine, my_ring}] ->
          last = if mine.ts >= ev.ts, do: mine, else: ev
          events = Enum.uniq(:queue.to_list(my_ring) ++ events)
          :ets.insert(@last, {key, last, trim(events, state)})

        [] ->
          :ets.insert(@last, {key, ev, trim(events, state)})
      end
    end

    {:noreply, state}
  end

  def handle_info({:flush, key, at}, state) do
    flush(key, at)
    {:noreply, state}
  end

  def handle_info({:nodeup, peer}, state) do
    ask(peer)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Going down (crash or shutdown): the throttle table goes with us, so send what it
  # holds back now rather than lose the final value of a burst.
  @impl true
  def terminate(_reason, _state) do
    for {_key, _at, %Event{} = ev, _v} <- :ets.tab2list(@throttle), do: publish(ev)
    :ok
  end

  defp ask(peer) do
    me = self()

    Task.start(fn ->
      try do
        send(me, {:snapshot, GenServer.call({__MODULE__, peer}, :snapshot)})
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp store(ev, state) do
    key = {ev.cap, ev.kind}

    {last, ring} =
      case :ets.lookup(@last, key) do
        [{_, last, ring}] -> {last, ring}
        [] -> {nil, :queue.new()}
      end

    ring = :queue.in(ev, ring)
    ring = if :queue.len(ring) > state.ring, do: :queue.drop(ring), else: ring
    last = if is_nil(last) or ev.ts >= last.ts, do: ev, else: last
    :ets.insert(@last, {key, last, ring})
  end

  defp trim(events, state), do: events |> sort() |> Enum.take(-state.ring) |> :queue.from_list()
  defp sort(events), do: Enum.sort_by(events, &{&1.ts, &1.mono})

  defp min_interval(:input, _), do: 250
  defp min_interval(:display, :frame), do: 1_000
  defp min_interval(_, :level), do: 1_000
  defp min_interval(_, _), do: 0
end
