defmodule Home.ClusterTest do
  use ExUnit.Case, async: false

  import Home.Test.Peer

  test "Tailscale status parsing keeps online tagged peers, IPv4 first" do
    status = %{
      "Peer" => %{
        "a" => %{
          "Online" => true,
          "Tags" => ["tag:homecluster"],
          "TailscaleIPs" => ["fd7a::1", "100.64.0.1"]
        },
        "b" => %{
          "Online" => false,
          "Tags" => ["tag:homecluster"],
          "TailscaleIPs" => ["100.64.0.2"]
        },
        "c" => %{"Online" => true, "Tags" => ["tag:other"], "TailscaleIPs" => ["100.64.0.3"]},
        "d" => %{"Online" => true, "TailscaleIPs" => ["100.64.0.4"]}
      }
    }

    assert Home.Cluster.Tailscale.parse(status) == [:"home@100.64.0.1"]
  end

  test "three nodes find each other via epmd, and a restarted node rejoins" do
    prefix = "m0#{System.pid()}"
    names = for s <- ~w(a b c), do: :"#{prefix}#{s}"
    opts = fn -> [cluster: [backend: {Home.Cluster.Epmd, prefix: prefix}, interval: 500]] end
    peers = for n <- names, do: start(n, opts.())
    nodes = Enum.map(peers, &elem(&1, 1))

    try do
      for node <- nodes do
        eventually(fn ->
          Enum.sort(rpc(node, Node, :list) -- [node()]) == Enum.sort(nodes -- [node])
        end)
      end

      # Stop one; start a fresh node with the same name; everybody reconnects.
      [{pb, nb} | _] = Enum.drop(peers, 1)
      stop(pb)
      eventually(fn -> nb not in rpc(hd(nodes), Node, :list) end)
      {pb2, ^nb} = start(Enum.at(names, 1), opts.())

      eventually(fn -> nb in rpc(hd(nodes), Node, :list) end)
      eventually(fn -> List.last(nodes) in rpc(nb, Node, :list) end)
      stop(pb2)
    after
      Enum.each(peers, fn {p, _} -> stop(p) end)
    end
  end
end
