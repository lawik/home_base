defmodule Home.Media.SinkPipeline do
  @moduledoc """
  Sink side of a session, on the sink capability's node:

      UDP endpoint -> RTCP receiver -> RTP demuxer (jitter buffer) -> RTP Opus depayloader
        -> Opus decoder -> level -> playout -> endpoint

  or, for `codec: :h264`,

      ... -> RTP H.264 depayloader (access units, on the RTP marker) -> H.264 parser
        -> H.264 decoder -> to RGB -> endpoint

  The decoder is the one the session's negotiation chose for this sink (`:video_decoder`,
  a `Home.Media.Video.Format` of this node's, see `Home.Media.Video`): FFmpeg's, in
  software, or a filter such as a hardware decoder, whose frames go to the endpoint as
  they come out, without the conversion to RGB. A session from a node without
  negotiation gives none, and this node's default decoder (`Home.Media.video_decoder/0`)
  is used.

  The RTCP receiver's feedback (receiver reports, NACKs, PLIs) goes back out of the same
  UDP endpoint to wherever the RTP comes from (see `Home.Media.RTCP`). After a loss the
  video freezes until a keyframe and a PLI asks for one (`Home.Media.H264Depayloader`);
  audio's playout queue is kept short by `Home.Media.Playout`.

  Options beyond `Home.Media.start_sink/2`'s: `:feedback` (subset of `[:nack, :pli]`,
  both by default), `:playout` (target queue in ms, or `false` for none).

  Sends `{:media_ready, self()}` to `reply_to` once the UDP socket is open, answers
  `Membrane.Pipeline.call(pipeline, :stats)`, and terminates when the session dies.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    Process.monitor(opts.session)
    opts = opts |> Map.put_new(:feedback, [:nack, :pli]) |> Map.put_new(:playout, 20)

    spec = [
      # The destination is only a placeholder: feedback goes back to the RTP's sender
      # (`latch?`), and nothing is sent before the first RTP packet.
      child(:udp, %Home.Media.UDPEndpoint{
        local_port_no: opts.port,
        local_address: opts.ip,
        destination_address: opts.ip,
        destination_port_no: opts.port,
        latch?: true
      })
      |> child(:rtcp, %Home.Media.RTCP.Receiver{
        ssrc: opts.ssrc,
        clock_rate: if(opts.codec == :h264, do: 90_000, else: 48_000),
        nack: :nack in opts.feedback
      })
      |> child(:demuxer, Membrane.RTP.Demuxer)
      |> via_out(:output,
        options: [
          stream_id: {:ssrc, opts.ssrc},
          jitter_buffer_latency: Membrane.Time.milliseconds(opts.jitter)
        ]
      )
      |> decode(opts)
      |> child(:endpoint, opts.endpoint),
      get_child(:rtcp) |> via_out(:feedback) |> get_child(:udp)
    ]

    {[spec: spec], Map.merge(opts, %{rtp: %{}, playout_stats: nil})}
  end

  defp decode(demuxer, %{codec: :h264} = opts) do
    decoder =
      case Map.get(opts, :video_decoder) do
        %Home.Media.Video.Format{element: element} -> Home.Media.decoder_element(element)
        nil -> Home.Media.video_decoder()
      end

    demuxer
    |> child(:depayloader, Home.Media.H264Depayloader)
    |> decode_h264(decoder)
  end

  defp decode(demuxer, opts) do
    demuxer
    |> child(:depayloader, Membrane.RTP.Opus.Depayloader)
    |> child(:decoder, Membrane.Opus.Decoder)
    |> child(:level, %Home.Media.Level{cap: opts.cap, kind: opts.kind, session: opts.session})
    |> playout(opts)
  end

  defp decode_h264(access_units, :software) do
    access_units
    |> child(:parser, Membrane.H264.Parser)
    |> child(:decoder, Membrane.H264.FFmpeg.Decoder)
    |> child(:to_rgb, %Membrane.FFmpeg.SWScale.Converter{format: :RGB})
  end

  defp decode_h264(access_units, decoder) do
    access_units
    |> child(:parser, %Membrane.H264.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb
    })
    |> child(:decoder, decoder)
  end

  defp playout(audio, %{playout: false}), do: audio
  defp playout(audio, %{playout: ms}), do: child(audio, :playout, %Home.Media.Playout{target: ms})

  @impl true
  # A display's activity (session started/stopped, frames) comes from its compositor.
  def handle_setup(_ctx, %{codec: :h264} = state), do: {[], state}

  def handle_setup(ctx, state) do
    Home.Media.announce_stream(ctx.resource_guard, state.cap, state.kind, state.session)
    {[], state}
  end

  @impl true
  def handle_child_notification({:connection_info, _ip, _port}, :udp, _ctx, state) do
    send(state.reply_to, {:media_ready, self()})
    {[], state}
  end

  def handle_child_notification(:keyframe_request, :depayloader, _ctx, state) do
    if :pli in state.feedback,
      do: {[notify_child: {:rtcp, :keyframe_request}], state},
      else: {[], state}
  end

  def handle_child_notification({:receiver_stats, stats}, :rtcp, _ctx, state),
    do: {[], %{state | rtp: stats}}

  def handle_child_notification({:playout, stats}, :playout, _ctx, state),
    do: {[], %{state | playout_stats: stats}}

  def handle_child_notification(_msg, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_call(:stats, _ctx, state) do
    stats =
      if state.playout_stats,
        do: Map.put(state.rtp, :playout, state.playout_stats),
        else: state.rtp

    {[reply: stats], state}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, _ctx, %{session: pid} = state),
    do: {[terminate: :normal], state}

  def handle_info(_msg, _ctx, state), do: {[], state}
end
