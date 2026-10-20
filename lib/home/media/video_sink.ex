defmodule Home.Media.VideoSink do
  @moduledoc """
  Membrane sink that shows decoded video on an emerge video surface (§6.3): each frame
  goes to the display's `Home.Render.Compositor`, which submits it to its renderer's
  `target` video element (`EmergeSkia.submit_video_frame/3`) while `owner`'s tree is the
  one drawn. RGB or RGBA frames (the software decoder's) become binary
  `%VideoInterop.Frame{}`s; a decoder that puts out `%VideoInterop.Frame{}`s already (a
  hardware one, see `Home.Media.video_decoder/0`) has them passed on as they are, and
  whoever gets one owns it: it submits it or releases it.

  `Home.Media.start_sink/2` uses it when a video session's sink endpoint is a compositor.
  """

  use Membrane.Sink

  alias Membrane.RawVideo

  def_input_pad(:input,
    accepted_format:
      any_of(
        %RawVideo{pixel_format: format} when format in [:RGB, :RGBA],
        VideoInterop.Format
      )
  )

  def_options(
    compositor: [spec: pid(), description: "The display's `Home.Render.Compositor`."],
    owner: [spec: pid(), description: "Render session whose tree holds the video element."],
    target: [spec: atom(), default: :home_video, description: "The video element's target."]
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{opts: opts, format: nil}}

  @impl true
  def handle_stream_format(:input, %VideoInterop.Format{}, _ctx, state),
    do: {[], %{state | format: :frames}}

  def handle_stream_format(:input, %RawVideo{} = format, _ctx, state) do
    pixel_format = if format.pixel_format == :RGB, do: :rgb888, else: :rgba8888
    {[], %{state | format: {format.width, format.height, pixel_format}}}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: %VideoInterop.Frame{} = frame}, _ctx, state) do
    %{compositor: comp, owner: owner, target: target} = state.opts
    Home.Render.Compositor.video_frame(comp, owner, target, frame)
    {[], state}
  end

  def handle_buffer(:input, %Membrane.Buffer{payload: payload}, _ctx, state) do
    {width, height, pixel_format} = state.format

    frame =
      VideoInterop.Frame.binary(payload,
        width: width,
        height: height,
        pixel_format: pixel_format,
        alpha_mode: :opaque
      )

    %{compositor: comp, owner: owner, target: target} = state.opts
    Home.Render.Compositor.video_frame(comp, owner, target, frame)
    {[], state}
  end
end
