defmodule Home.RenderInputCapTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.Render

  @moduletag timeout: 120_000

  @red {255, 0, 0, 255}
  @blue {0, 0, 255, 255}

  defp caps do
    [
      %{
        id: "disp0",
        kind: :display,
        adapter: {Home.Adapters.Display, input: "input0"},
        meta: %{w: 200, h: 120}
      },
      %{id: "input0", kind: :input, adapter: Home.Adapters.Input}
    ]
  end

  setup do
    [{a, _}, {b, _}] =
      start_cluster("m8c",
        a: [device_id: "laptop", capabilities: []],
        b: [device_id: "kitchen", capabilities: caps()]
      )

    %{a: a, b: b}
  end

  defp input(b, event) do
    comp = rpc(b, Render, :compositor, ["disp0"])
    :ok = rpc(b, Home.Render.Compositor, :input, [comp, event])
  end

  defp holder_of(a, b) do
    case rpc(a, Home.Registry, :list, [[kind: :input, node: b]]) do
      [%{status: status}] -> status
    end
  end

  defp pixel(b), do: rpc(b, Render, :pixel, ["disp0", {150, 100}])

  test "showing an app leases the display's input; input follows the lease", %{a: a, b: b} do
    {first, first_app} =
      rpc(a, Render, :show, [{b, "disp0"}, [test: self(), input_events: [:key]]])

    assert eventually(fn -> pixel(b) == @red end, 10_000)
    assert eventually(fn -> holder_of(a, b) == :leased end)

    button = rpc(a, Render, :element_id, [first, :inc])
    input(b, {button, :press})
    assert eventually(fn -> rpc(a, Render, :count, [first_app]) == 1 end)

    # A second app goes on top of the display, but the input is held by the first: raw
    # input still goes to the first; element events (ids of the drawn tree) to nobody.
    {second, second_app} =
      rpc(a, Render, :show, [{b, "disp0"}, [test: self(), input_events: [:key]]])

    assert eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == second end)

    input(b, {:key, {:enter, 1, []}})
    assert_receive {:app_input, ^a, {:key, {:enter, :press, []}}}, 5_000
    refute_receive {:app_input, _, _}, 300
    second_button = rpc(a, Render, :element_id, [second, :inc])
    input(b, {second_button, :press})
    Process.sleep(300)
    assert rpc(a, Render, :count, [second_app]) == 0

    # When the first app stops, the second gets the input lease.
    :ok = rpc(a, Home.Render, :stop, [first])
    input_lease = fn -> rpc(a, :sys, :get_state, [second]).input end

    assert eventually(
             fn -> rpc(a, Home.Render.InputLease, :lease, [input_lease.()]) != nil end,
             5_000
           )

    input(b, {second_button, :press})
    assert eventually(fn -> rpc(a, Render, :count, [second_app]) == 1 end)
    assert eventually(fn -> pixel(b) == @blue end)

    :ok = rpc(a, Home.Render, :stop, [second])
    assert eventually(fn -> holder_of(a, b) == :idle end)
  end

  test "any process can hold the input; the shown app then gets none", %{a: a, b: b} do
    test = self()
    holder = Node.spawn(a, Home.Test.InputHolder, :run, [test, {b, "input0"}])
    assert_receive {:input_holder, ^holder, _lease}, 5_000

    {session, app} = rpc(a, Render, :show, [{b, "disp0"}, [test: self(), input_events: [:key]]])
    assert eventually(fn -> pixel(b) == @red end, 10_000)

    input(b, {:key, {:enter, 1, []}})
    assert_receive {:home_render_input, _comp, {:key, {:enter, 1, []}}}, 5_000
    refute_receive {:app_input, _, _}, 300

    button = rpc(a, Render, :element_id, [session, :inc])
    input(b, {button, :press})
    Process.sleep(300)
    assert rpc(a, Render, :count, [app]) == 0

    # Released: the session takes the input over.
    send(holder, :release)
    Process.sleep(1_500)
    input(b, {button, :press})
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 1 end)
    refute_received {:home_render_input, _, _}
  end

  test "revoking the input lease takes input away, not the display", %{a: a, b: b} do
    {session, app} = rpc(a, Render, :show, [{b, "disp0"}])
    assert eventually(fn -> pixel(b) == @red end, 10_000)
    assert eventually(fn -> holder_of(a, b) == :leased end)

    # Revoke just the input capability's leases.
    {:ok, server} = rpc(b, Home.Registry, :whereis, [{b, "input0"}])
    :ok = GenServer.call(server, :revoke_all)

    button = rpc(a, Render, :element_id, [session, :inc])
    input(b, {button, :press})
    assert rpc(a, Process, :alive?, [session])
    # It is taken again on the next retry, and input flows.
    assert eventually(fn -> holder_of(a, b) == :leased end, 5_000)
    Process.sleep(200)
    input(b, {button, :press})
    assert eventually(fn -> rpc(a, Render, :count, [app]) >= 1 end)
  end
end
