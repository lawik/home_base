defmodule Home do
  @moduledoc """
  A home cluster node. The `:home_base` application starts it from its app env:

      config :home_base,
        device_id: "nerves-kitchen-01",
        capabilities: [
          %{id: "spk0", kind: :audio_out, adapter: Home.Adapters.Audio.PortAudioOut}
        ],
        cluster: [backend: Home.Cluster.Tailscale],
        data_dir: "/data/home"

  Options:

    * `:device_id` - stable id, also the id used in HA/MQTT discovery. Defaults to the hostname.
    * `:capabilities` - list of `Home.Capability` structs or maps. Or `:manifest` - `{:file, path}`.
    * `:cluster` - `[backend: module | {module, opts}, interval: ms]`. Default `Home.Cluster.Epmd`.
    * `:data_dir` - where secrets, area and other node state persist.
    * `:media` - `[ip: ip_tuple, ports: first..last]`, the address and UDP range media is received on.
    * `:ha` - `[area_refresh: ms, timeout: ms, lookup_timeout: ms]`: how often the area is
      looked up (3 h), the timeout per network step (10 s) and for a whole lookup (3 × timeout).
      HA URL and token come from `Home.Secrets` (`:ha_url`, `:ha_token`).
    * `:watchdog_interval` - lease watchdog sweep interval in ms.
    * `:activity` - `[ring: n]`, how many recent events to keep per capability and kind (64).
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "This node's options, as given to `start_link/1`."
  def config, do: :persistent_term.get({__MODULE__, :config})
  def config(key, default \\ nil), do: Keyword.get(config(), key, default)

  def data_dir do
    dir = config(:data_dir) || Path.join(System.tmp_dir!(), "home_base-#{node()}")
    File.mkdir_p!(dir)
    dir
  end

  @impl true
  def init(opts) do
    manifest =
      case Keyword.fetch(opts, :manifest) do
        {:ok, source} -> Home.Manifest.from_config(source)
        :error -> Home.Manifest.from_config(opts)
      end

    :persistent_term.put({__MODULE__, :config}, Keyword.put(opts, :device_id, manifest.device_id))

    capabilities =
      for cap <- manifest.capabilities, cap.availability != :off do
        Home.Capability.Server.child_spec(cap)
      end

    children = [
      %{id: :pg, start: {:pg, :start_link, [:home]}},
      {Phoenix.PubSub, name: Home.PubSub},
      # Registry reads the HA credentials from Secrets; Activity stamps events with the area.
      Home.Secrets,
      {Task.Supervisor, name: Home.TaskSupervisor},
      {Home.Registry, manifest},
      {Home.Activity, Keyword.get(opts, :activity, [])},
      %{
        id: Home.Capability.Supervisor,
        type: :supervisor,
        start: {Supervisor, :start_link, [capabilities, [strategy: :one_for_one]]}
      },
      {Home.Lease.Watchdog, interval: Keyword.get(opts, :watchdog_interval, 1_000)},
      {DynamicSupervisor, name: Home.Media.Supervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Home.Render.Supervisor, strategy: :one_for_one},
      {Home.Cluster, Keyword.get(opts, :cluster, [])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
