import Config

# qemu user-mode networking (see README "Networking"). scripts/qemu.sh starts the guest with
# `-netdev user,net=10.0.3.0/24,hostfwd=tcp:127.0.0.1:41470-:4370`, so:
#
#   * the guest is 10.0.3.15 and its node is home@10.0.3.15, listening on 4370;
#   * 10.0.3.2 is the qemu gateway, which slirp maps to the host's 127.0.0.1. Host nodes
#     are therefore named nvN@10.0.3.2 (the address the guest dials), each on its own
#     port since they share one address.
#
# The routes give those host nodes' ports. They are dialed at 10.0.3.2 as named.
host_nodes = %{
  "nv1@10.0.3.2" => {{10, 0, 3, 2}, 41401},
  "nv2@10.0.3.2" => {{10, 0, 3, 2}, 41402}
}

config :home_node, :epmd, port: 4370, routes: host_nodes

config :home_base,
  device_id: "nerves-qemu",
  cluster: [
    backend: {Home.Cluster.Static, nodes: Enum.map(Map.keys(host_nodes), &String.to_atom/1)},
    interval: 5_000
  ]
