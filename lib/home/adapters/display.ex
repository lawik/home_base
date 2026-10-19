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

  The renderer itself starts when a session is shown, not with the capability.
  """
  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, compositor: nil}}

  @impl true
  def start(%{compositor: nil, cap: cap} = state) do
    {:ok, pid} =
      Home.Render.Compositor.start_link(cap: {node(), cap.id}, config: config(cap.meta))

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
