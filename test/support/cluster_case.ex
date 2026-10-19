defmodule Home.Test.ClusterCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Home.Test.Peer
      import Home.Test.ClusterCase
    end
  end

  @doc """
  Start peers named `<prefix><suffix>` with the given Home opts each, all pointed at each
  other with a static peer list, and wait until they are meshed. Returns the node names.
  """
  def start_cluster(prefix, specs) do
    names = for {suffix, _} <- specs, do: :"#{prefix}#{suffix}@127.0.0.1"

    tmp =
      Path.join(System.tmp_dir!(), "home_test_#{prefix}_#{System.unique_integer([:positive])}")

    peers =
      for {{suffix, opts}, node} <- Enum.zip(specs, names) do
        opts =
          [cluster: [source: {Home.Cluster.Static, nodes: names}, interval: 500]]
          |> Keyword.merge(data_dir: Path.join(tmp, to_string(suffix)))
          |> Keyword.merge(opts)

        {peer, ^node} = Home.Test.Peer.start(:"#{prefix}#{suffix}", opts)
        peer
      end

    ExUnit.Callbacks.on_exit(fn -> Enum.each(peers, &Home.Test.Peer.stop/1) end)

    for node <- names do
      Home.Test.Peer.eventually(fn ->
        Enum.all?(names -- [node], &(&1 in Home.Test.Peer.rpc(node, Node, :list)))
      end)
    end

    Enum.zip(names, peers)
  end
end
