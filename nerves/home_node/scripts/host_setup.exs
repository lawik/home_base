# Start this BEAM as a home cluster member on the dev host, next to the qemu guest.
# Required by host_node.exs and demo.exs; run those via `mix run --no-start` from the
# home_base repo root so home_base and its deps are on the code path.
#
# Naming (see README "Networking"): host nodes are nvN@10.0.3.2, the address the qemu guest
# dials to reach the host, each listening on 127.0.0.1:4140N. The guest is home@10.0.3.15,
# reached through the hostfwd on 127.0.0.1:41470. HomeNode.Epmd routes both.
#
# Media (README "Media across qemu NAT"): host node nvN receives on 127.0.0.1, UDP ports
# 41420 + 10 * N .. +9 (nv1: 41430-41439, nv2: 41440-41449; N <= 5), and sends to the guest's
# advertised 10.0.3.15 through the hostfwd on 127.0.0.1 (same port numbers, 41480-41489).

Code.require_file("../lib/home_node/epmd.ex", __DIR__)

defmodule HostNode do
  @guest :"home@10.0.3.15"
  @host_ip "10.0.3.2"
  @cookie :home_cluster_cookie

  def guest, do: @guest
  def name(n), do: :"nv#{n}@#{@host_ip}"
  def port(n), do: 41400 + n
  def media_ports(n), do: (41420 + 10 * n)..(41429 + 10 * n)

  def media(n),
    do: [ip: {127, 0, 0, 1}, ports: media_ports(n), routes: %{{10, 0, 3, 15} => {127, 0, 0, 1}}]

  def routes(guest_port) do
    host = for n <- 1..9, into: %{}, do: {"nv#{n}@#{@host_ip}", {{127, 0, 0, 1}, port(n)}}
    Map.put(host, Atom.to_string(@guest), {{127, 0, 0, 1}, guest_port})
  end

  @doc "Start distribution as nvN and then home_base with `capabilities`."
  def start(n, capabilities, peers \\ [1, 2]) do
    guest_port = String.to_integer(System.get_env("HOME_NODE_DIST_PORT", "41470"))

    Application.put_env(:kernel, :epmd_module, HomeNode.Epmd)
    Application.put_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
    Application.put_env(:home_node, :epmd, routes: routes(guest_port))

    {:ok, _} = Node.start(name(n), :longnames)
    Node.set_cookie(@cookie)

    data_dir = Path.join(System.tmp_dir!(), "home_node_demo/nv#{n}")
    File.rm_rf!(data_dir)

    Application.load(:home_base)

    for {k, v} <- [
          device_id: "host-nv#{n}",
          data_dir: data_dir,
          capabilities: capabilities,
          media: media(n),
          cluster: [
            backend: {Home.Cluster.Static, nodes: [@guest | Enum.map(peers, &name/1)]},
            interval: 2_000
          ]
        ],
        do: Application.put_env(:home_base, k, v)

    {:ok, _} = Application.ensure_all_started(:home_base)
    node()
  end
end
