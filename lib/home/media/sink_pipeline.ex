defmodule Home.Media.SinkPipeline do
  @moduledoc """
  Sink side of a session, on the sink capability's node:

      UDP source -> RTP demuxer (jitter buffer) -> RTP Opus depayloader -> Opus decoder -> level -> endpoint

  or, for `codec: :h264`,

      ... -> RTP H.264 depayloader -> H.264 parser (access units) -> H.264 decoder -> to RGB -> endpoint

  Sends `{:media_ready, self()}` to `reply_to` once the UDP socket is open, and terminates
  when the session dies.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    Process.monitor(opts.session)

    spec =
      child(:udp, %Membrane.UDP.Source{local_port_no: opts.port, local_address: opts.ip})
      |> child(:demuxer, Membrane.RTP.Demuxer)
      |> via_out(:output,
        options: [
          stream_id: {:ssrc, opts.ssrc},
          jitter_buffer_latency: Membrane.Time.milliseconds(opts.jitter)
        ]
      )
      |> decode(opts)
      |> child(:endpoint, opts.endpoint)

    {[spec: spec], opts}
  end

  defp decode(demuxer, %{codec: :h264}) do
    demuxer
    |> child(:depayloader, Membrane.RTP.H264.Depayloader)
    |> child(:parser, Membrane.H264.Parser)
    |> child(:decoder, Membrane.H264.FFmpeg.Decoder)
    |> child(:to_rgb, %Membrane.FFmpeg.SWScale.Converter{format: :RGB})
  end

  defp decode(demuxer, opts) do
    demuxer
    |> child(:depayloader, Membrane.RTP.Opus.Depayloader)
    |> child(:decoder, Membrane.Opus.Decoder)
    |> child(:level, %Home.Media.Level{cap: opts.cap, kind: opts.kind, session: opts.session})
  end

  @impl true
  # A display's activity (session started/stopped, frames) comes from its compositor.
  def handle_setup(_ctx, %{codec: :h264} = opts), do: {[], opts}

  def handle_setup(ctx, opts) do
    Home.Media.announce_stream(ctx.resource_guard, opts.cap, opts.kind, opts.session)
    {[], opts}
  end

  @impl true
  def handle_child_notification({:connection_info, _ip, _port}, :udp, _ctx, opts) do
    send(opts.reply_to, {:media_ready, self()})
    {[], opts}
  end

  def handle_child_notification(_msg, _child, _ctx, opts), do: {[], opts}

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, _ctx, %{session: pid} = opts),
    do: {[terminate: :normal], opts}

  def handle_info(_msg, _ctx, opts), do: {[], opts}
end
