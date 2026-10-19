defmodule Home.IndicatorTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.{Holders, IndicatorHelpers, Render}

  setup do
    me = self()

    kitchen = [
      device_id: "kitchen",
      capabilities: [
        %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 320, h: 120}},
        %{
          id: "mic0",
          kind: :audio_in,
          availability: :on_request,
          adapter: Home.Test.FakeAdapter,
          meta: %{notify: me}
        }
      ]
    ]

    laptop = [
      device_id: "laptop",
      capabilities: [
        %{
          id: "cam0",
          kind: :video_in,
          availability: :on_request,
          adapter: Home.Test.FakeAdapter,
          meta: %{notify: me}
        }
      ]
    ]

    [{k, _}, {l, lp}] = start_cluster("m9i", k: kitchen, l: laptop)
    %{k: k, l: l, laptop_peer: lp}
  end

  defp leases(node, app), do: rpc(node, IndicatorHelpers, :leases, [app])

  defp await_leases(node, app, fun) do
    eventually(fn ->
      state = leases(node, app)
      fun.(state) && state
    end)
  end

  defp hold(node, cap, purpose) do
    holder = Node.spawn(node, Holders, :holder, [self(), cap, [purpose: purpose]])
    assert_receive {:lease, ^holder, {:ok, _lease}}, 5_000
    holder
  end

  test "state follows leases, hardware and capabilities; revoke_all acts on its own node",
       %{k: k, l: l, laptop_peer: laptop_peer} do
    {:ok, app} = rpc(k, IndicatorHelpers, :start_app, [])
    assert %{node: ^k, in_use: [], idle: 3} = leases(k, app)

    # The laptop takes the kitchen mic: on, held by the laptop.
    hold(l, {k, "mic0"}, "intercom")
    assert_receive {:fake_hw, "mic0", :on}

    %{in_use: [mic]} = await_leases(k, app, &match?(%{in_use: [_]}, &1))

    assert %{
             ref: {^k, "mic0"},
             kind: :audio_in,
             device: "kitchen",
             hardware: :on,
             holders: [%{node: ^l, name: "laptop", purpose: "intercom"}]
           } = mic

    # The kitchen takes the laptop camera too.
    hold(k, {l, "cam0"}, "doorbell")
    %{in_use: [_mic, cam]} = await_leases(k, app, &match?(%{in_use: [_, _]}, &1))
    assert %{ref: {^l, "cam0"}, holders: [%{name: "kitchen", purpose: "doorbell"}]} = cam

    # Revoke all on the kitchen: its mic goes off; the laptop's camera is not its to revoke.
    :ok = rpc(k, Solve, :dispatch, [app, :leases, :revoke_all, nil])
    assert_receive {:fake_hw, "mic0", :off}
    %{in_use: [cam]} = await_leases(k, app, &match?(%{in_use: [_]}, &1))
    assert cam.ref == {l, "cam0"}

    # Capabilities going away (the whole laptop) drop out.
    :ok = stop_node(l, laptop_peer)
    assert %{in_use: [], idle: 2} = await_leases(k, app, &(&1.in_use == []))
  end

  test "shown on a display: it lists what is in use, and its button revokes", %{k: k, l: l} do
    {:ok, keeper} = rpc(k, IndicatorHelpers, :start_keeper, [[on: {k, "disp0"}, retry: 200]])
    session = eventually(fn -> rpc(k, Home.Indicator, :session, [keeper]) end)
    assert node(session) == k

    # It doesn't list its own display lease.
    eventually(fn -> "Nothing in use" in rpc(k, IndicatorHelpers, :texts, [session]) end)
    eventually(fn -> rpc(k, Render, :shown, ["disp0"]) == session end)

    # Drawn: the dark background and the red button.
    eventually(fn -> rpc(k, Render, :pixel, ["disp0", {2, 118}]) == {15, 23, 43, 255} end)
    assert rpc(k, IndicatorHelpers, :count_pixels, ["disp0", {231, 0, 11}]) > 200

    hold(l, {k, "mic0"}, "intercom")
    assert_receive {:fake_hw, "mic0", :on}

    eventually(fn ->
      texts = rpc(k, IndicatorHelpers, :texts, [session])
      "1 in use" in texts and "mic0 on kitchen, on: held by laptop, intercom" in texts
    end)

    # A press on "Revoke all", as the display reports it.
    button = rpc(k, Render, :element_id, [session, :revoke_all])
    comp = rpc(k, Render, :compositor, ["disp0"])
    :ok = rpc(k, Home.Render.Compositor, :input, [comp, {button, :press}])

    assert_receive {:fake_hw, "mic0", :off}, 5_000

    assert eventually(fn ->
             match?(
               [%{status: :idle, hardware: :off}],
               rpc(l, Home.Registry, :list, [[kind: :audio_in]])
             )
           end)

    # That revoked the indicator's own display lease too; the keeper puts it back.
    new =
      eventually(fn -> (s = rpc(k, Home.Indicator, :session, [keeper])) && s != session && s end)

    eventually(fn -> "Nothing in use" in rpc(k, IndicatorHelpers, :texts, [new]) end)
    eventually(fn -> rpc(k, Render, :shown, ["disp0"]) == new end)
  end
end
