defmodule Home.RenderLayersTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.Render

  @moduletag timeout: 120_000

  @red {255, 0, 0, 255}
  @blue {0, 0, 255, 255}
  @green {0, 255, 0, 255}
  @yellow {255, 255, 0, 255}
  @bg {150, 100}
  @overlay {190, 10}
  @button {20, 20}

  defp display,
    do: %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 200, h: 120}}

  setup do
    [{a, _}, {b, _}] =
      start_cluster("m8l",
        a: [device_id: "laptop", capabilities: []],
        b: [device_id: "kitchen", capabilities: [display()]]
      )

    %{a: a, b: b}
  end

  defp pixel(b, point), do: rpc(b, Render, :pixel, ["disp0", point])

  defp assert_pixel(b, point, rgba),
    do: assert(eventually(fn -> pixel(b, point) == rgba end, 10_000))

  defp show_overlay(a, b) do
    rpc(a, Home.Render, :show, [
      {Home.Test.OverlayViewport, test: self()},
      [on: {b, "disp0"}, layer: :overlay]
    ])
  end

  test "an overlay is drawn over the app below it; both keep updating", %{a: a, b: b} do
    {base, app} = rpc(a, Render, :show, [{b, "disp0"}])
    assert_pixel(b, @bg, @red)

    {:ok, overlay} = show_overlay(a, b)
    assert_pixel(b, @overlay, @green)
    # The app below still shows (button, background, its assets), and still updates.
    assert_pixel(b, @bg, @red)
    assert_pixel(b, {10, 10}, @green)
    assert eventually(fn -> pixel(b, {20, 50}) not in [@red, nil] end, 10_000)
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    assert_pixel(b, @bg, @blue)
    assert rpc(b, Render, :shown, ["disp0"]) == overlay

    # The overlay goes away: the app below is drawn alone again.
    :ok = rpc(a, Home.Render, :stop, [overlay])
    assert eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == base end)
    assert_pixel(b, @overlay, @blue)
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    assert_pixel(b, @bg, @red)
  end

  test "an ordinary app on top hides the ones below; an overlay over it shows only it", %{
    a: a,
    b: b
  } do
    {_first, first_app} = rpc(a, Render, :show, [{b, "disp0"}])
    :ok = rpc(a, Solve, :dispatch, [first_app, :counter, :increment, nil])
    assert_pixel(b, @bg, @blue)

    {_second, _} = rpc(a, Render, :show, [{b, "disp0"}])
    assert_pixel(b, @bg, @red)
    {:ok, _overlay} = show_overlay(a, b)
    assert_pixel(b, @overlay, @green)
    assert_pixel(b, @bg, @red)
  end

  @tag :emerge_inject
  test "presses go to the layer that was hit", %{a: a, b: b} do
    {_base, app} = rpc(a, Render, :show, [{b, "disp0"}])
    assert_pixel(b, @bg, @red)
    {:ok, _overlay} = show_overlay(a, b)
    assert_pixel(b, @overlay, @green)

    # The base app's button, under the overlay's transparent area.
    :ok = rpc(b, Render, :tap, ["disp0", @button])
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 1 end)
    assert_pixel(b, @bg, @blue)

    # The overlay's button.
    :ok = rpc(b, Render, :tap, ["disp0", @overlay])
    assert_receive {:overlay_pressed, 1}, 5_000
    assert_pixel(b, @overlay, @yellow)
    assert rpc(a, Render, :count, [app]) == 1
  end
end
