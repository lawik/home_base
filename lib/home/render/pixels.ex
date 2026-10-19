defmodule Home.Render.Pixels do
  @moduledoc """
  Emerge renderer adapter (`Emerge.Config.Runtime.adapter`) for pixel forwarding (§6.2):
  the app's tree is drawn here by a local emerge headless renderer, at the remote
  display's size, and every frame goes to a `Home.Media.FrameSource` that encodes it
  for the display.

  Selected by `Home.Render.show_pixels/2`, which starts the app with
  `runtime: [adapter: Home.Render.Pixels, adapter_opts: [session: pid, frames: pid,
  size: {w, h}, renderer: %Emerge.Config.Renderer{}]]`; the app puts `runtime:` in its
  config exactly as for scene forwarding. Everything else is the stock renderer.

  Input from the display is injected into this renderer (`EmergeSkia.inject_input/2`,
  see `Home.Render.Video`), so it hit-tests the app's own tree: element events
  (`Event.on_press/1`, focus, text input, scrolling) and the app's raw input
  subscriptions work as with a local window.
  """

  @behaviour Emerge.Runtime.Viewport.Renderer

  @impl true
  def start(config, opts) do
    with {:ok, renderer} <- EmergeSkia.start(headless(config, opts)) do
      send(Keyword.fetch!(opts, :session), {:home_pixels_renderer, renderer})
      {:ok, {renderer, opts}}
    end
  end

  @impl true
  def configure({renderer, opts}, previous, config) do
    case EmergeSkia.configure(renderer, headless(previous, opts), headless(config, opts)) do
      {:ok, token} -> {:pending, token}
      result -> result
    end
  end

  @impl true
  def stop({renderer, _opts}), do: EmergeSkia.stop(renderer)

  @impl true
  def running?({renderer, _opts}), do: EmergeSkia.running?(renderer)

  @impl true
  def set_input_target({renderer, _opts}, pid), do: EmergeSkia.set_input_target(renderer, pid)

  @impl true
  def set_log_target({renderer, _opts}, pid), do: EmergeSkia.set_log_target(renderer, pid)

  @impl true
  def set_input_mask({renderer, _opts}, mask),
    do: Emerge.Runtime.Viewport.Renderer.Skia.set_input_mask(renderer, mask)

  @impl true
  def upload_tree({renderer, _opts}, tree), do: EmergeSkia.upload_tree(renderer, tree)

  @impl true
  def patch_tree({renderer, _opts}, diff_state, tree),
    do: EmergeSkia.patch_tree(renderer, diff_state, tree)

  defp headless(%Emerge.Config{} = config, opts) do
    %Emerge.Config{
      config
      | output: %Emerge.Config.Headless{
          size: Keyword.fetch!(opts, :size),
          target: Keyword.fetch!(opts, :frames)
        },
        renderer: Keyword.get(opts, :renderer, config.renderer)
    }
  end
end
