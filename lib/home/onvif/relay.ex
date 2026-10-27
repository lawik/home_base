defmodule Home.Onvif.Relay do
  @moduledoc """
  One RTSP connection to a camera, fanned out to every `Home.Media.H264Relay` source
  that subscribes (one per media session; each session tees to its own sinks). So a
  camera has at most one connection from this node however many displays show it.

  Started by `Home.Onvif.Camera` when its capability's hardware turns on (the first
  lease) and stopped when it turns off (last release, holder death, expiry, revoke or
  `Home.Onvif.remove_camera/1`); stopping sends RTSP TEARDOWN.

  The stream is pulled with the `rtsp` library (TCP interleaved by default, or
  `{:udp, first_port, last_port}`), which depayloads RTP into H.264 access units that
  start at a keyframe and carry SPS/PPS on every keyframe. Access units go out as
  annex-b with monotonic nanosecond pts, also across reconnects.

  ## Keyframes for late joiners

  RTSP has no way to ask a camera for a keyframe, so the relay keeps the current GOP
  (the last keyframe and every access unit since, up to `:gop_limit` bytes, 2 MB). A
  new subscriber first gets that GOP in one burst, then the live stream: its decoder
  catches up to the live picture at once instead of waiting up to a GOP for the next
  keyframe. If the GOP outgrew the limit, a new subscriber waits for the next keyframe.
  The first subscriber after a (re)connect always waits for the camera's first keyframe.

  ## Camera disconnects

  When the connection fails or closes, the relay reconnects with exponential backoff
  (`:backoff`, 250 ms doubling up to 30 s) for as long as it runs; subscribers stay
  subscribed and the picture freezes meanwhile. Status changes are broadcast on PubSub
  topic `"onvif"` (cluster-wide) as `{:onvif_stream, {node, cap_id}, status}` with status
  `:connecting`, `:streaming` or `{:retrying, reason}`.
  """

  use GenServer, restart: :temporary
  require Logger

  @gop_limit 2_000_000
  @backoff {250, 30_000}
  @rtsp_timeout 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  `%{status, connections, subscribers, frames, keyframes, last_frame_at}`: `connections`
  counts RTSP sessions set up since the relay started.
  """
  def info(relay), do: GenServer.call(relay, :info)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {min, max} = Keyword.get(opts, :backoff, @backoff)

    state = %{
      id: Keyword.fetch!(opts, :id),
      uri: Keyword.fetch!(opts, :uri),
      transport: Keyword.get(opts, :transport, :tcp),
      gop_limit: Keyword.get(opts, :gop_limit, @gop_limit),
      backoff: {min, max},
      rtsp: nil,
      clock_rate: 90_000,
      status: :connecting,
      attempt: 0,
      subscribers: %{},
      gop: [],
      gop_bytes: 0,
      gop_ok?: false,
      # pts of this connection's first access unit, and the last pts sent out.
      base: 0,
      last_pts: nil,
      period: div(1_000_000_000, 30),
      connections: 0,
      frames: 0,
      keyframes: 0,
      last_frame_at: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  # The camera's stream is what it is: a session's negotiated parameters change nothing.
  def handle_call({:subscribe, pid, _params}, from, state),
    do: handle_call({:subscribe, pid}, from, state)

  def handle_call({:subscribe, pid}, _from, state) do
    mref = Process.monitor(pid)

    status =
      if state.gop_ok? and state.gop != [] do
        Enum.each(Enum.reverse(state.gop), &send(pid, {:h264_relay, self(), &1}))
        :live
      else
        :waiting
      end

    {:reply, :ok, put_in(state.subscribers[pid], {mref, status})}
  end

  def handle_call(:info, _from, state) do
    info =
      Map.take(state, [:status, :connections, :frames, :keyframes, :last_frame_at])
      |> Map.put(:subscribers, map_size(state.subscribers))

    {:reply, info, state}
  end

  @impl true
  def handle_info({:rtsp_ready, rtsp, result}, %{rtsp: rtsp} = state) do
    case result do
      {:ok, clock_rate} ->
        Logger.info("onvif #{state.id}: streaming")

        state = %{
          state
          | clock_rate: clock_rate,
            attempt: 0,
            connections: state.connections + 1,
            # Continue the timeline one frame after the last access unit sent.
            base: if(state.last_pts, do: state.last_pts + state.period, else: 0),
            gop: [],
            gop_bytes: 0,
            gop_ok?: false,
            subscribers: Map.new(state.subscribers, fn {pid, {m, _}} -> {pid, {m, :waiting}} end)
        }

        {:noreply, set_status(state, :streaming)}

      {:error, reason} ->
        {:noreply, retry(state, reason)}
    end
  end

  def handle_info({:rtsp, rtsp, {_control_path, samples}}, %{rtsp: rtsp} = state)
      when is_list(samples),
      do: {:noreply, Enum.reduce(samples, state, &sample/2)}

  def handle_info({:rtsp, rtsp, {_control_path, sample}}, %{rtsp: rtsp} = state),
    do: {:noreply, sample(sample, state)}

  def handle_info({:rtsp, rtsp, :discontinuity}, %{rtsp: rtsp} = state), do: {:noreply, state}

  def handle_info({:rtsp, rtsp, :session_closed}, %{rtsp: rtsp} = state),
    do: {:noreply, retry(state, :session_closed)}

  def handle_info({:EXIT, rtsp, reason}, %{rtsp: rtsp} = state),
    do: {:noreply, retry(%{state | rtsp: nil}, {:exit, reason})}

  def handle_info(:reconnect, state), do: {:noreply, connect(state)}

  def handle_info({:DOWN, mref, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => {^mref, _}} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

      _ ->
        {:noreply, state}
    end
  end

  # Samples and exits of connections already given up on, the connect task's exit.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state.rtsp)
    :ok
  end

  ## Connection

  # The RTSP client is a process of its own that sends samples here. DESCRIBE/SETUP/PLAY
  # can block for its timeout, so they run in a task and the relay stays responsive.
  defp connect(state) do
    opts = [
      stream_uri: state.uri,
      allowed_media_types: [:video],
      transport: state.transport,
      timeout: @rtsp_timeout,
      receiver: self()
    ]

    case RTSP.start_link(opts) do
      {:ok, rtsp} ->
        relay = self()
        Task.start_link(fn -> send(relay, {:rtsp_ready, rtsp, setup(rtsp)}) end)
        %{state | rtsp: rtsp}

      {:error, reason} ->
        retry(state, reason)
    end
  end

  defp setup(rtsp) do
    with {:ok, tracks} <- RTSP.connect(rtsp, @rtsp_timeout + 1_000),
         {:ok, track} <- h264_track(tracks),
         :ok <- RTSP.play(rtsp, @rtsp_timeout + 1_000) do
      {:ok, track.rtpmap.clock_rate || 90_000}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp h264_track(tracks) do
    case Enum.find(tracks, &(&1.type == :video)) do
      %{rtpmap: %{encoding: encoding}} = track ->
        if String.upcase(encoding) == "H264",
          do: {:ok, track},
          else: {:error, {:unsupported_codec, encoding}}

      _ ->
        {:error, :no_video_track}
    end
  end

  defp retry(state, reason) do
    close(state.rtsp)
    {min, max} = state.backoff
    delay = min(min * Integer.pow(2, state.attempt), max)
    Logger.warning("onvif #{state.id}: #{inspect(reason)}, reconnecting in #{delay} ms")
    Process.send_after(self(), :reconnect, delay)

    %{state | rtsp: nil, attempt: state.attempt + 1}
    |> set_status({:retrying, reason})
  end

  defp close(nil), do: :ok

  defp close(rtsp) do
    Process.unlink(rtsp)

    # TEARDOWN, bounded: a camera that went away must not hold up the capability.
    task = Task.async(fn -> RTSP.stop(rtsp) end)
    Task.yield(task, 1_500) || Task.shutdown(task, :brutal_kill)
    GenServer.stop(rtsp, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    Phoenix.PubSub.broadcast(
      Home.PubSub,
      "onvif",
      {:onvif_stream, {node(), state.id}, status}
    )

    %{state | status: status}
  end

  ## Media

  defp sample({nalus, rtp_ts, keyframe?, _wall_ms}, state) do
    pts = state.base + div(rtp_ts * 1_000_000_000, state.clock_rate)

    payload =
      for nalu <- List.wrap(nalus),
          into: <<>>,
          do: <<0, 0, 0, 1, IO.iodata_to_binary(nalu)::binary>>

    au = {:au, payload, pts, keyframe?}

    state = cache(state, au, byte_size(payload))

    subscribers =
      Map.new(state.subscribers, fn
        {pid, {mref, :waiting}} when keyframe? ->
          send(pid, {:h264_relay, self(), au})
          {pid, {mref, :live}}

        {pid, {_mref, :live}} = sub ->
          send(pid, {:h264_relay, self(), au})
          sub

        sub ->
          sub
      end)

    period =
      if state.last_pts && pts > state.last_pts, do: pts - state.last_pts, else: state.period

    %{
      state
      | subscribers: subscribers,
        last_pts: pts,
        period: period,
        frames: state.frames + 1,
        keyframes: state.keyframes + if(keyframe?, do: 1, else: 0),
        last_frame_at: System.system_time(:millisecond)
    }
  end

  defp cache(state, au, size) do
    cond do
      elem(au, 3) ->
        %{state | gop: [au], gop_bytes: size, gop_ok?: true}

      state.gop_ok? and state.gop_bytes + size <= state.gop_limit ->
        %{state | gop: [au | state.gop], gop_bytes: state.gop_bytes + size}

      true ->
        %{state | gop: [], gop_bytes: 0, gop_ok?: false}
    end
  end
end
