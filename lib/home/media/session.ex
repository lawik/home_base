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

  Sinks can be added to and removed from a running session (`add_sink/2`,
  `remove_sink/2`): the source keeps its one encoder and gains or loses a destination.

  RTCP runs alongside the RTP (see `Home.Media.RTCP`): sinks report loss and jitter and
  NACK lost packets, which the source resends; a video sink that lost a frame asks for a
  keyframe. `stats/1` collects what both ends know.

  Video is the same with `codec: :h264` (§5.2, §6.3): the source is a `:video_in` lease
  and the sinks are `:display` leases, whose endpoint (the display's compositor) shows
  the frames on the video element `surface: {render_session, target}` (see
  `Home.Render.show_video/2`). The source can also be a Membrane source element to run
  on this node instead of a lease, e.g. a `Home.Media.FrameSource` for pixel forwarding.

  Before a video session starts anything it negotiates its stream (`Home.Media.Video`):
  a profile, size, frame rate and bitrate the source can make and every sink can decode,
  in hardware where the sink has it. If there is none, `start/1` returns `{:error,
  {:no_video_path, reasons}}`; a sink added later that can't take the stream gets the
  same from `add_sink/3`. `info/1` has the stream (`video:`).

  Options:

    * `:source` - lease on an `:audio_in` (`:video_in`) capability, or a Membrane
      source element for this node.
    * `:sink` or `:sinks` - lease(s) on `:audio_out` (`:display`) capabilities.
    * `:codec` - `:opus` (default) or `:h264`.
    * `:surface` - for video: `{render_session, target}` the frames are drawn into.
    * `:owner` - the session stops when this process exits. Default: the caller.
    * `:renew_every` - ms between lease renewals, default 30 s.
    * `:jitter` - receiver jitter buffer in ms, default 40: how long a sink waits for a
      missing (NACKed) packet before giving up on it.
    * `:bitrate` - encoder bitrate, default 64 kbps (Opus) or 3 Mbps (H.264, a cap; up
      to what the source can send).
    * `:size`, `:fps` - video: the size (`{w, h}`) and frame rate wanted, where the
      source can change them (default: the source's own). Negotiation goes smaller when
      a sink can't take them.
    * `:decoder` - video: what the sinks decode with: `:auto` (default; their node's
      hardware decoders if it has any, else software), `:software` (the override, even
      where there is hardware) or `:hardware`.
    * `:feedback` - which RTCP feedback sinks send: a subset of `[:nack, :pli]` (default
      both). Receiver reports are always sent.
    * `:playout` - audio sinks: playout queue to keep, in ms (default 20; see
      `Home.Media.Playout`), or `false` to leave the queue alone.
    * `:route` - `{module, function, args}` called as `apply(module, function,
      [{ip, port} | args])` for each sink address; the source sends to the address it
      returns instead (a port forward, or a test's impairment relay).
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

  @doc """
  Add a sink to a running session. The session becomes the holder of `lease` (an
  `:audio_out` or `:display` lease, like the ones given to `start/1`) and the source
  starts sending to it; a video sink gets a fresh keyframe.

  A video sink must take the stream the session sends (`{:error, {:no_video_path,
  reasons}}` otherwise; the lease stays the caller's). `opts`: `:decoder`, as for
  `start/1`, for this sink (default: the session's).
  """
  @spec add_sink(pid(), Lease.t(), keyword()) :: :ok | {:error, term()}
  def add_sink(session, %Lease{} = lease, opts \\ []),
    do: GenServer.call(session, {:add_sink, lease, opts}, @call_timeout * 2)

  @doc """
  Remove a sink (by capability ref or lease) from a running session: the source stops
  sending to it, its pipeline stops and its lease is released. The last sink can't be
  removed (`{:error, :last_sink}`); stop the session instead.
  """
  @spec remove_sink(pid(), Home.Capability.ref() | Lease.t()) :: :ok | {:error, term()}
  def remove_sink(session, %Lease{cap: cap}), do: remove_sink(session, cap)

  def remove_sink(session, cap),
    do: GenServer.call(session, {:remove_sink, cap}, @call_timeout * 2)

  @doc """
  What both ends know about the session's streams:

      %{source: %{packets: n, octets: n, nacked: n, retransmitted: n,
                  keyframe_requests: n, keyframes_forced: n,
                  receivers: %{sink_cap => %{fraction_lost: f, lost: n, jitter_ms: f,
                                             rtt_ms: f | nil, highest_seq: n}}},
        sinks: %{sink_cap => %{packets: n, expected: n, lost: n, fraction_lost: f,
                               jitter_ms: f, nacked: n, recovered: n, duplicates: n,
                               keyframe_requests: n, playout: %{...}}}}

  `receivers` is what each sink last reported over RTCP; `sinks` is each sink's own
  count. Both are updated about once a second (empty until the first report). Loss is
  after retransmission: a NACKed packet that arrived in time counts as `recovered`.
  """
  @spec stats(pid()) :: map()
  def stats(session), do: GenServer.call(session, :stats, @call_timeout)

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
          # Every lease the session holds, to renew and release.
          taken: [],
          source_cap: nil,
          source_pipeline: nil,
          # One per sink, in the order they were added.
          outputs: [],
          # Video: the negotiated stream (a Home.Media.Video.Path).
          video: nil,
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

    with {:ok, state} <- take_source(state),
         {:ok, state} <- negotiate_video(state),
         {:ok, state} <- add_outputs(state, state.sinks),
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
      source: source_ref(state.source),
      sinks: Enum.map(state.outputs, & &1.cap),
      destinations: Enum.map(state.outputs, & &1.address),
      ssrc: state.ssrc,
      pipelines: pipelines(state),
      video: state.video
    }

    {:reply, reply, state}
  end

  def handle_call({:add_sink, lease, opts}, _from, state) do
    if Enum.any?(state.outputs, &(&1.cap == lease.cap)) do
      {:reply, {:error, :already_a_sink}, state}
    else
      with {:ok, state} <- accept_sink(state, lease, opts),
           {:ok, state} <- add_output(state, lease) do
        output = List.last(state.outputs)

        case source_call(state, {:add_destination, output.to}) do
          :ok -> {:reply, :ok, state}
          error -> {:reply, error, drop_output(state, output)}
        end
      else
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:remove_sink, cap}, _from, state) do
    case Enum.find(state.outputs, &(&1.cap == cap)) do
      nil ->
        {:reply, {:error, :not_a_sink}, state}

      _output when length(state.outputs) == 1 ->
        {:reply, {:error, :last_sink}, state}

      output ->
        # Stop sending first, so nothing goes to a closed port.
        _ = source_call(state, {:remove_destination, output.to})
        {:reply, :ok, drop_output(state, output)}
    end
  end

  def handle_call(:stats, _from, state) do
    source = pipeline_call(state.source_pipeline, :stats) || %{}
    by_address = Map.new(state.outputs, &{&1.to, &1.cap})

    receivers =
      for {to, report} <- Map.get(source, :receivers, %{}),
          cap = by_address[to],
          into: %{},
          do: {cap, report}

    sinks = Map.new(state.outputs, &{&1.cap, pipeline_call(&1.pipeline, :stats) || %{}})
    {:reply, %{source: Map.put(source, :receivers, receivers), sinks: sinks}, state}
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

    # Source first so the mic stops producing, then the sinks, then the leases.
    Enum.each(pipelines(state), fn {_cap, pipeline} -> terminate_pipeline(pipeline) end)
    Enum.each(state.taken, &Lease.release/1)
  end

  ## Setup

  defp check(opts, sinks) do
    cond do
      Keyword.get(opts, :codec, :opus) not in [:opus, :h264] -> {:error, :unsupported_codec}
      sinks == [] -> {:error, :no_sink}
      true -> :ok
    end
  end

  defp take_source(%{source: %Lease{} = lease} = state) do
    case take(state, lease) do
      {:ok, state, _lease, _mref} -> {:ok, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp take_source(state), do: {:ok, state}

  # Video: settle the stream before anything starts, from what the source and the sinks
  # say they can do (`Home.Media.Video`).
  defp negotiate_video(%{opts: opts} = state) do
    if Keyword.get(opts, :codec) == :h264 do
      preference = Keyword.get(opts, :decoder, :auto)
      sinks = for lease <- state.sinks, do: {lease.cap, decode_formats(lease), preference}
      request = Keyword.take(opts, [:size, :fps, :bitrate])

      case Home.Media.Video.negotiate(source_formats(state), sinks, request) do
        {:ok, path} ->
          Logger.debug("video session: #{Home.Media.Video.describe(path)}")
          {:ok, %{state | video: path}}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:ok, state}
    end
  end

  # A sink joining a running video session takes the stream as it is.
  defp accept_sink(%{video: nil} = state, _lease, _opts), do: {:ok, state}

  defp accept_sink(%{video: path} = state, lease, opts) do
    preference = Keyword.get(opts, :decoder) || Keyword.get(state.opts, :decoder, :auto)

    case Home.Media.Video.accepts(decode_formats(lease), path, preference, lease.cap) do
      {:ok, decoder} -> {:ok, put_in(state.video.decoders[lease.cap], decoder)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp source_formats(%{source: %Lease{} = lease}),
    do: lease |> lease_info() |> Home.Media.Video.formats(:encode)

  # A source element on this node sends raw frames, for x264.
  defp source_formats(_state), do: [Home.Media.Video.software_encoder()]

  defp decode_formats(lease), do: lease |> lease_info() |> Home.Media.Video.formats(:decode)

  defp lease_info(lease) do
    Home.Capability.Server.info(lease.server)
  catch
    :exit, _ -> %{}
  end

  defp take(state, lease) do
    case Lease.handover(lease, self()) do
      {:ok, lease} ->
        mref = Process.monitor(lease.server)
        monitors = Map.put(state.monitors, mref, {:capability, lease.cap})
        {:ok, %{state | taken: state.taken ++ [lease], monitors: monitors}, lease, mref}

      {:error, reason} ->
        {:error, {reason, lease.cap}, state}
    end
  catch
    :exit, reason -> {:error, {:handover_failed, reason}, state}
  end

  defp add_outputs(state, leases) do
    Enum.reduce_while(leases, {:ok, state}, fn lease, {:ok, state} ->
      case add_output(state, lease) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  # Take the lease, start the sink's pipeline on its node and remember where to send.
  defp add_output(state, lease) do
    with {:ok, state, lease, cap_mref} <- take(state, lease) do
      opts =
        Map.merge(media_opts(state), %{
          ssrc: state.ssrc,
          session: self(),
          cap: lease.cap,
          jitter: Keyword.get(state.opts, :jitter, 40),
          video_decoder: state.video && state.video.decoders[lease.cap]
        })

      case remote(lease, :start_sink, [lease.endpoint, opts]) do
        {:ok, pipeline, {ip, port, _ssrc}} ->
          mref = Process.monitor(pipeline)

          output = %{
            cap: lease.cap,
            lease: lease,
            pipeline: pipeline,
            address: {ip, port},
            to: route(state, {ip, port}),
            mrefs: [cap_mref, mref]
          }

          monitors = Map.put(state.monitors, mref, {:pipeline, lease.cap})
          {:ok, %{state | outputs: state.outputs ++ [output], monitors: monitors}}

        {:error, reason} ->
          Process.demonitor(cap_mref, [:flush])
          release(lease)

          state = %{
            state
            | taken: Enum.reject(state.taken, &(&1.ref == lease.ref)),
              monitors: Map.delete(state.monitors, cap_mref)
          }

          {:error, {:sink_failed, lease.cap, reason}, state}
      end
    end
  end

  defp drop_output(state, output) do
    Enum.each(output.mrefs, &Process.demonitor(&1, [:flush]))
    terminate_pipeline(output.pipeline)
    release(output.lease)

    %{
      state
      | outputs: List.delete(state.outputs, output),
        taken: Enum.reject(state.taken, &(&1.ref == output.lease.ref)),
        monitors: Map.drop(state.monitors, output.mrefs),
        video:
          state.video && %{state.video | decoders: Map.delete(state.video.decoders, output.cap)}
    }
  end

  defp route(state, address) do
    case Keyword.get(state.opts, :route) do
      {m, f, a} -> apply(m, f, [address | a])
      nil -> address
    end
  end

  defp destinations(state), do: Enum.map(state.outputs, & &1.to)

  defp start_source(%{source: %Lease{}} = state) do
    [lease | _sinks] = state.taken
    opts = Map.merge(media_opts(state), %{ssrc: state.ssrc, session: self(), cap: lease.cap})

    case remote(lease, :start_source, [lease.endpoint, destinations(state), opts]) do
      {:ok, pipeline} -> {:ok, add_source_pipeline(state, lease.cap, pipeline)}
      {:error, reason} -> {:error, {:source_failed, lease.cap, reason}, state}
    end
  end

  # A source element of the session's own node (no capability, no lease).
  defp start_source(state) do
    opts = Map.merge(media_opts(state), %{ssrc: state.ssrc, session: self(), cap: nil})

    case Home.Media.start_source(state.source, destinations(state), opts) do
      {:ok, pipeline} -> {:ok, add_source_pipeline(state, {node(), :local}, pipeline)}
      {:error, reason} -> {:error, {:source_failed, :local, reason}, state}
    end
  end

  defp add_source_pipeline(state, cap, pipeline) do
    monitors = Map.put(state.monitors, Process.monitor(pipeline), {:pipeline, cap})
    %{state | monitors: monitors, source_pipeline: pipeline, source_cap: cap}
  end

  # Source first.
  defp pipelines(state) do
    sinks = for o <- Enum.reverse(state.outputs), do: {o.cap, o.pipeline}
    if state.source_pipeline, do: [{state.source_cap, state.source_pipeline} | sinks], else: sinks
  end

  defp media_opts(state) do
    opts =
      state.opts
      |> Keyword.take([:codec, :bitrate, :surface, :gop_size, :feedback, :playout])
      |> Map.new()

    if state.video, do: Map.put(opts, :video, state.video), else: opts
  end

  defp source_ref(%Lease{cap: cap}), do: cap
  defp source_ref(_element), do: {node(), :local}

  defp source_call(state, msg) do
    case pipeline_call(state.source_pipeline, msg) do
      nil -> {:error, :source_unreachable}
      reply -> reply
    end
  end

  defp pipeline_call(nil, _msg), do: nil

  defp pipeline_call(pipeline, msg) do
    Membrane.Pipeline.call(pipeline, msg, 5_000)
  catch
    :exit, _ -> nil
  end

  defp terminate_pipeline(pipeline) do
    Membrane.Pipeline.terminate(pipeline, force?: true, timeout: 2_000)
  catch
    _, _ -> :ok
  end

  defp remote(lease, fun, args) do
    :erpc.call(node(lease.server), Home.Media, fun, args, @call_timeout)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp renew_every(state), do: Keyword.get(state.opts, :renew_every, 30_000)

  defp renew(lease) do
    Lease.renew(lease)
  catch
    :exit, _ -> {:error, :gone}
  end

  defp release(lease) do
    Lease.release(lease)
  catch
    :exit, _ -> :ok
  end
end
