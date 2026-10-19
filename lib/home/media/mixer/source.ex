defmodule Home.Media.Mixer.Source do
  @moduledoc false
  # One mixer input: replays what an Input element forwards, `delay` later.
  use Membrane.Source

  def_output_pad :output, accepted_format: Membrane.RawAudio, flow_control: :push
  def_options format: [spec: Membrane.RawAudio.t()], delay: [spec: Membrane.Time.t()]

  @impl true
  def handle_init(_ctx, opts), do: {[], Map.from_struct(opts)}

  @impl true
  def handle_playing(_ctx, state), do: {[stream_format: {:output, state.format}], state}

  @impl true
  def handle_parent_notification({:buffer, buffer}, _ctx, state) do
    {[buffer: {:output, %{buffer | pts: (buffer.pts || 0) + state.delay}}], state}
  end

  def handle_parent_notification(:end_of_stream, _ctx, state),
    do: {[end_of_stream: :output, notify_parent: :ended], state}
end
