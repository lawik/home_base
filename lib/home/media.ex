defmodule Home.Media do
  @moduledoc """
  Media pipelines on this node (§5). `Home.Media.Session` calls `start_source/2` and
  `start_sink/2` on the nodes that own the capabilities; the pipelines run under
  `Home.Media.Supervisor` there.

  The node receives media on `Home.config(:media)`: `[ip: ip_tuple, ports: first..last]`,
  default `127.0.0.1` and #{inspect(50_000..50_099)}. Sinks bind that address and
  advertise it to the source.

  Behind NAT the address a sink advertises may not be the one a source has to send to (a
  qemu guest on user networking is reached through `hostfwd` on the host's 127.0.0.1). A
  source node then rewrites destinations with `routes:`, the way `HomeNode.Epmd` routes
  distribution: `%{advertised_ip => ip}` or `%{{advertised_ip, port} => {ip, port}}`
  (exact matches first).

      config :home_base, media: [ip: {127, 0, 0, 1}, ports: 41_430..41_439,
                                 routes: %{{10, 0, 3, 15} => {127, 0, 0, 1}}]
  """

  @default_ports 50_000..50_099

  @doc "This node's media address and UDP port range."
  def address do
    media = Home.config(:media, [])
    {Keyword.get(media, :ip, {127, 0, 0, 1}), Keyword.get(media, :ports, @default_ports)}
  end

  @doc """
  Start the receiving pipeline for `endpoint` on a free port of this node's range.
  Returns `{:ok, pipeline, {ip, port, ssrc}}`.

  Options: `:ssrc`, `:session`, `:cap`, `:codec` (`:opus` or `:h264`), `:kind` (`:audio_out`,
  or `:display` for video), `:jitter` (ms, 40).

  For video, `endpoint` may be a display's `Home.Render.Compositor`; frames then go to
  the video element `target` of render session `owner` given as `surface: {owner, target}`
  (see `Home.Media.VideoSink`).
  """
  def start_sink(endpoint, opts) do
    {ip, ports} = address()
    opts = Map.new(opts)
    video? = Map.get(opts, :codec) == :h264

    opts =
      opts
      |> Map.merge(%{endpoint: sink_endpoint(endpoint, opts), ip: ip, reply_to: self()})
      |> Map.put_new(:codec, :opus)
      |> Map.put_new(:kind, if(video?, do: :display, else: :audio_out))
      |> Map.put_new(:jitter, 40)

    open_sink(Enum.to_list(ports), opts)
  end

  defp sink_endpoint(comp, %{codec: :h264, surface: {owner, target}}) when is_pid(comp),
    do: %Home.Media.VideoSink{compositor: comp, owner: owner, target: target}

  defp sink_endpoint(endpoint, _opts), do: endpoint

  defp open_sink([], _opts), do: {:error, :no_free_port}

  defp open_sink([port | rest], opts) do
    with true <- free?(opts.ip, port),
         {:ok, pipeline} <- start_pipeline(Home.Media.SinkPipeline, Map.put(opts, :port, port)) do
      mref = Process.monitor(pipeline)

      receive do
        {:media_ready, ^pipeline} ->
          Process.demonitor(mref, [:flush])
          {:ok, pipeline, {opts.ip, port, opts.ssrc}}

        # Someone took the port between the probe and the open: try the next one.
        {:DOWN, ^mref, _, _, _} ->
          open_sink(rest, opts)
      after
        5_000 ->
          Membrane.Pipeline.terminate(pipeline, force?: true, timeout: 1_000)
          {:error, :timeout}
      end
    else
      _ -> open_sink(rest, opts)
    end
  end

  @doc """
  Start the sending pipeline for `endpoint` to `destinations` (`[{ip, port}]`).
  Returns `{:ok, pipeline}`.

  Options: `:ssrc`, `:session`, `:cap`, `:codec` (`:opus` or `:h264`), `:kind`
  (`:audio_in` or `:video_in`), `:bitrate` (64 kbps for Opus, 3 Mbps for H.264),
  `:application` (Opus, `:voip`), `:gop_size` (H.264 frames between keyframes, 30).
  """
  def start_source(endpoint, destinations, opts) do
    opts = Map.new(opts)
    video? = Map.get(opts, :codec) == :h264

    routes = Keyword.get(Home.config(:media, []), :routes, %{})

    opts =
      opts
      |> Map.merge(%{endpoint: endpoint, destinations: route(destinations, routes)})
      |> Map.put_new(:codec, :opus)
      |> Map.put_new(:kind, if(video?, do: :video_in, else: :audio_in))
      |> Map.put_new(:bitrate, if(video?, do: 3_000_000, else: 64_000))
      |> Map.put_new(:application, :voip)
      |> Map.put_new(:gop_size, 30)

    start_pipeline(Home.Media.SourcePipeline, opts)
  end

  @doc """
  Rewrite `[{ip, port}]` destinations with `routes` (see the moduledoc): an exact
  `{ip, port}` route first, then one for the ip alone (which keeps the port).
  """
  def route(destinations, routes) do
    for {ip, port} = dest <- destinations do
      case routes do
        %{^dest => {_ip, _port} = to} -> to
        %{^ip => to} when is_tuple(to) and tuple_size(to) in [4, 8] -> {to, port}
        _ -> dest
      end
    end
  end

  defp start_pipeline(module, opts) do
    spec = %{
      id: make_ref(),
      start: {Membrane.Pipeline, :start_link, [module, opts]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(Home.Media.Supervisor, spec) do
      {:ok, _supervisor, pipeline} -> {:ok, pipeline}
      {:error, _} = error -> error
    end
  end

  defp free?(ip, port) do
    case :gen_udp.open(port, ip: ip) do
      {:ok, socket} ->
        :gen_udp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  @doc false
  # Emit :stream_started now and :stream_stopped when the pipeline goes, however it goes.
  def announce_stream(_resource_guard, nil, _kind, _session), do: :ok

  def announce_stream(resource_guard, cap, kind, session) do
    Home.Activity.emit(cap, kind, :stream_started, %{session: session})

    Membrane.ResourceGuard.register(resource_guard, fn ->
      Home.Activity.emit(cap, kind, :stream_stopped, %{session: session})
    end)
  end
end
