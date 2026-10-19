defmodule Home.Adapters.Audio.CaptureSpeaker do
  @moduledoc """
  `:audio_out` adapter that records instead of playing (`Home.Media.CaptureSink`): it models a
  sound card's output queue, detects click onsets and reports them with wall-clock times, so
  latency can be measured on one host.

  Capability meta: `:notify` (pid or registered name for `{:capture_onset, cap, wall_us}` and friends, see
  `Home.Media.CaptureSink`), `:threshold`, `:quiet_ms`, `:record` (path to append PCM to).
  """

  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, on?: false}}

  @impl true
  def start(state), do: {:ok, %{state | on?: true}}

  @impl true
  def stop(state), do: {:ok, %{state | on?: false}}

  @impl true
  def endpoint(%{cap: cap}) do
    opts = Map.take(cap.meta, [:notify, :threshold, :quiet_ms, :record])
    struct!(Home.Media.CaptureSink, Map.put(opts, :cap, {node(), cap.id}))
  end
end
