defmodule Home.LeaseTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Lease

  defp caps(notify) do
    [
      %{
        id: "mic0",
        kind: :audio_in,
        availability: :on_request,
        adapter: Home.Test.FakeAdapter,
        meta: %{notify: notify},
        max_age: 300
      },
      %{id: "spk0", kind: :audio_out, adapter: Home.Test.FakeAdapter, meta: %{notify: notify}}
    ]
  end

  setup do
    me = self()

    [{a, _}, {b, _}] =
      start_cluster("m1",
        a: [device_id: "dev-a", capabilities: caps(me)],
        b: [device_id: "dev-b", capabilities: caps(me)]
      )

    # :always speakers come up on at boot.
    assert_receive {:fake_hw, "spk0", :on}
    assert_receive {:fake_hw, "spk0", :on}
    refute_receive {:fake_hw, "mic0", _}, 100
    %{a: a, b: b}
  end

  test "registry lists capabilities from any node", %{a: a, b: b} do
    for n <- [a, b] do
      outs =
        eventually(fn ->
          match?([_, _], l = rpc(n, Home.Registry, :list, [[kind: :audio_out]])) && l
        end)

      assert Enum.map(outs, & &1.ref) == Enum.sort([{a, "spk0"}, {b, "spk0"}])
      assert Enum.all?(outs, &(&1.hardware == :on and &1.status == :idle))
    end

    assert [%{ref: {^b, "mic0"}, hardware: :off, device_id: "dev-b"}] =
             rpc(a, Home.Registry, :list, [[kind: :audio_in, node: b]])
  end

  test "on-request mic: on at acquire, off at release; exclusive; events broadcast", %{a: a, b: b} do
    me = self()
    Node.spawn(a, Home.Test.Holders, :relay, [me, "leases"])
    assert_receive {:subscribed, relay}

    Node.spawn(a, Home.Test.Holders, :holder, [me, {b, "mic0"}, [purpose: "intercom"]])

    assert_receive {:lease, holder,
                    {:ok, %Lease{cap: {^b, "mic0"}, endpoint: {:fake, "mic0"}} = lease}}

    assert node(holder) == a
    assert_receive {:fake_hw, "mic0", :on}
    assert_receive {:relayed, {:hardware, {^b, "mic0"}, :on}}
    assert_receive {:relayed, {:lease, :acquired, %{cap: {^b, "mic0"}, purpose: "intercom"}}}

    # Exclusive: a second acquire is refused.
    assert {:error, :busy} = rpc(a, Lease, :acquire, [{b, "mic0"}])

    :ok = rpc(a, Lease, :release, [lease])
    assert_receive {:fake_hw, "mic0", :off}
    assert_receive {:relayed, {:lease, :released, _}}
    send(relay, :stop)
  end

  test "holder death and holder node death release the lease and close the mic", %{a: a, b: b} do
    me = self()
    Node.spawn(a, Home.Test.Holders, :holder, [me, {b, "mic0"}])
    assert_receive {:lease, holder, {:ok, _}}
    assert_receive {:fake_hw, "mic0", :on}
    Process.exit(holder, :kill)
    assert_receive {:fake_hw, "mic0", :off}

    # Holder on another node; that whole node goes away.
    [{c, cpeer}] = start_cluster("m1x", c: [capabilities: []])
    rpc(c, Node, :connect, [b])
    Node.spawn(c, Home.Test.Holders, :holder, [me, {b, "mic0"}])
    assert_receive {:lease, _, {:ok, _}}
    assert_receive {:fake_hw, "mic0", :on}
    stop(cpeer)
    assert_receive {:fake_hw, "mic0", :off}, 5_000
  end

  test "watchdog expires leases past max age unless renewed", %{a: a, b: b} do
    me = self()

    renewer = Node.spawn(a, Home.Test.Holders, :renewer, [me, {b, "mic0"}, 100])

    assert_receive {:got, lease}
    assert_receive {:fake_hw, "mic0", :on}
    # max_age is 300 ms; renewing every 100 ms keeps it alive for well past that.
    refute_receive {:fake_hw, "mic0", :off}, 1_200
    send(renewer, :stop_renewing)
    assert_receive {:fake_hw, "mic0", :off}, 2_000
    assert_receive {:holder_got, {:lease_expired, ref}}
    assert ref == lease.ref
  end

  test "revoke_all drops every lease on the node and closes on-request hardware", %{a: a, b: b} do
    me = self()

    Node.spawn(a, Home.Test.Holders, :multi, [me, [{b, "mic0"}, {b, "spk0"}, {b, "spk0"}], 3])

    assert_receive :acquired
    assert_receive {:fake_hw, "mic0", :on}
    assert [%{leases: 2}] = rpc(a, Home.Registry, :list, [[kind: :audio_out, node: b]])
    :ok = rpc(b, Lease, :revoke_all)
    for _ <- 1..3, do: assert_receive({:lease_revoked, _})
    assert_receive {:fake_hw, "mic0", :off}
    # :always hardware stays on.
    refute_received {:fake_hw, "spk0", :off}
  end
end
