defmodule Home.Media.Session do
  @moduledoc """
  A media session from one source capability to one or more sink capabilities (§5.2).

      {:ok, mic} = Home.Lease.acquire({a, "mic0"}, purpose: "intercom")
      {:ok, spk} = Home.Lease.acquire({b, "spk0"}, purpose: "intercom")
      {:ok, session} = Home.Media.Session.start(source: mic, sink: spk, codec: :opus)
      :ok = Home.Media.Session.stop(session)

  The session runs on the caller's node under `Home.Media.Supervisor` and becomes the
  holder of the leases it is given. Each sink node opens a UDP port from its media range
  and replies `{ip, port, ssrc}`; the source node then runs one encoder and sends RTP to
  every sink. The session monitors the pipelines, the capability servers and the caller;
  when any of them goes, or a lease expires or is revoked, it stops both sides and
  releases the leases (an `:on_request` mic turns off). Leases are renewed while it runs.

  If the session can't be set up, `start/1` returns `{:error, reason}`; leases already
  handed over to it are released.

  Options:

    * `:source` - lease on an `:audio_in` capability.
    * `:sink` or `:sinks` - lease(s) on `:audio_out` capabilities.
    * `:codec` - only `:opus`.
    * `:owner` - the session stops when this process exits. Default: the caller.
    * `:renew_every` - ms between lease renewals, default 30 s.
    * `:jitter` - receiver jitter buffer in ms, default 40.
    * `:bitrate` - Opus bitrate, default 64 kbps.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Home.Lease

  @call_timeout 15_000

  def start(opts) do
    ref = make_ref()
    opts = opts |> Keyword.put_new(:owner, self()) |> Keyword.put(:reply_to, {self(), ref})

    with {:ok, pid} <- DynamicSupervisor.start_child(Home.Media.Supervisor, {__MODULE__, opts}) do
      mref = Process.monitor(pid)

      receive do
        {^ref, :ok} ->
          Process.demonitor(mref, [:flush])
          {:ok, pid}

        {^ref, {:error, reason}} ->
          Process.demonitor(mref, [:flush])
          {:error, reason}

        {:DOWN, ^mref, :process, _, reason} ->
          {:error, reason}
      end
    else
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Stop the session and release its leases."
  def stop(session) do
    GenServer.stop(session, :normal, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  def info(session), do: GenServer.call(session, :info)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    sinks = List.wrap(opts[:sinks] || opts[:sink])

    case check(opts, sinks) do
      :ok ->
        state = %{
          source: Keyword.fetch!(opts, :source),
          sinks: sinks,
          ssrc: Enum.random(1..0xFFFFFFFF),
          monitors: %{Process.monitor(Keyword.fetch!(opts, :owner)) => :owner},
          taken: [],
          pipelines: [],
          destinations: [],
          opts: opts
        }

        # Setup calls into Home.Media.Supervisor, possibly on this node: not from init.
        {:ok, state, {:continue, :setup}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_continue(:setup, state) do
    {reply_to, ref} = state.opts[:reply_to]

    with {:ok, state} <- take_leases(state),
         {:ok, state} <- start_sinks(state),
         {:ok, state} <- start_source(state) do
      Process.send_after(self(), :renew, renew_every(state))
      send(reply_to, {ref, :ok})
      {:noreply, state}
    else
      {:error, reason, state} ->
        send(reply_to, {ref, {:error, reason}})
        {:stop, {:shutdown, reason}, state}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    reply = %{
      source: state.source.cap,
      sinks: Enum.map(state.sinks, & &1.cap),
      destinations: state.destinations,
      ssrc: state.ssrc,
      pipelines: state.pipelines
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
    case Map.fetch(state.monitors, mref) do
      {:ok, what} -> {:stop, {:shutdown, {:down, what, reason}}, state}
      :error -> {:noreply, state}
    end
  end

  def handle_info(:renew, state) do
    case Enum.find(state.taken, &(renew(&1) != :ok)) do
      nil ->
        Process.send_after(self(), :renew, renew_every(state))
        {:noreply, state}

      lease ->
        {:stop, {:shutdown, {:renew_failed, lease.cap}}, state}
    end
  end

  def handle_info({event, ref}, state) when event in [:lease_expired, :lease_revoked] do
    case Enum.find(state.taken, &(&1.ref == ref)) do
      nil -> {:noreply, state}
      lease -> {:stop, {:shutdown, {event, lease.cap}}, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    unless reason == :normal, do: Logger.info("media session ended: #{inspect(reason)}")

    # Source first (it was started last) so the mic stops producing, then the sinks, then
    # the leases.
    for {_cap, pipeline} <- state.pipelines do
      try do
        Membrane.Pipeline.terminate(pipeline, force?: true, timeout: 2_000)
      catch
        _, _ -> :ok
      end
    end

    Enum.each(state.taken, &Lease.release/1)
  end

  ## Setup

  defp check(opts, sinks) do
    cond do
      Keyword.get(opts, :codec, :opus) != :opus -> {:error, :unsupported_codec}
      sinks == [] -> {:error, :no_sink}
      true -> :ok
    end
  end

  defp take_leases(state) do
    Enum.reduce_while([state.source | state.sinks], {:ok, state}, fn lease, {:ok, state} ->
      case Lease.handover(lease, self()) do
        {:ok, lease} ->
          monitors =
            Map.put(state.monitors, Process.monitor(lease.server), {:capability, lease.cap})

          {:cont, {:ok, %{state | taken: state.taken ++ [lease], monitors: monitors}}}

        {:error, reason} ->
          {:halt, {:error, {reason, lease.cap}, state}}
      end
    end)
  catch
    :exit, reason -> {:error, {:handover_failed, reason}, state}
  end

  defp start_sinks(state) do
    [_source | sinks] = state.taken

    Enum.reduce_while(sinks, {:ok, state}, fn lease, {:ok, state} ->
      opts = %{
        ssrc: state.ssrc,
        session: self(),
        cap: lease.cap,
        jitter: Keyword.get(state.opts, :jitter, 40)
      }

      case remote(lease, :start_sink, [lease.endpoint, opts]) do
        {:ok, pipeline, {ip, port, _ssrc}} ->
          state = add_pipeline(state, lease, pipeline)
          {:cont, {:ok, %{state | destinations: state.destinations ++ [{ip, port}]}}}

        {:error, reason} ->
          {:halt, {:error, {:sink_failed, lease.cap, reason}, state}}
      end
    end)
  end

  defp start_source(state) do
    [lease | _sinks] = state.taken

    opts = %{
      ssrc: state.ssrc,
      session: self(),
      cap: lease.cap,
      bitrate: Keyword.get(state.opts, :bitrate, 64_000)
    }

    case remote(lease, :start_source, [lease.endpoint, state.destinations, opts]) do
      {:ok, pipeline} -> {:ok, add_pipeline(state, lease, pipeline)}
      {:error, reason} -> {:error, {:source_failed, lease.cap, reason}, state}
    end
  end

  defp remote(lease, fun, args) do
    :erpc.call(node(lease.server), Home.Media, fun, args, @call_timeout)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp add_pipeline(state, lease, pipeline) do
    monitors = Map.put(state.monitors, Process.monitor(pipeline), {:pipeline, lease.cap})
    %{state | monitors: monitors, pipelines: [{lease.cap, pipeline} | state.pipelines]}
  end

  defp renew_every(state), do: Keyword.get(state.opts, :renew_every, 30_000)

  defp renew(lease) do
    Lease.renew(lease)
  catch
    :exit, _ -> {:error, :gone}
  end
end
