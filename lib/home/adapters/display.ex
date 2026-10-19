defmodule Home.Adapters.Display do
  @moduledoc """
  `:display` capability drawn with emerge. The lease endpoint is the
  `Home.Render.Compositor` pid that remote render sessions attach to.

      %{id: "disp0", kind: :display, meta: %{w: 1024, h: 600, touch: true},
        adapter: {Home.Adapters.Display, output: %Emerge.Config.DRM{}}}

  Options (merged into the capability meta):

    * `:output` - an `Emerge.Config` output: `%Emerge.Config.Window{}`,
      `%Emerge.Config.DRM{}` or `%Emerge.Config.Headless{}`. Defaults to headless at
      `{meta.w, meta.h}`; a headless output's frames go to the compositor.
    * `:renderer` - an `Emerge.Config.Renderer`. Defaults to `api: :raster`.
    * `:input` - the id of an `:input` capability on this node (`Home.Adapters.Input`)
      for the renderer's input devices. Input then goes only to that capability's
      lease holder. Without it, input goes to the session drawn on top.

  The renderer itself starts when a session is shown, not with the capability.
  """
  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, compositor: nil}}

  @impl true
  def start(%{compositor: nil, cap: cap} = state) do
    input = Map.get(cap.meta, :input)

    {:ok, pid} =
      Home.Render.Compositor.start_link(
        cap: {node(), cap.id},
        config: config(cap.meta),
        input: input && {node(), input}
      )

    if input, do: Home.Adapters.Input.register(input, pid)

    {:ok, %{state | compositor: pid}}
  end

  def start(state), do: {:ok, state}

  @impl true
  def stop(%{compositor: nil} = state), do: {:ok, state}

  def stop(state) do
    GenServer.stop(state.compositor)
    {:ok, %{state | compositor: nil}}
  end

  @impl true
  def endpoint(state), do: state.compositor

  defp config(meta) do
    size = {Map.get(meta, :w, 800), Map.get(meta, :h, 600)}

    %Emerge.Config{
      output: Map.get(meta, :output, %Emerge.Config.Headless{size: size}),
      renderer: Map.get(meta, :renderer, %Emerge.Config.Renderer{api: :raster})
    }
  end
end
