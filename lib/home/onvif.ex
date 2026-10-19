defmodule Home.Onvif do
  @moduledoc """
  ONVIF IP cameras on this node, vended to the cluster as `:video_in` capabilities.

      [cam] = Home.Onvif.discover(hosts: ["10.0.0.5"])
      {:ok, {node, "cam-10-0-0-5"}} =
        Home.Onvif.add_camera(cam, username: "admin", password: "secret")

      # From any node: the camera is a capability like any other.
      {:ok, video} = Home.Render.show_video({node, "cam-10-0-0-5"}, on: {kitchen, "disp0"})

  `add_camera/2` runs on the node it is called on, which becomes the camera's owner: it
  talks to the camera (`Home.Onvif.Client`), keeps the configuration (credentials
  included) in a file under `Home.data_dir/0` that never leaves the node, and starts the
  capability with `Home.Capability.add/1`. To configure a camera on another node, call it
  there (`:erpc.call(node, Home.Onvif, :add_camera, [url, opts])`); the credentials then
  cross the distribution channel once, to the owner.

  The capability is `:on_request` and shared: the first lease opens one RTSP connection
  (`Home.Onvif.Relay`), every media session on it gets the same stream without
  re-encoding, and the last release closes it. See `Home.Onvif.Camera` and docs/ONVIF.md.

  Configured cameras are re-added at boot from the stored configuration, without
  asking the camera again (it may be offline; the stream reconnects when it is back).

  ## Periodic discovery

  With `onvif: [discover_every: ms, discover: probe_opts]` in the `Home` options this
  node probes every `ms` (`Home.Onvif.Discovery.probe/1` options) and broadcasts the
  cameras it found that are not configured here on PubSub topic `"onvif"` (cluster-wide)
  as `{:onvif_discovered, node, [%Home.Onvif.Discovery{}]}`. Nothing is added
  automatically. `discovered/0` returns the last such list.
  """

  use GenServer
  require Logger

  alias Home.Onvif.{Client, Discovery}

  @table __MODULE__
  @file_name "onvif_cameras"
  @public [:id, :url, :username, :profile, :transport, :device, :stream]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "WS-Discovery probe; see `Home.Onvif.Discovery.probe/1` for options."
  @spec discover(keyword()) :: [Discovery.t()]
  defdelegate discover(opts \\ []), to: Discovery, as: :probe

  @doc """
  Configure a camera on this node and vend it as a `:video_in` capability.

  `target` is the device service URL (`"http://10.0.0.5/onvif/device_service"`), a
  host (`"10.0.0.5"`, `"10.0.0.5:8080"`; default path), or a `%Home.Onvif.Discovery{}`.

  Options:

    * `:username`, `:password` - the camera's ONVIF (and RTSP) credentials.
    * `:profile` - media profile token, name or index; default the first H.264 one.
    * `:id` - capability id; default `"cam-<host>"` (dots and colons become dashes).
    * `:transport` - RTSP transport, `:tcp` (interleaved, default) or
      `{:udp, first_port, last_port}`.
    * `:meta` - extra capability meta (e.g. `%{name: "Porch"}`).

  Returns `{:ok, {node, id}}`, or `{:error, reason}`: `:unauthorized` (wrong
  credentials), `{:unreachable, reason}`, `:already_exists`, `:no_profiles`,
  `{:unsupported_encoding, enc}`, ...
  """
  @spec add_camera(String.t() | Discovery.t(), keyword()) ::
          {:ok, Home.Capability.ref()} | {:error, term()}
  def add_camera(target, opts \\ []) do
    url = device_url(target)
    username = Keyword.get(opts, :username, "")
    password = Keyword.get(opts, :password, "")
    id = Keyword.get_lazy(opts, :id, fn -> default_id(url) end)

    # The camera round trips run in the caller, not the server.
    with :ok <- unused(id),
         {:ok, info} <- Client.describe(url, username, password, Keyword.get(opts, :profile)) do
      config = %{
        id: id,
        url: url,
        username: username,
        password: password,
        profile: info.profile.token,
        stream_uri: info.stream_uri,
        transport: Keyword.get(opts, :transport, :tcp),
        device: info.device,
        stream: info.profile,
        meta: Keyword.get(opts, :meta, %{})
      }

      GenServer.call(__MODULE__, {:add, config}, 15_000)
    end
  end

  @doc """
  Remove a camera configured on this node: its leases are revoked (holders get
  `{:lease_revoked, ref}`), the stream closes, the capability disappears from every
  node and the configuration is deleted.
  """
  @spec remove_camera(String.t()) :: :ok | {:error, :not_found}
  def remove_camera(id), do: GenServer.call(__MODULE__, {:remove, id}, 15_000)

  @doc "Cameras configured on this node (without passwords)."
  @spec list_cameras() :: [map()]
  def list_cameras do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, config} -> Map.take(config, @public) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Cameras the last periodic discovery found that are not configured here."
  @spec discovered() :: [Discovery.t()]
  def discovered, do: GenServer.call(__MODULE__, :discovered)

  @doc false
  # For `Home.Onvif.Camera` on this node: the RTSP URI with credentials, and transport.
  def stream(id) do
    case :ets.lookup(@table, id) do
      [{^id, config}] ->
        {:ok, %{uri: with_credentials(config), transport: config.transport}}

      [] ->
        {:error, :not_found}
    end
  end

  ## Server

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    cameras = read()
    for {id, config} <- cameras, do: :ets.insert(@table, {id, config})

    state = %{
      every: Keyword.get(opts, :discover_every),
      probe: Keyword.get(opts, :discover, []),
      discovered: [],
      task: nil
    }

    if state.every, do: send(self(), :discover)
    {:ok, state, {:continue, {:start, Map.values(cameras)}}}
  end

  @impl true
  def handle_continue({:start, configs}, state) do
    for config <- configs do
      case Home.Capability.add(capability(config)) do
        {:ok, _} -> :ok
        {:error, :already_exists} -> :ok
        {:error, reason} -> Logger.error("onvif #{config.id}: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:add, config}, _from, state) do
    if :ets.member(@table, config.id) do
      {:reply, {:error, :already_exists}, state}
    else
      :ets.insert(@table, {config.id, config})

      case Home.Capability.add(capability(config)) do
        {:ok, _pid} ->
          write()
          {:reply, {:ok, {node(), config.id}}, state}

        {:error, reason} ->
          :ets.delete(@table, config.id)
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:remove, id}, _from, state) do
    if :ets.member(@table, id) do
      # Revoke and stop first (the adapter still reads the table while stopping).
      _ = Home.Capability.remove(id)
      :ets.delete(@table, id)
      write()
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:discovered, _from, state), do: {:reply, state.discovered, state}

  @impl true
  def handle_info(:discover, %{task: nil} = state) do
    task = Task.async(fn -> Discovery.probe(state.probe) end)
    {:noreply, %{state | task: task}}
  end

  def handle_info(:discover, state), do: {:noreply, state}

  def handle_info({ref, found}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    configured = for {_id, c} <- :ets.tab2list(@table), do: endpoint(c.url)
    new = Enum.reject(found, fn d -> Enum.any?(d.xaddrs, &(endpoint(&1) in configured)) end)

    Phoenix.PubSub.broadcast(Home.PubSub, "onvif", {:onvif_discovered, node(), new})
    Process.send_after(self(), :discover, state.every)
    {:noreply, %{state | task: nil, discovered: new}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("onvif discovery failed: #{inspect(reason)}")
    Process.send_after(self(), :discover, state.every)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Capability

  defp capability(config) do
    stream = config.stream

    meta =
      %{
        source: :onvif,
        codec: :h264,
        w: stream.w,
        h: stream.h,
        fps: stream.fps,
        bitrate: stream.bitrate,
        profile: stream.token,
        manufacturer: config.device[:manufacturer],
        model: config.device[:model],
        firmware: config.device[:firmware_version],
        onvif: config.url
      }
      |> Map.merge(config.meta)

    %Home.Capability{
      id: config.id,
      kind: :video_in,
      availability: :on_request,
      shared: true,
      adapter: Home.Onvif.Camera,
      meta: meta
    }
  end

  ## Helpers

  defp unused(id) do
    if :ets.member(@table, id), do: {:error, :already_exists}, else: :ok
  end

  defp device_url(%Discovery{xaddrs: [xaddr | _]}), do: xaddr

  defp device_url(url) when is_binary(url) do
    if String.contains?(url, "://"), do: url, else: "http://" <> url
  end

  defp default_id(url) do
    uri = URI.parse(url)
    host = if uri.port in [nil, 80], do: uri.host, else: "#{uri.host}:#{uri.port}"
    "cam-" <> String.replace(host, ~r/[^A-Za-z0-9]+/, "-")
  end

  defp endpoint(url) do
    uri = URI.parse(url)
    {uri.host, uri.port}
  end

  defp with_credentials(%{username: user, password: pass, stream_uri: uri})
       when user in [nil, ""] or pass == nil,
       do: uri

  defp with_credentials(%{username: user, password: pass, stream_uri: uri}) do
    case URI.parse(uri) do
      %URI{userinfo: nil} = parsed ->
        userinfo = encode(user) <> ":" <> encode(pass)
        URI.to_string(%{parsed | userinfo: userinfo})

      _has_own ->
        uri
    end
  end

  defp encode(part), do: URI.encode(part, &URI.char_unreserved?/1)

  ## Persistence (this node only: the file holds credentials)

  defp file, do: Path.join(Home.data_dir(), @file_name)

  defp read do
    case File.read(file()) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      {:error, :enoent} -> %{}
    end
  rescue
    e ->
      Logger.error("onvif: unreadable #{file()}: #{Exception.message(e)}")
      %{}
  end

  defp write do
    cameras = Map.new(:ets.tab2list(@table))
    tmp = file() <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(cameras))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, file())
  end
end
