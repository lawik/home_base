defmodule Home.Media.SourcePipeline do
  @moduledoc """
  Source side of a session, on the source capability's node:

      endpoint -> level -> Opus encoder -> RTP Opus payloader -> RTP muxer -> RTCP sender -> tee
        -> UDP endpoint (one per destination) -> back into the RTCP sender (feedback)

  or, for `codec: :h264`,

      endpoint -> to I420 -> H.264 encoder -> keyframes -> H.264 parser
        -> RTP H.264 payloader (marker on each access unit's last packet) -> RTP muxer -> ...

  One encoder and one payloader however many sinks (§5.3). Each destination gets a UDP
  endpoint on an ephemeral port of this node's media address; the sink's RTCP (receiver
  reports, NACKs, PLIs) comes back on it (see `Home.Media.RTCP`). A PLI from any sink
  forces a keyframe (`Home.Media.Keyframes`).

  Calls (`Membrane.Pipeline.call/3`): `:stats`, `{:add_destination, {ip, port}}`,
  `{:remove_destination, {ip, port}}`. Terminates when the session dies.
  """

  use Membrane.Pipeline

  require Membrane.Pad

  alias Membrane.Pad

  @impl true
  def handle_init(_ctx, opts) do
    Process.monitor(opts.session)
    {local_ip, _ports} = Home.Media.address()

    spec =
      [
        child(:endpoint, opts.endpoint)
        |> encode(opts)
        |> via_in(:input, options: [ssrc: opts.ssrc])
        |> child(:muxer, Membrane.RTP.Muxer)
        |> child(:rtcp, %Home.Media.RTCP.Sender{clock_rate: clock_rate(opts)})
        |> child(:tee, Membrane.Tee)
      ] ++ Enum.map(opts.destinations, &destination(&1, local_ip))

    state =
      opts
      |> Map.put(:local_ip, local_ip)
      |> Map.merge(%{receivers: %{}, sent: %{}, keyframes: 0})

    {[spec: spec], state}
  end

  defp destination({ip, port} = dest, local_ip) do
    get_child(:tee)
    |> via_out(:push_output)
    |> child({:udp, dest}, %Membrane.UDP.Endpoint{
      destination_address: ip,
      destination_port_no: port,
      local_address: local_ip
    })
    |> via_in(Pad.ref(:feedback, dest))
    |> get_child(:rtcp)
  end

  defp clock_rate(%{codec: :h264}), do: 90_000
  defp clock_rate(_opts), do: 48_000

  defp encode(endpoint, %{codec: :h264} = opts) do
    # x264 in CRF mode capped at `bitrate` (VBV), tuned for latency: no B-frames, a
    # keyframe every `gop_size` frames and whenever a sink asks for one.
    endpoint
    |> child(:to_i420, %Membrane.FFmpeg.SWScale.Converter{format: :I420})
    |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
      preset: :ultrafast,
      tune: :zerolatency,
      profile: :baseline,
      max_b_frames: 0,
      gop_size: opts.gop_size,
      ffmpeg_params: %{
        "maxrate" => Integer.to_string(opts.bitrate),
        "bufsize" => Integer.to_string(div(opts.bitrate, 2))
      }
    })
    |> child(:keyframes, Home.Media.Keyframes)
    |> child(:parser, %Membrane.H264.Parser{output_alignment: :au, repeat_parameter_sets: true})
    |> child(:payloader, Home.Media.H264Payloader)
  end

  defp encode(endpoint, opts) do
    endpoint
    |> child(:level, %Home.Media.Level{cap: opts.cap, kind: opts.kind, session: opts.session})
    |> child(:encoder, %Membrane.Opus.Encoder{
      application: opts.application,
      bitrate: opts.bitrate
    })
    |> child(:payloader, Membrane.RTP.Opus.Payloader)
  end

  @impl true
  def handle_setup(ctx, state) do
    Home.Media.announce_stream(ctx.resource_guard, state.cap, state.kind, state.session)
    {[], state}
  end

  @impl true
  def handle_child_notification({:receiver_report, dest, report}, :rtcp, _ctx, state),
    do: {[], put_in(state.receivers[dest], report)}

  def handle_child_notification({:sender_stats, stats}, :rtcp, _ctx, state),
    do: {[], %{state | sent: stats}}

  def handle_child_notification({:keyframe_request, _dest}, :rtcp, _ctx, state),
    do: {keyframe(state), state}

  def handle_child_notification({:forced, n}, :keyframes, _ctx, state),
    do: {[], %{state | keyframes: n}}

  def handle_child_notification(_msg, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_call(:stats, _ctx, state) do
    stats =
      Map.merge(state.sent, %{keyframes_forced: state.keyframes, receivers: state.receivers})

    {[reply: stats], state}
  end

  def handle_call({:add_destination, dest}, ctx, state) do
    if Map.has_key?(ctx.children, {:udp, dest}) do
      {[reply: :ok], state}
    else
      # A new receiver can't start decoding video before a keyframe.
      {[spec: destination(dest, state.local_ip), reply: :ok] ++ keyframe(state), state}
    end
  end

  def handle_call({:remove_destination, dest}, ctx, state) do
    state = %{state | receivers: Map.delete(state.receivers, dest)}

    if Map.has_key?(ctx.children, {:udp, dest}),
      do: {[remove_children: {:udp, dest}, reply: :ok], state},
      else: {[reply: :ok], state}
  end

  defp keyframe(%{codec: :h264}), do: [notify_child: {:keyframes, :keyframe_request}]
  defp keyframe(_state), do: []

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, _ctx, %{session: pid} = state),
    do: {[terminate: :normal], state}

  def handle_info(_msg, _ctx, state), do: {[], state}
end
