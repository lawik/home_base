defmodule Home.Media do
  @moduledoc """
  Media pipelines on this node (§5). `Home.Media.Session` calls `start_source/2` and
  `start_sink/2` on the nodes that own the capabilities; the pipelines run under
  `Home.Media.Supervisor` there.

  The node receives media on `Home.config(:media)`: `[ip: ip_tuple, ports: first..last]`,
  default `127.0.0.1` and #{inspect(50_000..50_099)}.
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

  Options: `:ssrc`, `:session`, `:cap`, `:kind` (`:audio_out`), `:jitter` (ms, 40).
  """
  def start_sink(endpoint, opts) do
    {ip, ports} = address()

    opts =
      opts
      |> Map.new()
      |> Map.merge(%{endpoint: endpoint, ip: ip, reply_to: self()})
      |> Map.put_new(:kind, :audio_out)
      |> Map.put_new(:jitter, 40)

    open_sink(Enum.to_list(ports), opts)
  end

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

  Options: `:ssrc`, `:session`, `:cap`, `:kind` (`:audio_in`), `:bitrate` (64 kbps),
  `:application` (`:voip`).
  """
  def start_source(endpoint, destinations, opts) do
    opts =
      opts
      |> Map.new()
      |> Map.merge(%{endpoint: endpoint, destinations: destinations})
      |> Map.put_new(:kind, :audio_in)
      |> Map.put_new(:bitrate, 64_000)
      |> Map.put_new(:application, :voip)

    start_pipeline(Home.Media.SourcePipeline, opts)
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
  def announce_stream(resource_guard, cap, kind, session) do
    Home.Activity.emit(cap, kind, :stream_started, %{session: session})

    Membrane.ResourceGuard.register(resource_guard, fn ->
      Home.Activity.emit(cap, kind, :stream_stopped, %{session: session})
    end)
  end
end
