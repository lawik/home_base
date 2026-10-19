defmodule Home.Test.LossyRelay do
  @moduledoc false
  # Runs on peers: a UDP relay between a session's source and one sink that impairs the
  # media direction. Use as a session's `route:` (`{__MODULE__, :route, [opts]}`): for
  # each sink address the session asks for, a relay starts on this node, owned by the
  # session process, and the source sends to it instead. Datagrams from the sink (RTCP
  # feedback) go back to the source unimpaired unless `feedback_loss` is set.
  #
  # Impairments (all optional, changeable with `configure/2`):
  #   * `loss` - probability of dropping a media datagram;
  #   * `reorder` - probability of holding a datagram back until after the next one;
  #   * `delay` / `jitter` - ms added to every media datagram: `delay` plus uniform
  #     0..`jitter` (datagrams can overtake each other);
  #   * `feedback_loss` - probability of dropping a datagram from the sink;
  #   * `blackout: ms` (one-off, via `configure/2`) - drop everything for `ms` from now;
  #   * `stall: ms` (one-off) - hold everything for `ms`, then release it all at once.
  #
  # Relays register as `{__MODULE__, sink_port}` in `Home.Test.LossyRelay.Registry`
  # (started on demand); `configure/2` and `stats/1` take the sink port.

  use GenServer

  @registry __MODULE__.Registry

  def route({ip, port}, opts \\ []) do
    ensure_registry()
    {:ok, pid} = GenServer.start(__MODULE__, {{ip, port}, self(), opts})
    {:ok, relay_port} = GenServer.call(pid, :port)
    {{127, 0, 0, 1}, relay_port}
  end

  def configure(sink_port, opts), do: GenServer.call(whereis(sink_port), {:configure, opts})

  def stats(sink_port), do: GenServer.call(whereis(sink_port), :stats)

  def relays, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp whereis(sink_port) do
    [{pid, _}] = Registry.lookup(@registry, sink_port)
    pid
  end

  defp ensure_registry do
    case Registry.start_link(keys: :unique, name: @registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  @impl true
  def init({{_ip, port} = sink, owner, opts}) do
    {:ok, _} = Registry.register(@registry, port, nil)
    Process.monitor(owner)
    {:ok, socket} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: true])
    :rand.seed(:exsss, Keyword.get(opts, :seed, {1, 2, 3}))

    state = %{
      socket: socket,
      sink: sink,
      source: nil,
      impair: Map.new(opts),
      blackout_until: nil,
      stall_until: nil,
      stalled: [],
      held: nil,
      stats: %{
        forwarded: 0,
        dropped: 0,
        reordered: 0,
        delayed: 0,
        feedback: 0,
        feedback_dropped: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:ok, port} = :inet.port(state.socket)
    {:reply, {:ok, port}, state}
  end

  def handle_call({:configure, opts}, _from, state) do
    now = now()
    {blackout, opts} = Keyword.pop(opts, :blackout)
    {stall, opts} = Keyword.pop(opts, :stall)
    state = %{state | impair: Map.merge(state.impair, Map.new(opts))}
    state = if blackout, do: %{state | blackout_until: now + blackout}, else: state

    state =
      if stall do
        Process.send_after(self(), :release, stall)
        %{state | stall_until: now + stall}
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl true
  def handle_info({:udp, _socket, ip, port, data}, %{sink: {ip, port}} = state) do
    # Feedback from the sink.
    cond do
      state.source == nil ->
        {:noreply, state}

      chance?(state.impair[:feedback_loss]) ->
        {:noreply, count(state, :feedback_dropped)}

      true ->
        send_to(state, state.source, data)
        {:noreply, count(state, :feedback)}
    end
  end

  def handle_info({:udp, _socket, ip, port, data}, state) do
    state = %{state | source: {ip, port}}
    now = now()

    cond do
      state.blackout_until && now < state.blackout_until ->
        {:noreply, count(state, :dropped)}

      # Until the backlog is out, so nothing overtakes it.
      state.stall_until != nil ->
        {:noreply, %{state | stalled: [data | state.stalled]}}

      chance?(state.impair[:loss]) ->
        {:noreply, count(state, :dropped)}

      state.held == nil and chance?(state.impair[:reorder]) ->
        {:noreply, count(%{state | held: data}, :reordered)}

      true ->
        state = forward(state, data)

        case state.held do
          nil -> {:noreply, state}
          held -> {:noreply, forward(%{state | held: nil}, held)}
        end
    end
  end

  def handle_info({:delayed, data}, state) do
    send_to(state, state.sink, data)
    {:noreply, state}
  end

  def handle_info(:release, state) do
    for data <- Enum.reverse(state.stalled), do: send_to(state, state.sink, data)
    {:noreply, %{state | stalled: [], stall_until: nil}}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  defp forward(state, data) do
    delay = Map.get(state.impair, :delay, 0) + jitter(state.impair[:jitter])

    if delay > 0 do
      Process.send_after(self(), {:delayed, data}, delay)
      count(count(state, :delayed), :forwarded)
    else
      send_to(state, state.sink, data)
      count(state, :forwarded)
    end
  end

  defp jitter(nil), do: 0
  defp jitter(0), do: 0
  defp jitter(ms), do: :rand.uniform(ms + 1) - 1

  defp send_to(state, {ip, port}, data), do: :gen_udp.send(state.socket, ip, port, data)

  defp chance?(nil), do: false
  defp chance?(p), do: :rand.uniform() < p

  defp count(state, key), do: update_in(state.stats[key], &(&1 + 1))

  defp now, do: System.monotonic_time(:millisecond)
end
