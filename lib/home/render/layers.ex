defmodule Home.Render.Layers do
  @moduledoc """
  Composes several sessions' emerge trees into the one tree a renderer draws, for
  overlays (`Home.Render.show(app, on: display, layer: :overlay)`).

  Emerge has one tree per renderer. Each session's tree arrives as emerge's own bytes
  (full tree, then patches) with ids from that session's diff state, so trees of two
  sessions have colliding ids. Here every id of layer `n` becomes `n <<< 48 ||| id`,
  and patches are translated op by op: no diffing, no retained copy of the trees.
  Element events coming back carry composed ids, which `owner/1` maps to the layer and
  the session's own id.

  The layers hang in a chain of empty full-size wrappers (`frame/1`): wrapper `i`
  has layer `i` as its `behind` nearby and wrapper `i + 1` (for the last one, the top
  layer) as its child. Emerge paints `behind` under the host's children, so the order
  is bottom to top; and unlike `in_front` nearby roots, which block pointer input to
  everything under their box (emerge's modal semantics), this lets presses through
  the transparent parts of an overlay to the layers below.

  Image and font paths of layer `n` are prefixed with `"<n>/"`, so each session's asset
  directory can be mounted under one source directory without name clashes.
  """

  import Bitwise

  alias Emerge.Engine.{Element, NodeId, Patch, Serialization}

  @shift 48
  @mask (1 <<< @shift) - 1

  @doc """
  The wrapper chain for `count` layers: `{binary, frame}`, where `frame` holds the
  wrapper ids (bottom first) and the placeholder in the last one.
  """
  def frame(count) when count >= 2 do
    import Emerge.UI.Size

    tree =
      Enum.reduce(1..(count - 1), Emerge.UI.none(), fn _, inner ->
        Emerge.UI.el([width(fill()), height(fill())], inner)
      end)

    {bin, _diff_state, assigned} =
      Emerge.Engine.encode_full(Emerge.Engine.diff_state_new(), tree)

    {wrappers, leaf} = chain(assigned, [])
    {bin, %{wrappers: wrappers, top: List.last(wrappers), leaf: leaf, count: count}}
  end

  defp chain(%Element{type: :none, id: id}, acc), do: {Enum.reverse(acc), id}
  defp chain(%Element{id: id, children: [child]}, acc), do: chain(child, [id | acc])

  @doc """
  Ops mounting `subtree` (a layer root) at `position` (1 = bottom) of `frame`,
  replacing `old` (that position's previous root, nil for none yet, or `:removed`).
  """
  def mount(frame, position, old, %Element{} = subtree) do
    if position == frame.count do
      removes(old, frame.leaf) ++ [{:insert_subtree, frame.top, 0, subtree}]
    else
      host = Enum.at(frame.wrappers, position - 1)
      removes(old, nil) ++ [{:insert_nearby_subtree, host, 0, :behind, subtree}]
    end
  end

  # `:removed`: the session's own patch removed its old root already.
  defp removes(:removed, _placeholder), do: []
  defp removes(nil, nil), do: []
  defp removes(nil, placeholder), do: [{:remove, placeholder}]
  defp removes(old, _placeholder), do: [{:remove, old}]

  @doc "A session's full tree (bytes) as a layer: `{layer_root_id, subtree}`."
  def full(bin, layer) do
    tree = bin |> Serialization.decode() |> remap_tree(layer)
    {tree.id, tree}
  end

  @doc """
  Translate a session's patch bytes to layer `n`. Returns `{ops, root}`, where a new
  session root (`insert_subtree` with no parent) comes back as `root`
  (`{:new_root, subtree}`, for the caller to mount) and `nil` otherwise.
  """
  def patch(bin, layer) do
    bin
    |> Patch.decode()
    |> Enum.reduce({[], nil}, fn
      {:insert_subtree, nil, _index, subtree}, {ops, _root} ->
        {ops, {:new_root, remap_tree(subtree, layer)}}

      op, {ops, root} ->
        {[remap_op(op, layer) | ops], root}
    end)
    |> then(fn {ops, root} -> {Enum.reverse(ops), root} end)
  end

  def encode(ops), do: Patch.encode(ops)

  @doc "The layer and the session's own id (binary) of a composed element id (binary)."
  def owner(<<id::unsigned-big-64>>) when id > @mask,
    do: {id >>> @shift, NodeId.encode(id &&& @mask)}

  def owner(_), do: nil

  @doc "Element events: the event with the session's own id, and the layer; raw input: nil."
  def route_event({id, event}) when is_binary(id), do: with_owner(id, &{&1, event})

  def route_event({id, event, payload}) when is_binary(id),
    do: with_owner(id, &{&1, event, payload})

  def route_event(_raw), do: nil

  defp with_owner(id, fun) do
    case owner(id) do
      {layer, own} -> {layer, fun.(own)}
      nil -> nil
    end
  end

  @doc "A logical asset path of layer `n`."
  def prefix(path, layer) when is_binary(path), do: "#{layer}/" <> String.trim_leading(path, "/")

  ## Internals

  defp id(nil, _layer), do: nil
  defp id(id, layer), do: layer <<< @shift ||| id

  defp remap_op({:set_attrs, id, attrs}, n), do: {:set_attrs, id(id, n), attrs(attrs, n)}

  defp remap_op({:set_children, id, ids}, n),
    do: {:set_children, id(id, n), Enum.map(ids, &id(&1, n))}

  defp remap_op({:set_nearby_mounts, id, mounts}, n),
    do: {:set_nearby_mounts, id(id, n), Enum.map(mounts, fn {slot, m} -> {slot, id(m, n)} end)}

  defp remap_op({:insert_subtree, parent, index, tree}, n),
    do: {:insert_subtree, id(parent, n), index, remap_tree(tree, n)}

  defp remap_op({:insert_nearby_subtree, host, index, slot, tree}, n),
    do: {:insert_nearby_subtree, id(host, n), index, slot, remap_tree(tree, n)}

  defp remap_op({:remove, id}, n), do: {:remove, id(id, n)}

  defp remap_tree(%Element{} = el, n) do
    %{
      el
      | id: id(el.id, n),
        attrs: attrs(el.attrs, n),
        children: Enum.map(el.children, &remap_tree(&1, n)),
        nearby: Enum.map(el.nearby, fn {slot, child} -> {slot, remap_tree(child, n)} end)
    }
  end

  defp attrs(attrs, n) do
    Home.Render.Assets.map_attr_sources(attrs, fn
      path when is_binary(path) -> prefix(path, n)
      other -> other
    end)
  end
end
