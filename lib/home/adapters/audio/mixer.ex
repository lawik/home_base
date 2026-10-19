defmodule Home.Adapters.Audio.Mixer do
  @moduledoc """
  `:audio_out` adapter that mixes every session playing on the speaker (§5.3): wraps another
  `:audio_out` adapter and, while the hardware is on, runs a `Home.Media.Mixer` pipeline into
  that adapter's endpoint. Each shared lease's session gets its own mixer input.

      %{id: "spk0", kind: :audio_out,
        adapter: {Home.Adapters.Audio.Mixer, output: Home.Adapters.Audio.PortAudioOut}}

  Meta: `:output` (the wrapped adapter, which sees the same capability), `:slack` (extra ms
  of headroom per input, default 0).

  The mixer pipeline is linked to the capability server: if it dies, so does the server
  (and with it the leases and the sessions using them).
  """

  @behaviour Home.Adapter

  @impl true
  def init(cap) do
    output = Map.fetch!(cap.meta, :output)

    with {:ok, out} <- output.init(cap) do
      {:ok, %{cap: cap, output: output, out: out, mixer: nil}}
    end
  end

  @impl true
  def start(state) do
    {:ok, out} = state.output.start(state.out)

    {:ok, _supervisor, mixer} =
      Home.Media.Mixer.start_link(
        output: state.output.endpoint(out),
        slack: Map.get(state.cap.meta, :slack, 0)
      )

    {:ok, %{state | out: out, mixer: mixer}}
  end

  @impl true
  def stop(state) do
    Membrane.Pipeline.terminate(state.mixer, force?: true)
    {:ok, out} = state.output.stop(state.out)
    {:ok, %{state | out: out, mixer: nil}}
  end

  @impl true
  def endpoint(%{mixer: mixer}), do: %Home.Media.Mixer.Input{mixer: mixer}
end
