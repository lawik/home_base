defmodule Home.Test.FakeRtspCamera do
  @moduledoc false
  # The RTSP side of a fake IP camera: a live H.264 stream of `Home.Media.SynthVideo`
  # (frame numbers drawn in, `{:synth_frame, cap, n, wall_us}` sent to `notify` per
  # frame) encoded once with x264 and served to every RTSP client (PLAY, TCP
  # interleaved) by `Membrane.RTSP.Server`. Like a real camera it streams whether or not
  # anyone watches, starts each client mid-GOP, and counts its RTSP sessions.
  #
  #     {:ok, cam} = FakeRtspCamera.start_link(port: 0, notify: self())
  #     FakeRtspCamera.url(cam)  #=> "rtsp://127.0.0.1:PORT/stream"
  #     FakeRtspCamera.stats(cam) #=> %{active: 1, sessions: 1}

  use GenServer

  alias Home.Test.FakeRtspCamera.{Handler, Pipeline}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def url(cam), do: GenServer.call(cam, :url)

  @doc "`active` clients playing now, `sessions` started in total."
  def stats(cam), do: GenServer.call(cam, :stats)

  @doc "Close every client connection, as a camera reboot would."
  def drop_clients(cam), do: GenServer.call(cam, :drop_clients)

  @doc "While `refuse?`, new clients get 503 on DESCRIBE."
  def refuse(cam, refuse?), do: GenServer.call(cam, {:refuse, refuse?})

  def stop(cam), do: GenServer.stop(cam)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {w, h} = Keyword.get(opts, :size, {320, 240})
    fps = Keyword.get(opts, :fps, 30)

    {:ok, server} =
      Membrane.RTSP.Server.start_link(
        port: Keyword.get(opts, :port, 0),
        address: {127, 0, 0, 1},
        handler: Handler,
        handler_config: [camera: self()]
      )

    {:ok, port} = Membrane.RTSP.Server.port_number(server)

    {:ok, _sup, pipeline} =
      Membrane.Pipeline.start_link(Pipeline,
        camera: self(),
        width: w,
        height: h,
        fps: fps,
        gop: Keyword.get(opts, :gop, fps),
        notify: Keyword.get(opts, :notify),
        cap: Keyword.get(opts, :cap, :fake_camera)
      )

    {:ok,
     %{
       server: server,
       port: port,
       pipeline: pipeline,
       clients: %{},
       sessions: 0,
       refuse?: false
     }}
  end

  @impl true
  def handle_call(:url, _from, state),
    do: {:reply, "rtsp://127.0.0.1:#{state.port}/stream", state}

  def handle_call(:stats, _from, state),
    do: {:reply, %{active: map_size(state.clients), sessions: state.sessions}, state}

  def handle_call(:drop_clients, _from, state) do
    for {_pid, client} <- state.clients, do: :gen_tcp.close(client.socket)
    {:reply, :ok, state}
  end

  def handle_call({:refuse, refuse?}, _from, state),
    do: {:reply, :ok, %{state | refuse?: refuse?}}

  def handle_call(:refuse?, _from, state), do: {:reply, state.refuse?, state}

  def handle_call({:play, pid, ctx}, _from, state) do
    [{_control, track}] = Map.to_list(ctx)

    client = %{
      socket: track.tcp_socket,
      channel: elem(track.channels, 0),
      ssrc: track.ssrc,
      payloader: RTSP.RTP.Encoder.H264.init(payload_type: 96, ssrc: track.ssrc),
      monitor: Process.monitor(pid)
    }

    {:reply, :ok,
     %{state | clients: Map.put(state.clients, pid, client), sessions: state.sessions + 1}}
  end

  def handle_call({:stop, pid}, _from, state), do: {:reply, :ok, forget(state, pid)}

  @impl true
  def handle_info({:au, payload, pts}, state) do
    timestamp = div(pts * 90_000, 1_000_000_000) |> rem(0x1_0000_0000)

    clients =
      Map.new(state.clients, fn {pid, client} ->
        {packets, payloader} =
          RTSP.RTP.Encoder.H264.handle_sample(payload, timestamp, client.payloader)

        data =
          for packet <- packets do
            bin = ExRTP.Packet.encode(%{packet | ssrc: client.ssrc})
            [?$, client.channel, <<byte_size(bin)::16>>, bin]
          end

        # A closed socket: the handler's connection-closed callback forgets the client.
        _ = :gen_tcp.send(client.socket, data)
        {pid, %{client | payloader: payloader}}
      end)

    {:noreply, %{state | clients: clients}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, forget(state, pid)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Membrane.Pipeline.terminate(state.pipeline, timeout: 2_000)
    Membrane.RTSP.Server.stop(state.server)
    :ok
  catch
    _, _ -> :ok
  end

  defp forget(state, pid) do
    case Map.pop(state.clients, pid) do
      {nil, _} ->
        state

      {client, clients} ->
        Process.demonitor(client.monitor, [:flush])
        %{state | clients: clients}
    end
  end
end

defmodule Home.Test.FakeRtspCamera.Pipeline do
  @moduledoc false
  # SynthVideo -> x264 -> access units (annex-b, SPS/PPS on keyframes) -> the camera.
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    camera = opts[:camera]

    spec =
      child(:video, %Home.Media.SynthVideo{
        width: opts[:width],
        height: opts[:height],
        fps: opts[:fps],
        notify: opts[:notify],
        cap: opts[:cap]
      })
      |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
        preset: :ultrafast,
        tune: :zerolatency,
        profile: :baseline,
        max_b_frames: 0,
        gop_size: opts[:gop]
      })
      |> child(:parser, %Membrane.H264.Parser{
        output_alignment: :au,
        output_stream_structure: :annexb,
        repeat_parameter_sets: true
      })
      |> child(:sink, %Membrane.Debug.Sink{
        handle_buffer: fn buffer -> send(camera, {:au, buffer.payload, buffer.pts}) end
      })

    {[spec: spec], %{}}
  end
