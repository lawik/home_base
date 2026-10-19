defmodule Home.SecretsTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Secrets

  defp data(node), do: rpc(node, Secrets, :snapshot).data

  defp converged?(nodes, expected) do
    Enum.all?(nodes, &(data(&1) == expected))
  end

  setup do
    nodes =
      start_cluster("m3s", a: [capabilities: []], b: [capabilities: []], c: [capabilities: []])

    %{nodes: Enum.map(nodes, &elem(&1, 0)), peers: Map.new(nodes)}
  end

  test "put and delete on one node reach every node", %{nodes: [a, b, c] = nodes} do
    :ok = rpc(b, Secrets, :put, [:ha_url, "http://ha.local:8123"])
    :ok = rpc(b, Secrets, :put, [:ha_token, "t0k3n"])
    eventually(fn -> converged?(nodes, %{ha_url: "http://ha.local:8123", ha_token: "t0k3n"}) end)
    assert rpc(c, Secrets, :get, [:ha_token]) == "t0k3n"
    assert rpc(a, Secrets, :fetch, [:nope]) == :error

    # Rotation from another node.
    :ok = rpc(c, Secrets, :put, [:ha_token, "rotated"])
    :ok = rpc(a, Secrets, :delete, [:ha_url])
    eventually(fn -> converged?(nodes, %{ha_token: "rotated"}) end)
    assert rpc(b, Secrets, :version, []) == rpc(a, Secrets, :version, [])
  end

  test "late joiner gets the current set", %{nodes: [a, b, _c]} do
    :ok = rpc(a, Secrets, :put, [:mqtt_password, "hunter2"])
    :ok = rpc(b, Secrets, :put, [:api_key, "k"])
    eventually(fn -> data(a) == %{mqtt_password: "hunter2", api_key: "k"} end)

    # (d may already be meshed through the test node by global's connect_all.)
    [{d, _}] = start_cluster("m3sx", d: [capabilities: []])
    true = rpc(d, Node, :connect, [a])
    eventually(fn -> data(d) == %{mqtt_password: "hunter2", api_key: "k"} end)
  end

  test "concurrent puts on different nodes converge without losing keys", %{nodes: nodes} do
    # Every node writes its own keys and a shared key at the same time, many rounds.
    for round <- 1..20 do
      nodes
      |> Enum.map(fn n ->
        Task.async(fn ->
          :ok = rpc(n, Secrets, :put, [{:own, n}, round])
          :ok = rpc(n, Secrets, :put, [:shared, {n, round}])
        end)
      end)
      |> Task.await_many()
    end

    eventually(fn ->
      sets = Enum.map(nodes, &data/1)
      Enum.uniq(sets) |> length() == 1
    end)

    set = data(hd(nodes))
    for n <- nodes, do: assert(set[{:own, n}] == 20)
    assert {_, 20} = set[:shared]
    assert length(Enum.uniq(Enum.map(nodes, &rpc(&1, Secrets, :version, [])))) == 1
  end

  test "a put on a node that is behind still lands", %{nodes: [a, b, c] = nodes, peers: peers} do
    :ok = rpc(a, Secrets, :put, [:ha_url, "http://old"])
    eventually(fn -> converged?(nodes, %{ha_url: "http://old"}) end)

    # b is away while a bumps the version a few times.
    :ok = stop_node(b, peers[b])
    for i <- 1..5, do: :ok = rpc(a, Secrets, :put, [:ha_url, "http://new#{i}"])

    # Everyone but b goes down too; b comes back alone with its older set (from disk)
    # and takes a put there.
    :ok = stop_node(a, peers[a])
    :ok = stop_node(c, peers[c])
    start_again(b)
    assert data(b) == %{ha_url: "http://old"}
    :ok = rpc(b, Secrets, :put, [:ha_token, "from-b"])

    # The others return: b's newer key and a's newer url both survive, everywhere.
    start_again(a)
    start_again(c)
    await_mesh(nodes)
    eventually(fn -> converged?(nodes, %{ha_url: "http://new5", ha_token: "from-b"}) end)
  end

  test "survives restart: a node boots with its last set, then converges",
       %{nodes: [a, b, c] = nodes, peers: peers} do
    :ok = rpc(a, Secrets, :put, [:ha_token, "one"])
    eventually(fn -> converged?(nodes, %{ha_token: "one"}) end)

    # Restart every node at once; with nobody to ask, each must read its own disk.
    for n <- nodes, do: :ok = stop_node(n, peers[n])
    start_again(c)
    assert data(c) == %{ha_token: "one"}

    :ok = rpc(c, Secrets, :put, [:ha_token, "two"])
    start_again(a)
    start_again(b)
    await_mesh(nodes)
    eventually(fn -> converged?(nodes, %{ha_token: "two"}) end)
  end

  test "older or equal remote sets are ignored, newer keys are taken", %{nodes: [a | _]} do
    :ok = rpc(a, Secrets, :put, [:k, "mine"])
    pid = rpc(a, Process, :whereis, [Secrets])

    # A stale peer's view: an old :k and a key nobody here has seen.
    send(
      pid,
      {:secrets, %{k: {{0, :ghost@nowhere}, {:ok, "old"}}, x: {{1, :ghost@nowhere}, {:ok, 1}}}}
    )

    eventually(fn -> data(a) == %{k: "mine", x: 1} end)

    # Same counter, higher node name wins the tie.
    {n, _} = rpc(a, Secrets, :version, [])
    send(pid, {:secrets, %{k: {{n, :zzz@nowhere}, {:ok, "tie"}}}})
    eventually(fn -> data(a)[:k] == "tie" end)

    # A newer tombstone deletes.
    send(pid, {:secrets, %{x: {{n + 1, :ghost@nowhere}, :deleted}}})
    eventually(fn -> data(a) == %{k: "tie"} end)
  end
end
