defmodule Home.RenderRetainedTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.{Render, VideoHelpers}

  @moduletag timeout: 120_000
  @moduletag :emerge_inject

  @field {50, 15}
  # In the scroll list, 15 px into the first stripe.
  @list {150, 45}

  defp display,
    do: %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 200, h: 120}}

  setup do
    [{a, _}, {b, _}, {c, _}] =
      start_cluster("m8s",
        a: [device_id: "laptop", capabilities: []],
        b: [device_id: "kitchen", capabilities: [display()]],
        c: [device_id: "hall", capabilities: [display()]]
      )

    %{a: a, b: b, c: c}
  end

  defp inject(node, event) do
    comp = rpc(node, Render, :compositor, ["disp0"])
    :ok = rpc(node, Home.Render.Compositor, :inject, [comp, event])
  end

  test "scroll position and focus survive move/2", %{a: a, b: b, c: c} do
    {:ok, session} =
      rpc(a, Home.Render, :show, [{Home.Test.FormViewport, test: self()}, [on: {b, "disp0"}]])

    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @list, &VideoHelpers.red?/1])

    # Scroll the list one stripe down on B.
    inject(b, {:cursor_pos, @list})
    inject(b, {:cursor_scroll, {{0, -30}, @list}})
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @list, &VideoHelpers.blue?/1])

    # Focus the text field and type.
    inject(b, {:cursor_button, {:left, :press, [], @field}})
    inject(b, {:cursor_button, {:left, :release, [], @field}})
    inject(b, {:text_commit, {"x", []}})
    assert_receive {:changed, "x"}, 5_000

    :ok = rpc(a, Home.Render, :move, [session, [to: {c, "disp0"}]])

    # C shows the list where B had it, and the field still has the focus.
    assert rpc(c, VideoHelpers, :await_pixel, ["disp0", @list, &VideoHelpers.blue?/1])
    Process.sleep(200)
    inject(c, {:text_commit, {"y", []}})
    # (The caret is not kept: focus_on_mount puts it at the start.)
    assert_receive {:changed, "yx"}, 5_000

    :ok = rpc(a, Home.Render, :stop, [session])
  end
end
