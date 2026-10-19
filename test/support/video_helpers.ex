defmodule Home.Test.PixelApp do
  @moduledoc false
  # An emerge app for pixel forwarding: red, blue after an odd number of pointer presses.
  # Raw input is reported to `test`.
  use Emerge

  @impl Viewport
  def mount(opts) do
    config = %Emerge.Config{
      runtime: Keyword.get(opts, :runtime, []),
      input: [events: [:pointer_button, :key]],
      assets: [otp_app: :home_base]
    }

    {:ok, %{test: opts[:test], presses: 0}, config}
  end

  @impl Viewport
  def render(%{presses: presses}) do
    bg = if rem(presses, 2) == 0, do: color_rgb(255, 0, 0), else: color_rgb(0, 0, 255)
    el([width(fill()), height(fill()), Background.color(bg)], none())
  end

  @impl Viewport
  def handle_input(event, state) do
    if state.test,
      do: send(state.test, {:app_input, node(), event, :os.system_time(:microsecond)})

    case event do
      {:pointer_button, {_button, :press, _mods, _pos}} ->
        {:noreply, Viewport.rerender(%{state | presses: state.presses + 1})}

      _ ->
        {:noreply, state}
    end
  end
end

defmodule Home.Test.VideoHelpers do
  @moduledoc false
  # Runs on peers.

  alias Home.Render.Compositor

  @doc """
  For `ms`, watch the display's headless frames for the synthetic camera's frame numbers
  (`Home.Media.SynthVideo`, a `video_size` frame drawn to fit) and send
  `{:shown, cap, n, wall_us}` to `test` the first time each number is on screen. Then
  `{:watch_done, cap, polls}`.
  """
  def watch(test, cap_id, video_size, ms) do
    comp = Home.Test.Render.compositor(cap_id)
    deadline = System.monotonic_time(:millisecond) + ms
    watch(test, {node(), cap_id}, comp, video_size, deadline, nil, 0)
  end

  defp watch(test, cap, comp, size, deadline, last, polls) do
    if System.monotonic_time(:millisecond) > deadline do
      send(test, {:watch_done, cap, polls})
    else
      last =
        with %VideoInterop.Frame{} = frame <- Compositor.frame(comp),
             {:ok, n} when n != last <- Home.Media.SynthVideo.decode(picture(frame), size) do
          send(test, {:shown, cap, n, :os.system_time(:microsecond)})
          n
        else
          _ -> last
        end

      Process.sleep(2)
      watch(test, cap, comp, size, deadline, last, polls + 1)
    end
  end

  defp picture(%VideoInterop.Frame{storage: %{data: data, planes: [plane]}} = frame) do
    offset = plane.offset
    <<_::binary-size(^offset), data::binary>> = data
    {data, plane.stride, 4, {frame.coded_width, frame.coded_height}}
  end

  @doc """
  Wait until the display's pixel at `point` matches `fun` (an RGBA predicate); returns
  the wall time it was first seen, or nil after `ms`.
  """
  def await_pixel(cap_id, point, fun, ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + ms
    await_pixel(cap_id, point, fun, deadline, :loop)
  end

  defp await_pixel(cap_id, point, fun, deadline, :loop) do
    rgba = Home.Test.Render.pixel(cap_id, point)

    cond do
      rgba != nil and fun.(rgba) ->
        :os.system_time(:microsecond)

      System.monotonic_time(:millisecond) > deadline ->
        nil

      true ->
        Process.sleep(2)
        await_pixel(cap_id, point, fun, deadline, :loop)
    end
  end

  def red?({r, g, b, _}), do: r > 200 and g < 60 and b < 60
  def blue?({r, g, b, _}), do: b > 200 and r < 60 and g < 60
  def green?({r, g, b, _}), do: g > 200 and r < 60 and b < 60

  @doc "Inject a pointer press and release at `{x, y}` into the display, as its renderer would."
  def click(cap_id, {x, y}) do
    comp = Home.Test.Render.compositor(cap_id)
    pos = {x * 1.0, y * 1.0}
    :ok = Compositor.input(comp, {:cursor_button, {:left, 1, [], pos}})
    :ok = Compositor.input(comp, {:cursor_button, {:left, 0, [], pos}})
    :os.system_time(:microsecond)
  end
end

defmodule Home.Test.PlainPixelApp do
  @moduledoc false
  # A non-emerge app for pixel forwarding: draws solid green frames itself and reports
  # the input it gets.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    adapter_opts = opts[:runtime][:adapter_opts]
    {w, h} = adapter_opts[:size]
    pixels = :binary.copy(<<0, 255, 0, 255>>, w * h)
    frame = VideoInterop.Frame.binary(pixels, width: w, height: h, pixel_format: :rgba8888)
    send(self(), :draw)
    {:ok, %{frames: adapter_opts[:frames], frame: frame, test: opts[:test]}}
  end

  @impl true
  def handle_info(:draw, state) do
    send(state.frames, {:emerge_skia_frame, state.frame})
    Process.send_after(self(), :draw, 100)
    {:noreply, state}
  end

  def handle_info({:emerge_skia_event, event}, state) do
    send(state.test, {:plain_input, node(), event})
    {:noreply, state}
  end
end
