defmodule Home.Activity do
  @moduledoc """
  When each capability was last active, and how. Records, doesn't interpret.

  Capabilities emit events with `emit/4`; they go to PubSub `"activity"`. Every node keeps
  the latest event per `{cap, kind}` and a bounded ring of recent ones, last writer (by
  `ts`) wins. A node asks peers for a snapshot when they come up.

  Rate limits are per `{cap, kind, event}`: `:input` events at most one per 250 ms,
  `:display` `:frame` and `:level` one per second; everything else is never dropped.
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

  @doc "Emit an event for a capability on this node. Returns `:ok` or `:throttled`."
  def emit(cap, kind, event, data \\ %{}) do
    mono = System.monotonic_time(:millisecond)

    if throttled?({cap, kind, event}, min_interval(kind, event), mono) do
      :throttled
    else
      ev = %Event{
        cap: cap,
        kind: kind,
        event: event,
        ts: System.system_time(:millisecond),
        mono: mono,
        area: Home.Registry.area(),
        data: data
      }

      Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:activity, ev})
    end
  end

  @doc "Latest event for `{cap, kind}`, or nil."
  def last(cap, kind) do
    case :ets.lookup(@last, {cap, kind}) do
      [{_, ev, _ring}] -> ev
      [] -> nil
    end
  end

  @doc "Latest event per cap for `kind:`, optionally scoped by `area:` (the event's area)."
  def last(filters) when is_list(filters) do
    kind = Keyword.fetch!(filters, :kind)
    area = Keyword.get(filters, :area)

    for {{_cap, ^kind}, ev, _} <- :ets.tab2list(@last), is_nil(area) or ev.area == area, do: ev
  end

  @doc "Events for `{cap, kind}` in the last `ms` milliseconds (wall clock), oldest first."
  def since(cap, kind, ms) do
    cutoff = System.system_time(:millisecond) - ms

    case :ets.lookup(@last, {cap, kind}) do
      [{_, _ev, ring}] -> ring |> :queue.to_list() |> Enum.filter(&(&1.ts >= cutoff))
      [] -> []
    end
  end

  @doc "Receive `{:activity, event}` for a kind or a capability ref as events arrive."
  def subscribe(kind) when is_atom(kind),
    do: Phoenix.PubSub.subscribe(Home.PubSub, "activity:kind:#{kind}")

  def subscribe({node, id}),
    do: Phoenix.PubSub.subscribe(Home.PubSub, "activity:cap:#{node}/#{id}")

  def snapshot, do: :ets.tab2list(@last)

  ## Server

  @impl true
  def init(opts) do
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
    for {key, ev, ring} <- rows do
      case :ets.lookup(@last, key) do
        [{_, mine, _}] when mine.ts >= ev.ts -> :ok
        _ -> :ets.insert(@last, {key, ev, ring})
      end
    end

    {:noreply, state}
  end

  def handle_info({:nodeup, peer}, state) do
    ask(peer)
    {:noreply, state}
  end

  def handle_info({:nodedown, _}, state), do: {:noreply, state}

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

  defp min_interval(:input, _), do: 250
  defp min_interval(:display, :frame), do: 1_000
  defp min_interval(_, :level), do: 1_000
  defp min_interval(_, _), do: 0

  defp throttled?(_key, 0, _now), do: false

  defp throttled?(key, interval, now) do
    case :ets.lookup(@throttle, key) do
      [{_, at}] when now - at < interval ->
        true

      _ ->
        :ets.insert(@throttle, {key, now})
        false
    end
  end
end
