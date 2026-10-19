defmodule Home.Media.SourcePipeline do
  @moduledoc """
  Source side of a session, on the source capability's node:

      endpoint -> level -> Opus encoder -> RTP Opus payloader -> RTP muxer -> tee -> UDP sink (one per destination)

  One encoder and one payloader however many sinks (§5.3). Terminates when the session dies.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    Process.monitor(opts.session)

    spec =
      [
        child(:endpoint, opts.endpoint)
        |> child(:level, %Home.Media.Level{cap: opts.cap, kind: opts.kind, session: opts.session})
        |> child(:encoder, %Membrane.Opus.Encoder{
          application: opts.application,
          bitrate: opts.bitrate
        })
        |> child(:payloader, Membrane.RTP.Opus.Payloader)
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
