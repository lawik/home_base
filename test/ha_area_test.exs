defmodule Home.HAAreaTest do
  use Home.Test.ClusterCase, async: false

  alias Home.{Registry, Secrets}
  alias Home.Test.FakeHA

  @token "long-lived-token"

  defp caps, do: [%{id: "spk0", kind: :audio_out, adapter: Home.Test.FakeAdapter}]

  defp area(node), do: rpc(node, Registry, :area)

  defp refs(node, filters) do
    for info <- rpc(node, Registry, :list, [filters]), do: info.ref
  end

  setup do
    ha =
      FakeHA.start(
        free_port(),
        @token,
        [{"m3-dev-a", "kitchen"}, {"m3-dev-b", "living_room"}, {"m3-dev-c", nil}],
        [{"kitchen", "Kitchen"}, {"living_room", "Living Room"}, {"office", "Office"}]
      )

    on_exit(fn -> FakeHA.stop(ha) end)

    opts = fn id -> [device_id: id, capabilities: caps(), ha: [timeout: 1_000]] end

    nodes =
      start_cluster("m3h",
        a: opts.("m3-dev-a"),
        b: opts.("m3-dev-b"),
        c: opts.("m3-dev-c"),
        d: opts.("m3-dev-not-in-ha")
      )

    %{ha: ha, nodes: Enum.map(nodes, &elem(&1, 0)), peers: Map.new(nodes)}
  end

  defp provision(node, ha) do
    :ok = rpc(node, Secrets, :put, [:ha_url, ha.url])
    :ok = rpc(node, Secrets, :put, [:ha_token, @token])
  end

  test "each node resolves its own area with the shared token, area-scoped lists skip nil",
       %{ha: ha, nodes: [a, b, c, d] = nodes} do
    # No credentials yet: everyone is a full peer without an area.
    for n <- nodes, do: assert(area(n) == nil)
    assert rpc(a, Registry, :refresh_area) == {:error, :no_ha_credentials}
    assert length(refs(a, kind: :audio_out)) == 4
    assert refs(a, kind: :audio_out, area: "Kitchen") == []

    # Credentials are put on one node; every node looks itself up when they arrive.
    provision(d, ha)
    eventually(fn -> area(a) == "Kitchen" and area(b) == "Living Room" end)

    # c is in HA without an area; d is not in HA at all. Both stay nil.
    assert rpc(c, Registry, :refresh_area) == {:ok, nil}
    assert rpc(d, Registry, :refresh_area) == {:error, {:device_not_found, "m3-dev-not-in-ha"}}
    assert area(c) == nil and area(d) == nil

    for n <- nodes do
      assert refs(n, kind: :audio_out, area: "Kitchen") == [{a, "spk0"}]
      assert refs(n, kind: :audio_out, area: "Living Room") == [{b, "spk0"}]
      assert length(refs(n, kind: :audio_out)) == 4
    end

    # The two HA commands, once each per lookup (lookups from several nodes interleave).
    reqs = Enum.frequencies(FakeHA.requests(ha))
    assert Map.keys(reqs) == ["config/area_registry/list", "config/device_registry/list"]
    assert reqs["config/area_registry/list"] == reqs["config/device_registry/list"]
  end

  test "refresh_area picks up a move in HA, and other nodes see it", %{ha: ha, nodes: [a, b | _]} do
    provision(a, ha)
    eventually(fn -> area(a) == "Kitchen" and area(b) == "Living Room" end)
    assert refs(a, kind: :audio_out, area: "Kitchen") == [{a, "spk0"}]

    FakeHA.move(ha, "m3-dev-b", "kitchen")
    assert rpc(b, Registry, :refresh_area) == {:ok, "Kitchen"}
    assert area(b) == "Kitchen"
    # a's cached view of b's capability is dropped on {:area_changed, ...}.
    assert refs(a, kind: :audio_out, area: "Kitchen") == [{a, "spk0"}, {b, "spk0"}]

    # A new area created in HA, then a move into it.
    FakeHA.put_area(ha, "garage", "Garage")
    FakeHA.move(ha, "m3-dev-a", "garage")
    assert rpc(a, Registry, :refresh_area) == {:ok, "Garage"}
    assert refs(b, kind: :audio_out, area: "Garage") == [{a, "spk0"}]
  end

  test "HA down or unreachable: the node keeps its last known area", %{ha: ha, nodes: [a | _]} do
    provision(a, ha)
    eventually(fn -> area(a) == "Kitchen" end)

    FakeHA.down(ha)

    assert {:error, %Mint.TransportError{reason: :econnrefused}} =
             rpc(a, Registry, :refresh_area)

    assert area(a) == "Kitchen"

    # A token that HA rejects also keeps the old area.
    ha = FakeHA.up(ha)
    :ok = rpc(a, Secrets, :put, [:ha_token, "wrong"])

    assert rpc(a, Registry, :refresh_area) ==
             {:error, {:auth_invalid, "Invalid access token or password"}}

    assert area(a) == "Kitchen"

    # Fixing the token anywhere triggers a lookup everywhere.
    FakeHA.move(ha, "m3-dev-a", "office")
    :ok = rpc(a, Secrets, :put, [:ha_token, @token])
    eventually(fn -> area(a) == "Office" end)
  end

  test "an HA that accepts but never answers times out without wedging the registry",
       %{nodes: [a | _]} do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    acceptor = spawn(fn -> accept_forever(listen) end)
    on_exit(fn -> Process.exit(acceptor, :kill) end)

    :ok = rpc(a, Registry, :put_area, ["Kitchen"])
    {:ok, hung_port} = :inet.port(listen)
    :ok = rpc(a, Secrets, :put, [:ha_url, "http://127.0.0.1:#{hung_port}"])
    :ok = rpc(a, Secrets, :put, [:ha_token, @token])

    {us, result} = :timer.tc(fn -> rpc(a, Registry, :refresh_area) end)
    assert result == {:error, %Mint.TransportError{reason: :timeout}}
    assert us < 5_000_000
    assert area(a) == "Kitchen"
    # The registry kept serving while it waited.
    assert [_ | _] = refs(a, kind: :audio_out)
  end

  defp accept_forever(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, _sock} -> accept_forever(listen)
      {:error, _} -> :ok
    end
  end

  test "area persists across a restart, even with HA down", %{
    ha: ha,
    nodes: [a, b | _] = nodes,
    peers: peers
  } do
    provision(a, ha)
    eventually(fn -> area(b) == "Living Room" end)

    FakeHA.down(ha)
    :ok = stop_node(b, peers[b])
    peer = start_again(b)
    assert area(b) == "Living Room"
    await_mesh(nodes)
    assert refs(a, kind: :audio_out, area: "Living Room") == [{b, "spk0"}]

    # HA back with b moved: the next lookup (here: explicit) updates and persists it.
    ha = FakeHA.up(ha)
    FakeHA.move(ha, "m3-dev-b", "office")
    assert rpc(b, Registry, :refresh_area) == {:ok, "Office"}
    :ok = stop_node(b, peer)
    FakeHA.down(ha)
    start_again(b)
    assert area(b) == "Office"
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end
end
