defmodule Home.Media.FrameSource do
  @moduledoc """
  Membrane source fed with rendered frames, for pixel forwarding (§6.2).

  On setup it sends `{:home_frame_source, self()}` to `notify`. From then on any process
  on this node can send it `{:emerge_skia_frame, %VideoInterop.Frame{}}` (binary
  `:rgba8888` or `:rgb888` storage), which is what an emerge headless renderer sends its
  `target`. Like a screen capture, it outputs the latest frame at a constant `fps`,
  repeating it while nothing changes, so the encoder gets a steady stream and a receiver
  that lost a packet recovers at the next keyframe. Output is `RawVideo` `:RGBA` or
  `:RGB`; a frame of another size starts a new stream format.
  """

  use Membrane.Source

  alias Membrane.{Buffer, RawVideo, Time}

  def_output_pad(:output,
    accepted_format: %RawVideo{pixel_format: format} when format in [:RGB, :RGBA],
    flow_control: :push
  )

  def_options(
    notify: [spec: pid(), description: "Gets `{:home_frame_source, pid}` on setup."],
    fps: [spec: pos_integer(), default: 30, description: "Output frame rate."]
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{opts: opts, latest: nil, format: nil, n: 0}}

  @impl true
  def handle_setup(_ctx, state) do
    send(state.opts.notify, {:home_frame_source, self()})
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[start_timer: {:tick, Time.seconds(1) |> div(state.opts.fps)}], state}
  end

  @impl true
  def handle_info({:emerge_skia_frame, %VideoInterop.Frame{} = frame}, _ctx, state) do
    case pack(frame, state.opts.fps) do
      {:ok, latest} -> {[], %{state | latest: latest}}
      :error -> {[], state}
    end
  end

  def handle_info(_msg, _ctx, state), do: {[], state}

  @impl true
  def handle_tick(:tick, _ctx, %{latest: nil} = state), do: {[], state}

  def handle_tick(:tick, _ctx, state) do
    {format, payload} = state.latest
    pts = div(state.n * Time.seconds(1), state.opts.fps)
    buffer = {:buffer, {:output, %Buffer{payload: payload, pts: pts}}}

    actions =
      if format == state.format,
        do: [buffer],
        else: [{:stream_format, {:output, format}}, buffer]

    {actions, %{state | format: format, n: state.n + 1}}
  end

  # Tightly packed pixels of the visible rectangle.
  defp pack(
         %VideoInterop.Frame{
           visible_rect: rect,
           storage: %VideoInterop.Binary{data: data, planes: [plane]},
           format: %{storage: %{pixel_format: pixel_format}}
         },
         fps
       )
       when pixel_format in [:rgba8888, :rgb888] do
    {bpp, raw} = if pixel_format == :rgb888, do: {3, :RGB}, else: {4, :RGBA}
    row = rect.width * bpp

    payload =
      if plane.stride == row and rect.x == 0 and rect.y == 0 and plane.offset == 0 and
           byte_size(data) == row * rect.height do
        data
      else
        for y <- rect.y..(rect.y + rect.height - 1), into: <<>> do
          binary_part(data, plane.offset + y * plane.stride + rect.x * bpp, row)
        end
      end

    format = %RawVideo{
      width: rect.width,
      height: rect.height,
      pixel_format: raw,
      framerate: {fps, 1},
      aligned: true
    }

    {:ok, {format, payload}}
  end

  defp pack(_frame, _fps), do: :error
end
