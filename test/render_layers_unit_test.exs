defmodule Home.RenderLayersUnitTest do
  use ExUnit.Case, async: true
  use Emerge.UI

  import Bitwise

  alias Emerge.Engine
  alias Emerge.Engine.{NodeId, Patch}
  alias Home.Render.Layers

  defp tree(text, img \\ "images/a.png") do
    column([key(:root)], [el([key(:t)], text(text)), image([key(:i)], img)])
  end

  test "full trees and patches are moved into the layer's id space" do
    {full, ds, assigned} = Engine.encode_full(Engine.diff_state_new(), tree("a"))
    {root, layered} = Layers.full(full, 3)
    assert root == (3 <<< 48 ||| assigned.id)
    assert Enum.all?(layered.children, &(&1.id >>> 48 == 3))

    # Image paths get the layer prefix.
    assert [_, %{attrs: %{image_src: "3/images/a.png"}}] = layered.children

    {bin, _ds, _} = Engine.diff_state_update(ds, tree("b", "images/b.png"))
    {ops, nil} = Layers.patch(bin, 3)
    assert ops != []

    for op <- ops do
      assert elem(op, 1) >>> 48 == 3

      if match?({:set_attrs, _, %{image_src: _}}, op),
        do: assert(elem(op, 2).image_src == "3/images/b.png")
    end

    # Encodes back to a valid patch stream.
    assert is_list(Patch.decode(Layers.encode(ops)))
  end

  test "a new root comes back to be mounted" do
    {_full, ds, _} = Engine.encode_full(Engine.diff_state_new(), tree("a"))
    {bin, _ds, _} = Engine.diff_state_update(ds, row([key(:other)], [text("x")]))
    assert {ops, {:new_root, %{id: id}}} = Layers.patch(bin, 2)
    assert id >>> 48 == 2
    assert Enum.any?(ops, &match?({:remove, _}, &1))
  end

  test "element events map back to the layer and the session's id" do
    composed = NodeId.encode(5 <<< 48 ||| 42)
    assert Layers.route_event({composed, :press}) == {5, {NodeId.encode(42), :press}}
    assert Layers.route_event({composed, :change, "x"}) == {5, {NodeId.encode(42), :change, "x"}}
    assert Layers.route_event({:key, {:enter, 1, []}}) == nil
    # Ids of the frame itself (layer 0) belong to nobody.
    assert Layers.route_event({NodeId.encode(1), :press}) == nil
  end

  test "frame: lower layers go behind wrappers, the top one is the last wrapper's child" do
    {_bin, frame} = Layers.frame(3)
    assert [w1, w2] = frame.wrappers

    layer = %Emerge.Engine.Element{
      type: :el,
      id: 1 <<< 48 ||| 1,
      attrs: %{},
      children: [],
      nearby: []
    }

    assert [{:insert_nearby_subtree, ^w1, 0, :behind, _}] = Layers.mount(frame, 1, nil, layer)

    assert [{:remove, 99}, {:insert_nearby_subtree, ^w2, 0, :behind, _}] =
             Layers.mount(frame, 2, 99, layer)

    leaf = frame.leaf
    assert [{:remove, ^leaf}, {:insert_subtree, ^w2, 0, _}] = Layers.mount(frame, 3, nil, layer)
    assert [{:insert_subtree, ^w2, 0, _}] = Layers.mount(frame, 3, :removed, layer)
  end
end
