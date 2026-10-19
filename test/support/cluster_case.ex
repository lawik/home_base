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

        Process.put({__MODULE__, node}, {:"#{prefix}#{suffix}", opts})
        {peer, ^node} = Home.Test.Peer.start(:"#{prefix}#{suffix}", opts)
        peer
      end

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(peers, &Home.Test.Peer.stop/1)
      File.rm_rf(tmp)
    end)

    for node <- names do
      Home.Test.Peer.eventually(fn ->
        Enum.all?(names -- [node], &(&1 in Home.Test.Peer.rpc(node, Node, :list)))
      end)
    end

    Enum.zip(names, peers)
  end

  @doc """
  Stop a node started by `start_cluster/2` and wait until it is gone. Returns `:ok`.
  """
  def stop_node(node, peer) do
    Home.Test.Peer.stop(peer)
    Home.Test.Peer.eventually(fn -> node not in Node.list() end)
    :ok
  end

  @doc """
  Start `node` again with the name, data dir and opts it had in `start_cluster/2` (merged
  with `extra`). Does not wait for it to mesh. Returns the new peer.
  """
  def start_again(node, extra \\ []) do
    {name, opts} = Process.get({__MODULE__, node})
    {peer, ^node} = Home.Test.Peer.start(name, Keyword.merge(opts, extra))
    ExUnit.Callbacks.on_exit(fn -> Home.Test.Peer.stop(peer) end)
    peer
  end

  @doc "Wait until every node in `nodes` sees all the others."
  def await_mesh(nodes) do
    for node <- nodes do
      Home.Test.Peer.eventually(fn ->
        Enum.all?(nodes -- [node], &(&1 in Home.Test.Peer.rpc(node, Node, :list)))
      end)
    end

    :ok
  end
end
