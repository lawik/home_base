defmodule Home.Media.SynthVideo do
  @moduledoc """
  A synthetic camera: real-time paced I420 video with the frame number drawn into it, so a
  receiver can tell which frame it shows and measure latency on one host.

  Each frame is a grey picture with a bright bar moving across it and, near the top-left
  corner, a row of 32 black/white blocks: the 24-bit frame number (most significant bit
  first) and an 8-bit check (the XOR of its three bytes). Blocks are big enough
  (`block_size/1`, 8 px at 320 wide) to survive lossy coding and scaling. `decode/2`
  reads them back from an RGB(A) picture of the frame.

  Frame `n` is sent at its capture time; if `notify` is set it gets
  `{:synth_frame, cap, n, wall_us}` with that time (`:os.system_time(:microsecond)`).
  """

  use Membrane.Source

  import Bitwise

  alias Membrane.{Buffer, RawVideo, Time}

  @bg 80
  @bar 200
  @one 235
  @zero 16
  @bits 32

  def_output_pad(:output, accepted_format: %RawVideo{pixel_format: :I420}, flow_control: :push)

  def_options(
    width: [spec: pos_integer(), default: 320, description: "Even, at least 280."],
    height: [spec: pos_integer(), default: 240, description: "Even."],
    fps: [spec: pos_integer(), default: 30, description: "Frames per second."],
    notify: [spec: Process.dest() | nil, default: nil, description: "Gets frame times."],
    cap: [spec: term(), default: nil, description: "Capability ref for notify."]
  )

  @impl true
  def handle_init(_ctx, opts) do
    %{width: w, height: h} = opts
    chroma = :binary.copy(<<128>>, div(w, 2) * div(h, 2))
    {[], %{opts: opts, n: 0, chroma: chroma, block: block_size(w)}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    %{width: w, height: h, fps: fps} = state.opts

    format = %RawVideo{
      width: w,
      height: h,
      pixel_format: :I420,
      framerate: {fps, 1},
      aligned: true
    }

    {[stream_format: {:output, format}, start_timer: {:tick, div(Time.seconds(1), fps)}], state}
  end

  @impl true
  def handle_tick(:tick, _ctx, %{n: n} = state) do
    %{fps: fps, notify: notify, cap: cap} = state.opts
    if notify, do: send(notify, {:synth_frame, cap, n, :os.system_time(:microsecond)})

    payload = IO.iodata_to_binary([luma(state, n), state.chroma, state.chroma])
    buffer = %Buffer{payload: payload, pts: div(n * Time.seconds(1), fps)}
    {[buffer: {:output, buffer}], %{state | n: n + 1}}
  end

  @doc "Side of one code block for a frame `width` pixels wide."
  def block_size(width), do: width |> div(40) |> max(7) |> min(16)

  defp luma(state, n) do
    %{width: w, height: h} = state.opts
    b = state.block
    bg_row = :binary.copy(<<@bg>>, w)

    code_row = [
      :binary.copy(<<@bg>>, b),
      for(bit <- code(n), do: :binary.copy(<<if(bit == 1, do: @one, else: @zero)>>, b)),
      :binary.copy(<<@bg>>, w - b * (@bits + 1))
    ]

    x = rem(n * 4, w - 2 * b)

    bar_row = [
      :binary.copy(<<@bg>>, x),
      :binary.copy(<<@bar>>, 2 * b),
      :binary.copy(<<@bg>>, w - x - 2 * b)
    ]

    [
      List.duplicate(bg_row, b),
      List.duplicate(code_row, b),
      List.duplicate(bg_row, b),
      List.duplicate(bar_row, h - 3 * b)
    ]
  end

  defp code(n) do
    n = n &&& 0xFFFFFF
    check = bxor(bxor(n >>> 16, n >>> 8 &&& 0xFF), n &&& 0xFF) &&& 0xFF
    for <<(bit::1 <- <<n::24, check::8>>)>>, do: bit
  end

  @doc """
  Read the frame number from a picture of a synthetic frame.

  `picture` is `{data, stride, bytes_per_pixel, {width, height}}` of an RGB(A) image in
  which the `{w, h}` video frame is drawn scaled to fit and centred (emerge's `:contain`).
  Returns `{:ok, n}` or `:error` when the code doesn't check out.
  """
  def decode({data, stride, bpp, {pw, ph}}, {w, h}) do
    scale = min(pw / w, ph / h)
    ox = (pw - w * scale) / 2
    oy = (ph - h * scale) / 2
    b = block_size(w)

    bits =
      for i <- 1..@bits do
        x = trunc(ox + (i + 0.5) * b * scale)
        y = trunc(oy + 1.5 * b * scale)
        at = y * stride + x * bpp
        <<_::binary-size(^at), r, g, bl, _::binary>> = data
        if r + g + bl > 3 * 128, do: 1, else: 0
      end

    <<n::24, _check::8>> = for bit <- bits, into: <<>>, do: <<bit::1>>
    if code(n) == bits, do: {:ok, n}, else: :error
  end
end
