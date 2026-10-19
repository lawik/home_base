defmodule Mix.Tasks.Home.Node do
  @shortdoc "Start a named home_base node from a manifest file"
  @moduledoc """
  Start this project's `:home_base` app as a named, distributed node with the
  manifest in `MANIFEST` (an `.exs` file returning `[device_id: ..., capabilities: [...]]`,
  see `examples/`). With `iex -S mix home.node ...` you get a shell on the node;
  without IEx the task keeps running until it is stopped.

      iex -S mix home.node examples/kitchen.exs --name home-kitchen

  Options:

    * `--name NAME` - node name; `@HOST` is added unless given (required)
    * `--host HOST` - host part of the node name (`127.0.0.1`)
    * `--cookie COOKIE` - distribution cookie, the same on every node (`home_demo`)
    * `--backend epmd|static` - peer discovery (`epmd`). `epmd` connects to every node
      in the local epmd whose name starts with the same prefix as this one (up to the
      first `-`, `_` or digit, so `home-kitchen` and `home-laptop` find each other), or
      `--prefix`. `static` connects to `--peers a@host,b@host`.
    * `--media-ports FIRST..LAST` - UDP range this node receives media on
      (`50000..50099`); the address is the host
    * `--data-dir DIR` - where secrets and area persist (a per-node temp dir)
    * `--require FILE` - load an `.exs` file once the node is up (repeatable), e.g.
      `examples/demo.exs`

  epmd is started (`epmd -daemon`) if it isn't running.
  """

  use Mix.Task

  @switches [
    name: :string,
    host: :string,
    cookie: :string,
    backend: :string,
    prefix: :string,
    peers: :string,
    media_ports: :string,
    data_dir: :string,
    require: :keep
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    manifest =
      case argv do
        [path] -> Path.expand(path)
        _ -> Mix.raise("usage: mix home.node MANIFEST --name NAME [options]")
      end

    name = opts[:name] || Mix.raise("--name is required")
    host = opts[:host] || "127.0.0.1"
    node = if String.contains?(name, "@"), do: name, else: "#{name}@#{host}"

    Mix.Task.run("app.config")
    start_distribution(String.to_atom(node), opts[:cookie] || "home_demo")

    env =
      [manifest: {:file, manifest}, cluster: [backend: backend(opts), interval: 2_000]] ++
        if(dir = opts[:data_dir], do: [data_dir: Path.expand(dir)], else: []) ++
        media(opts, host)

    for {key, value} <- env, do: Application.put_env(:home_base, key, value)
    {:ok, _} = Application.ensure_all_started(:home_base)

    caps = for info <- Home.Registry.list(node: node()), do: elem(info.ref, 1)

    Mix.shell().info(
      "#{node()} is up as #{inspect(Home.Registry.device_id())}, vending #{inspect(caps)}"
    )

    for file <- Keyword.get_values(opts, :require), do: Code.require_file(file)

    unless Code.ensure_loaded?(IEx) and IEx.started?(), do: Process.sleep(:infinity)
  end

  defp start_distribution(node, cookie) do
    if Node.alive?() do
      Mix.raise("already distributed as #{node()}; don't also pass --name to iex/elixir")
    end

    System.cmd("epmd", ["-daemon"])

    case :net_kernel.start(node, %{name_domain: :longnames}) do
      {:ok, _} -> Node.set_cookie(String.to_atom(cookie))
      {:error, reason} -> Mix.raise("could not start #{node}: #{inspect(reason)}")
    end
  end

  defp backend(opts) do
    case opts[:backend] || "epmd" do
      "epmd" ->
        if prefix = opts[:prefix],
          do: {Home.Cluster.Epmd, prefix: prefix},
          else: Home.Cluster.Epmd

      "static" ->
        peers =
          (opts[:peers] || "") |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)

        {Home.Cluster.Static, nodes: peers}

      other ->
        Mix.raise("unknown --backend #{other}; use epmd or static")
    end
  end

  defp media(opts, host) do
    ports =
      case opts[:media_ports] do
        nil ->
          []

        range ->
          [first, last] = range |> String.split("..") |> Enum.map(&String.to_integer/1)
          [ports: first..last]
      end

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> [media: [ip: ip] ++ ports]
      {:error, _} -> if ports == [], do: [], else: [media: ports]
    end
  end
end
