defmodule Home.Media.Mixer.Input do
  @moduledoc "Sink at the end of a session's pipeline that feeds a `Home.Media.Mixer`."
  use Membrane.Sink

  def_input_pad :input, accepted_format: Membrane.RawAudio
  def_options mixer: [spec: pid(), description: "The mixer pipeline."]

  @impl true
  def handle_init(_ctx, opts), do: {[], %{mixer: opts.mixer}}

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    send(state.mixer, {:mixer_input, self(), {:format, format}})
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    send(state.mixer, {:mixer_input, self(), {:buffer, buffer}})
    {[], state}
  end
end
