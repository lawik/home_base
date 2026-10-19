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
  """

  @behaviour Emerge.Runtime.Viewport.Renderer

  @impl true
  def start(config, opts) do
    send(Keyword.fetch!(opts, :session), {:home_pixels_input, config.input})

    with {:ok, renderer} <- EmergeSkia.start(headless(config, opts)) do
      {:ok, {renderer, opts}}
    end
  end

  @impl true
  def configure({renderer, opts}, previous, config) do
    if config.input != previous.input,
      do: send(Keyword.fetch!(opts, :session), {:home_pixels_input, config.input})

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

  # A headless renderer has no input of its own; input comes from the display.
  @impl true
  def set_input_mask(_renderer, _mask), do: :ok

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
