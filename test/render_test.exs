defmodule Home.RenderTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.Render

  @red {255, 0, 0, 255}
  @blue {0, 0, 255, 255}
  @green {0, 255, 0, 255}
  # Below the button, image and text: plain background.
  @bg_point {150, 100}

  defp display,
    do: %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 200, h: 120}}

  setup do
    [{a, _}, {b, _}, {c, _}] =
      start_cluster("m4r",
        a: [device_id: "laptop", capabilities: []],
        b: [device_id: "kitchen", capabilities: [display()]],
        c: [device_id: "hall", capabilities: [display()]]
      )

    {session, app} = rpc(a, Render, :show, [{b, "disp0"}, [test: self(), input_events: [:key]]])
    %{a: a, b: b, c: c, session: session, app: app}
  end

  defp pixel(node, point \\ @bg_point), do: rpc(node, Render, :pixel, ["disp0", point])

  defp assert_pixel(node, point \\ @bg_point, expected) do
    eventually(fn -> pixel(node, point) == expected end, 10_000)
  end

  test "an app on A renders on B's display, with its assets", %{
    a: a,
    b: b,
    c: c,
    session: session
  } do
    assert_pixel(b, @red)
    assert_pixel(b, {10, 10}, @green)
    assert rpc(b, Render, :shown, ["disp0"]) == session
    assert node(session) == a
    assert pixel(c) == nil

    # The image and font came over the asset manifest step into B's cache.
    cache = Path.join([rpc(b, Home, :data_dir, []), "render", "assets"])
    cached = rpc(b, File, :ls!, [cache])

    for asset <- ["sample_assets/static.jpg", "test_assets/Lobster-Regular.ttf"] do
      data = File.read!(Path.join(:code.priv_dir(:emerge), asset))
      assert Home.Render.Compositor.hash(data) in cached
    end

    # The image is drawn: its area is not the background colour.
    assert eventually(fn -> pixel(b, {20, 50}) not in [@red, nil] end, 10_000)

    # B's display is leased (shared) by the session.
    assert [%{status: :leased}] = rpc(a, Home.Registry, :list, [[kind: :display, node: b]])
  end

  test "a state change on A shows up on B", %{a: a, b: b, app: app} do
    assert_pixel(b, @red)
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    assert_pixel(b, @blue)
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    assert_pixel(b, @red)
  end

  test "input on B reaches the app on A", %{a: a, b: b, session: session, app: app} do
    assert_pixel(b, @red)
    button = rpc(a, Render, :element_id, [session, :inc])
    comp = rpc(b, Render, :compositor, ["disp0"])

    # An element event, as B's renderer reports a press on the button.
    :ok = rpc(b, Home.Render.Compositor, :input, [comp, {button, :press}])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 1 end)
    assert_pixel(b, @blue)

    # Raw input the app subscribed to (`input: [events: [:key]]`).
    :ok = rpc(b, Home.Render.Compositor, :input, [comp, {:key, {:enter, 1, []}}])
    assert_receive {:app_input, ^a, {:key, {:enter, :press, []}}}, 5_000
  end

  test "move/2 migrates the running app to C; B stops showing it", ctx do
    %{a: a, b: b, c: c, session: session, app: app} = ctx
    assert_pixel(b, @red)
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    assert_pixel(b, @blue)
    viewport = rpc(a, Home.Render.Session, :viewport, [session])

    assert :ok = rpc(a, Home.Render, :move, [session, [to: {c, "disp0"}]])

    # Same app process, same state, now on C.
    assert_pixel(c, @blue)
    assert_pixel(c, {10, 10}, @green)
    assert pixel(c, {20, 50}) not in [@blue, nil]
    assert rpc(a, Home.Render.Session, :viewport, [session]) == viewport
    assert rpc(a, Home.Render, :target, [session]) == {c, "disp0"}

    # B shows nothing and its lease is gone.
    assert rpc(b, Render, :shown, ["disp0"]) == nil
    assert pixel(b) == nil

    assert eventually(fn ->
             match?([%{status: :idle}], rpc(a, Home.Registry, :list, [[kind: :display, node: b]]))
           end)

    # State changes and input now go through C.
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    assert_pixel(c, @red)
    assert pixel(b) == nil

    button = rpc(a, Render, :element_id, [session, :inc])
    comp_c = rpc(c, Render, :compositor, ["disp0"])
    :ok = rpc(c, Home.Render.Compositor, :input, [comp_c, {button, :press}])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 3 end)
    assert_pixel(c, @blue)
  end

  test "a second app on the same display goes on top; the first comes back when it stops", ctx do
    %{a: a, b: b, session: first, app: first_app} = ctx
    assert_pixel(b, @red)

    {second, second_app} = rpc(a, Render, :show, [{b, "disp0"}])
    assert eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == second end)
    :ok = rpc(a, Solve, :dispatch, [second_app, :counter, :increment, nil])
    assert_pixel(b, @blue)

    # The hidden app keeps running; its changes show once it is on top again.
    :ok = rpc(a, Solve, :dispatch, [first_app, :counter, :increment, nil])
    :ok = rpc(a, Solve, :dispatch, [first_app, :counter, :increment, nil])
    :ok = rpc(a, Home.Render, :stop, [second])
    assert eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == first end)
    assert_pixel(b, @red)
    :ok = rpc(a, Solve, :dispatch, [first_app, :counter, :increment, nil])
    assert_pixel(b, @blue)
  end

  test "revoking B's leases stops the session and its app", %{a: a, b: b, session: session} do
    assert_pixel(b, @red)
    viewport = rpc(a, Home.Render.Session, :viewport, [session])
    :ok = rpc(b, Home.Lease, :revoke_all, [])

    assert eventually(fn ->
             not rpc(a, Process, :alive?, [session]) and not rpc(a, Process, :alive?, [viewport])
           end)

    assert eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == nil end)
  end
end
