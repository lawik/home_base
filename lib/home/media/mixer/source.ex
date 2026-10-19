defmodule Home.Media.Mixer.Source do
  @moduledoc false
  # One mixer input: replays what an Input element forwards, `delay` later, converted to
  # the mix's `output_format` if it differs from the input's `format`. Timestamps start
  # from 0 at the first buffer: the mixer places the input from the moment it joins (an
  # input that joins a restarted mixer mid-session would otherwise start with silence).
  use Membrane.Source

  alias Home.Media.Mixer.Convert

  def_output_pad :output, accepted_format: Membrane.RawAudio, flow_control: :push

  def_options format: [spec: Membrane.RawAudio.t()],
              output_format: [spec: Membrane.RawAudio.t() | nil, default: nil],
              delay: [spec: Membrane.Time.t()]

  @impl true
  def handle_init(_ctx, opts) do
    out = opts.output_format || opts.format
    convert = if out != opts.format, do: Convert.new(opts.format, out)
    {[], %{format: out, delay: opts.delay, convert: convert, base: nil}}
  end

  @impl true
  def handle_playing(_ctx, state), do: {[stream_format: {:output, state.format}], state}

  @impl true
  def handle_parent_notification({:buffer, buffer}, _ctx, state) do
    pts = buffer.pts || 0
    state = %{state | base: state.base || pts}
    {payload, state} = convert(buffer.payload, state)
    buffer = %{buffer | payload: payload, pts: pts - state.base + state.delay}
    {[buffer: {:output, buffer}], state}
  end

  def handle_parent_notification(:end_of_stream, _ctx, state),
    do: {[end_of_stream: :output, notify_parent: :ended], state}

  defp convert(payload, %{convert: nil} = state), do: {payload, state}

  defp convert(payload, state) do
    {payload, convert} = Convert.run(state.convert, payload)
    {payload, %{state | convert: convert}}
  end
end
