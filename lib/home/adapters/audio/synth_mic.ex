defmodule Home.Adapters.Audio.SynthMic do
  @moduledoc """
  `:audio_in` adapter for a synthetic microphone (`Home.Media.SynthSource`): real-time paced
  silence with a click every `click_every` ms. For tests and for checking a path end to end.

  Capability meta: `:click_every`, `:click_ms`, `:tone_hz`, `:amplitude`, and `:notify` (a
  pid that gets `{:synth_click, cap, wall_us}` per click and `{:home_hw, cap_id, :on | :off}`
  when the "hardware" turns on or off).
  """

  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, on?: false}}

  @impl true
  def start(state) do
    notify(state, :on)
    {:ok, %{state | on?: true}}
  end

  @impl true
  def stop(state) do
    notify(state, :off)
    {:ok, %{state | on?: false}}
  end

  @impl true
  def endpoint(%{cap: cap}) do
    opts = Map.take(cap.meta, [:click_every, :click_ms, :tone_hz, :amplitude, :notify])
    struct!(Home.Media.SynthSource, Map.put(opts, :cap, {node(), cap.id}))
  end

  defp notify(%{cap: %{id: id, meta: %{notify: pid}}}, what) when is_pid(pid),
    do: send(pid, {:home_hw, id, what})

  defp notify(_, _), do: :ok
end
