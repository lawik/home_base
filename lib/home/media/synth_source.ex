defmodule Home.Media.SynthSource do
  @moduledoc """
  A synthetic microphone: real-time paced mono s16le 48 kHz audio in 20 ms frames, silent
  except for a short tone burst (a "click") every `click_every` ms.

  Like a real capture device, a frame is delivered when its 20 ms have "been recorded": the
  frame emitted at wall time `t` covers `[t - 20 ms, t]`. Each click starts at the start of
  its frame; if `notify` is set it gets `{:synth_click, cap, wall_us}` with that start time
  (`:os.system_time(:microsecond)`), so a receiver on the same host can measure latency.
  """

  use Membrane.Source

  alias Membrane.{Buffer, RawAudio, Time}

  @rate 48_000
  @frame_ms 20
  @frame_samples div(@rate * @frame_ms, 1000)

  def_output_pad(:output,
    accepted_format: %RawAudio{sample_format: :s16le},
    flow_control: :push
  )

  def_options(
    click_every: [
      spec: pos_integer(),
      default: 500,
      description: "Milliseconds between clicks (rounded to whole frames)."
    ],
    click_ms: [spec: pos_integer(), default: 10, description: "Click length."],
    tone_hz: [spec: pos_integer(), default: 1_000, description: "Click tone."],
    amplitude: [spec: float(), default: 0.6, description: "Click peak, 0..1."],
    notify: [spec: Process.dest() | nil, default: nil, description: "Gets click times."],
    cap: [spec: term(), default: nil, description: "Capability ref for notify."]
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      opts: opts,
      n: 0,
      every: max(1, div(opts.click_every, @frame_ms)),
      click: click_frame(opts),
      silence: <<0::size(@frame_samples * 16)>>
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    format = %RawAudio{channels: 1, sample_rate: @rate, sample_format: :s16le}

    {[stream_format: {:output, format}, start_timer: {:tick, Time.milliseconds(@frame_ms)}],
     state}
  end

  @impl true
  def handle_tick(:tick, _ctx, %{n: n} = state) do
    click? = n > 0 and rem(n, state.every) == 0

    if click? and state.opts.notify do
      start_us = :os.system_time(:microsecond) - @frame_ms * 1_000
      send(state.opts.notify, {:synth_click, state.opts.cap, start_us})
    end

    payload = if click?, do: state.click, else: state.silence
    buffer = %Buffer{payload: payload, pts: Time.milliseconds(n * @frame_ms)}
    {[buffer: {:output, buffer}], %{state | n: n + 1}}
  end

  defp click_frame(opts) do
    click_samples = min(@frame_samples, div(@rate * opts.click_ms, 1000))
    peak = opts.amplitude * 32_767

    tone =
      for i <- 0..(click_samples - 1), into: <<>> do
        v = round(peak * :math.sin(2 * :math.pi() * opts.tone_hz * i / @rate))
        <<v::signed-little-16>>
      end

    tone <> <<0::size((@frame_samples - click_samples) * 16)>>
  end
end
