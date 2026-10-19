defmodule Home.Adapters.Audio.Mixer do
  @moduledoc """
  `:audio_out` adapter that mixes every session playing on the speaker (§5.3): wraps another
  `:audio_out` adapter and, while the hardware is on, runs a `Home.Media.Mixer` pipeline into
  that adapter's endpoint. Each shared lease's session gets its own mixer input.

      %{id: "spk0", kind: :audio_out,
        adapter: {Home.Adapters.Audio.Mixer, output: Home.Adapters.Audio.PortAudioOut}}

  Meta: `:output` (the wrapped adapter, which sees the same capability), `:slack` (extra ms
  of headroom per input, default 0).

  The mixer pipeline is monitored, not linked: if it dies it is started again and the
  sessions' `Home.Media.Mixer.Input`s find the new one (they ask the capability server),
  so the leases and sessions carry on after a short gap. Only if it dies more than
  five times in 10 s does the capability server exit too.
  """

  @behaviour Home.Adapter

  require Logger

  @max_restarts 5
  @restart_window 10_000

  @impl true
  def init(cap) do
    output = Map.fetch!(cap.meta, :output)

    with {:ok, out} <- output.init(cap) do
      {:ok, %{cap: cap, output: output, out: out, mixer: nil, mref: nil, restarts: []}}
    end
  end

  @impl true
  def start(state) do
    {:ok, out} = state.output.start(state.out)
    {:ok, start_mixer(%{state | out: out})}
  end

  @impl true
  def stop(state) do
    if state.mref, do: Process.demonitor(state.mref, [:flush])
    if state.mixer, do: Membrane.Pipeline.terminate(state.mixer, force?: true)
    {:ok, out} = state.output.stop(state.out)
    {:ok, %{state | out: out, mixer: nil, mref: nil}}
  end

  @impl true
  def endpoint(%{mixer: mixer}), do: %Home.Media.Mixer.Input{mixer: mixer, server: self()}

  @doc false
  # Called by `Home.Capability.Server` with messages it doesn't handle itself.
  def handle_info({:DOWN, mref, :process, _pid, reason}, %{mref: mref} = state) do
    now = System.monotonic_time(:millisecond)
    restarts = [now | Enum.filter(state.restarts, &(now - &1 < @restart_window))]

    if length(restarts) > @max_restarts,
      do: exit({:shutdown, {:mixer_failed, reason}})

    Logger.warning("mixer for #{state.cap.id} died (#{inspect(reason)}), restarting")
    {:ok, start_mixer(%{state | restarts: restarts})}
  end

  # A session's input lost its mixer and wants the current one.
  def handle_info({:mixer_wanted, input}, state) do
    if state.mixer, do: send(input, {:mixer, state.mixer})
    {:ok, state}
  end

  def handle_info(msg, state) do
    if function_exported?(state.output, :handle_info, 2) do
      {:ok, out} = state.output.handle_info(msg, state.out)
      {:ok, %{state | out: out}}
    else
      {:ok, state}
    end
  end

  defp start_mixer(state) do
    {:ok, _supervisor, mixer} =
      Home.Media.Mixer.start(
        output: state.output.endpoint(state.out),
        slack: Map.get(state.cap.meta, :slack, 0)
      )

    %{state | mixer: mixer, mref: Process.monitor(mixer)}
  end
end
