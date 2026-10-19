defmodule Home.Media.Playout do
  @moduledoc """
  Keeps a speaker's playout queue short: a pass-through for decoded s16le audio, right
  before the speaker's endpoint, that drops audio when the queue has stayed above
  `target` for a while.

  It models the device the way a sound card's output queue behaves: a buffer starts
  playing when it arrives or when the previous one has finished, whichever is later,
  and audio is consumed in real time (this node's monotonic clock). So the queue ahead
  of each buffer is known on arrival. Anything that delivers a burst (the jitter
  buffer's start-up hold, a network stall that releases a backlog, a sender whose clock
  runs fast) shows up as a queue that stays long. When the shortest queue seen over the
  last `window` ms is still more than one buffer above `target`, buffers are dropped
  until it isn't: quiet ones (peak below `quiet`) first, any one once `patience` ms have
  passed without a quiet one. A momentary peak (jitter) is left alone; the window
  minimum only stays high when the excess is permanent.

  Output timestamps are made contiguous again, so a downstream mixer that places audio by
  `pts` sees the shortened timeline. A sender whose clock runs slow empties the queue
  instead; that ends in an underrun, after which the model restarts from the next buffer.

  The parent gets `{:playout, %{queue_ms, dropped_ms, underruns}}` once per `window`.
  """

  use Membrane.Filter

  alias Membrane.{Buffer, RawAudio}

  def_input_pad :input, accepted_format: %RawAudio{sample_format: :s16le}
  def_output_pad :output, accepted_format: %RawAudio{sample_format: :s16le}

  def_options target: [spec: non_neg_integer(), default: 20, description: "Queue to keep (ms)."],
              window: [spec: pos_integer(), default: 500, description: "ms the excess must last."],
              patience: [
                spec: pos_integer(),
                default: 1_000,
                description: "ms to wait for a quiet buffer before dropping a loud one."
              ],
              quiet: [spec: pos_integer(), default: 1_000, description: "Quiet peak (s16)."]

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       opts: opts,
       format: nil,
       cursor: nil,
       window_end: nil,
       window_min: nil,
       excess_min: nil,
       excess_since: nil,
       pts: nil,
       queue: 0,
       dropped: 0,
       underruns: 0
     }}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state),
    do: {[stream_format: {:output, format}], %{state | format: format}}

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload} = buffer, _ctx, state) do
    now = System.monotonic_time(:microsecond)
    duration = duration(payload, state.format)

    {cursor, state} =
      cond do
        state.cursor == nil -> {now, state}
        state.cursor >= now -> {state.cursor, state}
        true -> {now, %{state | underruns: state.underruns + 1, excess_min: nil}}
      end

    queue = cursor - now
    {notify, state} = window(state, queue, now)

    if drop?(state, duration, payload, now) do
      state = %{
        state
        | cursor: cursor,
          excess_min: state.excess_min - duration,
          dropped: state.dropped + duration
      }

      {notify, state}
    else
      pts = state.pts || buffer.pts || 0
      state = %{state | cursor: cursor + duration, pts: pts + duration * 1_000, queue: queue}
      {[buffer: {:output, %{buffer | pts: pts}}] ++ notify, state}
    end
  end

  # The shortest queue over each window; the previous window's decides drops.
  defp window(%{window_end: nil} = state, queue, now),
    do: {[], %{state | window_end: now + state.opts.window * 1_000, window_min: queue}}

  defp window(state, queue, now) when now >= state.window_end do
    excess_min = min(state.window_min, queue)

    stats = %{
      queue_ms: div(state.queue, 1_000),
      dropped_ms: div(state.dropped, 1_000),
      underruns: state.underruns
    }

    state = %{
      state
      | window_end: now + state.opts.window * 1_000,
        window_min: queue,
        excess_min: excess_min,
        excess_since:
          if(excess_min > state.opts.target * 1_000, do: state.excess_since || now, else: nil)
    }

    {[notify_parent: {:playout, stats}], state}
  end

  defp window(state, queue, _now), do: {[], %{state | window_min: min(state.window_min, queue)}}

  defp drop?(%{excess_min: nil}, _duration, _payload, _now), do: false

  defp drop?(state, duration, payload, now) do
    if state.excess_min - duration >= state.opts.target * 1_000 do
      quiet?(payload, state.opts.quiet) or
        (state.excess_since != nil and now - state.excess_since >= state.opts.patience * 1_000)
    else
      false
    end
  end

  # µs of audio in `payload`.
  defp duration(payload, %RawAudio{sample_rate: rate, channels: channels}),
    do: div(div(byte_size(payload), 2 * channels) * 1_000_000, rate)

  defp quiet?(payload, limit) do
    Enum.all?(for <<s::signed-little-16 <- payload>>, do: abs(s) < limit)
  end
end
