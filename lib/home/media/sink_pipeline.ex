defmodule Home.Media.SinkPipeline do
  @moduledoc """
  Sink side of a session, on the sink capability's node:

      UDP source -> RTP demuxer (jitter buffer) -> RTP Opus depayloader -> Opus decoder -> level -> endpoint

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
      |> child(:depayloader, Membrane.RTP.Opus.Depayloader)
      |> child(:decoder, Membrane.Opus.Decoder)
      |> child(:level, %Home.Media.Level{cap: opts.cap, kind: opts.kind, session: opts.session})
      |> child(:endpoint, opts.endpoint)

    {[spec: spec], opts}
  end

  @impl true
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