end

defmodule Home.Test.FakeRtspCamera.Handler do
  @moduledoc false
  use Membrane.RTSP.Server.Handler

  alias Membrane.RTSP.Response

  @impl true
  def init(config), do: %{camera: config[:camera]}

  @impl true
  def handle_open_connection(_conn, state), do: state

  @impl true
  def handle_describe(_request, state) do
    if GenServer.call(state.camera, :refuse?) do
      {Response.new(503), state}
    else
      media = %ExSDP.Media{
        type: :video,
        port: 0,
        protocol: "RTP/AVP",
        fmt: [96],
        attributes: [
          {"control", "track=0"},
          %ExSDP.Attribute.FMTP{pt: 96, packetization_mode: 1},
          %ExSDP.Attribute.RTPMapping{payload_type: 96, encoding: "H264", clock_rate: 90_000}
        ]
      }

      sdp = %ExSDP{
        origin: %ExSDP.Origin{session_id: 0, session_version: 0, address: {127, 0, 0, 1}},
        media: [media]
      }

      response =
        Response.new(200)
        |> Response.with_header("Content-Type", "application/sdp")
        |> Response.with_body(to_string(sdp))

      {response, state}
    end
  end

  @impl true
  def handle_setup(_request, :play, state), do: {Response.new(200), state}
  def handle_setup(_request, :record, state), do: {Response.new(405), state}

  @impl true
  def handle_play(media_context, state) do
    :ok = GenServer.call(state.camera, {:play, self(), media_context})
    {Response.new(200), state}
  end

  @impl true
  def handle_pause(state), do: {Response.new(501), state}

  @impl true
  def handle_teardown(state) do
    GenServer.call(state.camera, {:stop, self()})
    {Response.new(200), state}
  end

  @impl true
  def handle_closed_connection(state) do
    GenServer.call(state.camera, {:stop, self()})
    :ok
  catch
    :exit, _ -> :ok
  end
end
