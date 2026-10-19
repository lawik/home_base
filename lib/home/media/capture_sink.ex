defmodule Home.Media.CaptureSink do
  @moduledoc """
  A capture speaker: "plays" s16le audio against a model of a sound card's output queue and
  reports what it heard, so a test on one host (one wall clock) can measure latency.

  A buffer starts playing when it arrives, or when the previous one finishes, whichever is
  later (an arrival after the queue ran dry counts as an underrun). A click onset is a
  sample above `threshold` after at least `quiet_ms` of quiet; its play time is the buffer's
  start plus the sample's offset.

  If `notify` is set it gets:

    * `{:capture_started, cap}` on the first buffer
    * `{:capture_onset, cap, wall_us, queued_us}` per onset: its play time
      (`:os.system_time(:microsecond)`) and how much audio was queued ahead of its buffer
    * `{:capture_stats, cap, %{samples: n, underruns: n}}` every second of audio

  If `record` is a path, the received PCM is appended to that file.
  """

  use Membrane.Sink

  alias Membrane.RawAudio

  def_input_pad(:input, accepted_format: %RawAudio{sample_format: :s16le})

  def_options(
    notify: [
      spec: Process.dest() | nil,
      default: nil,
      description: "Gets onsets and stats (a pid or registered name)."
    ],
    cap: [spec: term(), default: nil, description: "Capability ref for notify."],
    threshold: [spec: pos_integer(), default: 8_000, description: "Onset level."],
    quiet_ms: [spec: pos_integer(), default: 200, description: "Gap between onsets."],
    record: [spec: Path.t() | nil, default: nil, description: "Append PCM here."]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       opts: opts,
       rate: nil,
       channels: nil,
       cursor: nil,
       last_loud: nil,
       samples: 0,
       underruns: 0,
       next_stats: 0,
       file: nil
     }}
  end

  @impl true
  def handle_setup(ctx, %{opts: %{record: path}} = state) when is_binary(path) do
    file = File.open!(path, [:append, :binary, :raw])
    Membrane.ResourceGuard.register(ctx.resource_guard, fn -> File.close(file) end)
    {[], %{state | file: file}}
  end

  def handle_setup(_ctx, state), do: {[], state}

  @impl true
  def handle_stream_format(:input, %RawAudio{} = format, _ctx, state) do
    {[], %{state | rate: format.sample_rate, channels: format.channels}}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: payload}, _ctx, state) do
    now = :os.system_time(:microsecond)
    if state.file, do: IO.binwrite(state.file, payload)
    if state.cursor == nil, do: notify(state, {:capture_started, state.opts.cap})

    {start, underruns} =
      cond do
        state.cursor == nil -> {now, state.underruns}
        state.cursor >= now -> {state.cursor, state.underruns}
        true -> {now, state.underruns + 1}
      end

    frames = div(byte_size(payload), 2 * state.channels)
    last_loud = scan(payload, state, start, start - now, 0, state.last_loud)
    samples = state.samples + frames

    state = %{
      state
      | cursor: start + div(frames * 1_000_000, state.rate),
        last_loud: last_loud,
        samples: samples,
        underruns: underruns
    }

    {[], stats(state)}
  end

  defp scan(payload, state, start, queued, i, last_loud) do
    skip = 16 * (state.channels - 1)

    case payload do
      <<s::signed-little-16, _::size(^skip), rest::binary>> ->
        last_loud =
          if abs(s) >= state.opts.threshold do
            t = start + div(i * 1_000_000, state.rate)

            if last_loud == nil or t - last_loud > state.opts.quiet_ms * 1_000,
              do: notify(state, {:capture_onset, state.opts.cap, t, queued})

            t
          else
            last_loud
          end

        scan(rest, state, start, queued, i + 1, last_loud)

      _ ->
        last_loud
    end
  end

  defp stats(%{samples: s, next_stats: next} = state) when s >= next do
    notify(state, {:capture_stats, state.opts.cap, %{samples: s, underruns: state.underruns}})
    %{state | next_stats: next + state.rate}
  end

  defp stats(state), do: state

  defp notify(%{opts: %{notify: dest}}, msg) when dest != nil, do: send(dest, msg)
  defp notify(_, _), do: :ok
end
