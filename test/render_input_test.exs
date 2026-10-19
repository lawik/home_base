defmodule Home.RenderInputTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.{MediaHelpers, Render, VideoHelpers}

  @moduletag timeout: 120_000
  @moduletag :emerge_inject

  # The counter viewport (`Home.Test.CounterViewport`): a 40x40 button at the top left,
  # red background for even counts, blue for odd.
  @button {20, 20}
  @bg {150, 100}

  defp display,
    do: %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 200, h: 120}}

  setup do
    [{a, _}, {b, _}] =
      start_cluster("m8i",
        a: [device_id: "laptop", capabilities: [], media: [ports: 41_900..41_909]],
        b: [device_id: "kitchen", capabilities: [display()], media: [ports: 41_910..41_919]]
      )

    for n <- [a, b], do: rpc(n, MediaHelpers, :preload)
    %{a: a, b: b}
  end

  test "scene forwarding: B's renderer hit-tests a press against A's tree", %{a: a, b: b} do
    {session, app} = rpc(a, Render, :show, [{b, "disp0"}])
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @bg, &VideoHelpers.red?/1])

    # Raw pointer input into B's renderer, as from a mouse or touchscreen on B: B finds
    # the button (an element id from A's tree) and A's viewport routes the press.
    :ok = rpc(b, Render, :tap, ["disp0", @button])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 1 end)
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @bg, &VideoHelpers.blue?/1])

    :ok = rpc(b, Render, :tap, ["disp0", @bg])
    Process.sleep(300)
    assert rpc(a, Render, :count, [app]) == 1

    :ok = rpc(a, Home.Render, :stop, [session])
  end

  test "pixel forwarding: a click on B is hit-tested on A and fires the element's on_press", %{
    a: a,
    b: b
  } do
    {pixels, app} = rpc(a, Render, :show_pixels, [{b, "disp0"}])
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @bg, &VideoHelpers.red?/1])

    # The press lands on the button in A's headless renderer: the Solve event fires.
    rpc(b, VideoHelpers, :click, ["disp0", @button])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 1 end)
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @bg, &VideoHelpers.blue?/1])

    # Outside the button nothing is pressed.
    rpc(b, VideoHelpers, :click, ["disp0", @bg])
    Process.sleep(300)
    assert rpc(a, Render, :count, [app]) == 1

    rpc(b, VideoHelpers, :click, ["disp0", @button])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 2 end)
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @bg, &VideoHelpers.red?/1])

    # The same through B's own renderer: it reports the raw press, which goes to A.
    :ok = rpc(b, Render, :tap, ["disp0", @button])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 3 end)

    :ok = rpc(a, Home.Render, :stop, [pixels])
  end
end
