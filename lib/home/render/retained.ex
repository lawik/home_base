defmodule Home.Render.Retained do
  @moduledoc """
  Scroll positions and focus of a forwarded app, kept across `Home.Render.move/2` and
  across its session being hidden and shown again.

  Emerge keeps these natively in the display's renderer, which is replaced in both
  cases. It reports them only for elements that ask: `Event.on_scroll/1` (fractions
  `%{x: f, y: f}`) and `Event.on_focus/1` / `Event.on_blur/1`. So `instrument/2` gives
  every scroll container and text input that lacks those handlers one that points at
  the session (which ignores the message; it reads the events as they pass through it,
  see `record/2`), and `restore/2` puts the last known state into the full tree a new
  renderer gets, as `Scroll.scroll_x/1`, `Scroll.scroll_y/1` and `focus_on_mount/0`.
  Emerge treats those as one-shot: later user scrolling wins, and the app's next patch
  of that element's attributes releases them without moving.

  Not kept: the caret and selection inside a text input (emerge does not report them;
  a restored focus puts the caret at the start).
  """

  alias Emerge.Engine.{Element, NodeId}

  defstruct scroll: %{}, focus: nil

  @type t :: %__MODULE__{scroll: %{binary() => %{x: float(), y: float()}}, focus: binary() | nil}

  @focusable [:text_input, :multiline]

  @doc "Add scroll and focus handlers (to `sink`) where the app has none."
  def instrument(nil, _sink), do: nil

  def instrument(%Element{} = el, sink) do
    attrs = el.attrs

    attrs =
      if scrolls?(attrs), do: Map.put_new(attrs, :on_scroll, {sink, :home_retained}), else: attrs

    attrs =
      if el.type in @focusable do
        attrs
        |> Map.put_new(:on_focus, {sink, :home_retained})
        |> Map.put_new(:on_blur, {sink, :home_retained})
      else
        attrs
      end

    %{
      el
      | attrs: attrs,
        children: Enum.map(el.children, &instrument(&1, sink)),
        nearby: Enum.map(el.nearby, fn {slot, child} -> {slot, instrument(child, sink)} end)
    }
  end

  def instrument(other, _sink), do: other

  @doc "Update `retained` from an event the display's renderer reported."
  def record(%__MODULE__{} = retained, {id, :scroll, %{x: x, y: y}}) when is_binary(id),
    do: %{retained | scroll: Map.put(retained.scroll, id, %{x: x, y: y})}

  def record(%__MODULE__{} = retained, {id, :focus}) when is_binary(id),
    do: %{retained | focus: id}

  def record(%__MODULE__{focus: id} = retained, {id, :blur}), do: %{retained | focus: nil}
  def record(%__MODULE__{} = retained, _event), do: retained

  @doc "`tree` (an assigned tree, with ids) with the recorded state as one-shot attributes."
  def restore(tree, %__MODULE__{scroll: scroll, focus: nil}) when map_size(scroll) == 0,
    do: tree

  def restore(%Element{} = el, retained) do
    id = el.id && NodeId.encode(el.id)
    attrs = el.attrs

    attrs =
      case retained.scroll do
        %{^id => %{x: x, y: y}} ->
          attrs
          |> put_if(Map.get(attrs, :scrollbar_x), :scroll_position_x, fraction(x))
          |> put_if(Map.get(attrs, :scrollbar_y), :scroll_position_y, fraction(y))

        _ ->
          attrs
      end

    attrs =
      if id != nil and id == retained.focus,
        do: Map.put(attrs, :focus_on_mount, true),
        else: attrs

    %{
      el
      | attrs: attrs,
        children: Enum.map(el.children, &restore(&1, retained)),
        nearby: Enum.map(el.nearby, fn {slot, child} -> {slot, restore(child, retained)} end)
    }
  end

  def restore(other, _retained), do: other

  defp scrolls?(attrs),
    do: Map.get(attrs, :scrollbar_x) == true or Map.get(attrs, :scrollbar_y) == true

  # Positions the app controls itself are left alone.
  defp put_if(attrs, true, key, value), do: Map.put_new(attrs, key, value)
  defp put_if(attrs, _, _key, _value), do: attrs

  defp fraction(v) when is_number(v), do: v |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
end
