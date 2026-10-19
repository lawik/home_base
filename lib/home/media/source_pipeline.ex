defmodule Home.Media.SourcePipeline do
  @moduledoc """
  Source side of a session, on the source capability's node:

      endpoint -> level -> Opus encoder -> RTP Opus payloader -> RTP muxer -> tee -> UDP sink (one per destination)

  or, for `codec: :h264`,

      endpoint -> to I420 -> H.264 encoder -> H.264 parser (NAL units) -> RTP H.264 payloader -> RTP muxer -> ...

  One encoder and one payloader however many sinks (§5.3). Terminates when the session dies.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    Process.monitor(opts.session)

    spec =
      [
        child(:endpoint, opts.endpoint)
        |> encode(opts)
        |> via_in(:input, options: [ssrc: opts.ssrc])
        |> child(:muxer, Membrane.RTP.Muxer)
        |> child(:tee, Membrane.Tee)
      ] ++
        for {ip, port} <- opts.destinations do
          get_child(:tee)
          |> via_out(:output)
          |> child({:udp, ip, port}, %Membrane.UDP.Sink{
            destination_address: ip,
            destination_port_no: port
          })
        end

    {[spec: spec], opts}
  end

  defp encode(endpoint, %{codec: :h264} = opts) do
    # x264 in CRF mode capped at `bitrate` (VBV), tuned for latency: no B-frames, a
    # keyframe every second so a receiver that lost a packet recovers quickly.
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
    |> child(:parser, %Membrane.H264.Parser{
      output_alignment: :nalu,
      repeat_parameter_sets: true
    })
    |> child(:payloader, Membrane.RTP.H264.Payloader)
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
  def handle_setup(ctx, opts) do
    Home.Media.announce_stream(ctx.resource_guard, opts.cap, opts.kind, opts.session)
    {[], opts}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, _ctx, %{session: pid} = opts),
    do: {[terminate: :normal], opts}

  def handle_info(_msg, _ctx, opts), do: {[], opts}
end
