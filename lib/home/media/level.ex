defmodule Home.Media.Level do
  @moduledoc """
  Pass-through filter that emits `:level` activity events (`%{session: pid, level_db: float}`)
  for a capability, at most once a second. Only s16le audio is measured.
  """

  use Membrane.Filter

  alias Membrane.RawAudio

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  def_options(
    cap: [spec: Home.Capability.ref(), description: "Capability the audio belongs to."],
    kind: [spec: atom(), description: "Activity kind, `:audio_in` or `:audio_out`."],
    session: [spec: pid() | nil, default: nil, description: "Session, for event data."],
    interval: [spec: pos_integer(), default: 1_000, description: "ms between levels."]
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{opts: opts, s16?: false, next: 0}}

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    s16? = match?(%RawAudio{sample_format: :s16le}, format)
    {[stream_format: {:output, format}], %{state | s16?: s16?}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    now = System.monotonic_time(:millisecond)

    state =
      if state.s16? and now >= state.next do
        %{cap: cap, kind: kind, session: session} = state.opts
        Home.Activity.emit(cap, kind, :level, %{session: session, level_db: db(buffer.payload)})
        %{state | next: now + state.opts.interval}
      else
        state
      end

    {[buffer: {:output, buffer}], state}
  end

  @doc "RMS level of s16le PCM in dBFS (-inf is reported as -120.0)."
  def db(payload) do
    {sum, n} =
      for <<s::signed-little-16 <- payload>>, reduce: {0, 0} do
        {sum, n} -> {sum + s * s, n + 1}
      end

    rms = if n == 0, do: 0.0, else: :math.sqrt(sum / n) / 32_768

    if rms <= 1.0e-6, do: -120.0, else: Float.round(20 * :math.log10(rms), 1)
  end
end
