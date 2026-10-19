defmodule Home.Media.Mixer.Input do
  @moduledoc """
  Sink at the end of a session's pipeline that feeds a `Home.Media.Mixer`.

  If the mixer goes away while the session plays, the input asks the capability
  `server` for its replacement (`Home.Adapters.Audio.Mixer` starts one) and carries on
  there; audio in between is dropped.
  """
  use Membrane.Sink

  def_input_pad :input, accepted_format: Membrane.RawAudio

  def_options mixer: [spec: pid(), description: "The mixer pipeline."],
              server: [
                spec: pid() | nil,
                default: nil,
                description: "Capability server that knows the current mixer."
              ]

  @retry_ms 100

  @impl true
  def handle_init(_ctx, opts) do
    Process.monitor(opts.mixer)
    {[], %{mixer: opts.mixer, server: opts.server, format: nil}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    send(state.mixer, {:mixer_input, self(), {:format, format}})
    {[], %{state | format: format}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    send(state.mixer, {:mixer_input, self(), {:buffer, buffer}})
    {[], state}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, _ctx, %{mixer: pid, server: nil} = state),
    do: {[], state}

  def handle_info({:DOWN, _, :process, pid, _}, _ctx, %{mixer: pid} = state) do
    send(self(), :find_mixer)
    {[], state}
  end

  def handle_info(:find_mixer, _ctx, state) do
    if Process.alive?(state.mixer) do
      {[], state}
    else
      send(state.server, {:mixer_wanted, self()})
      Process.send_after(self(), :find_mixer, @retry_ms)
      {[], state}
    end
  end

  def handle_info({:mixer, pid}, _ctx, %{mixer: old} = state) when pid != old do
    Process.monitor(pid)
    if state.format, do: send(pid, {:mixer_input, self(), {:format, state.format}})
    {[], %{state | mixer: pid}}
  end

  def handle_info(_msg, _ctx, state), do: {[], state}
end
