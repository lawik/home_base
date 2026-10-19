defmodule Home.Adapters.Audio.PortAudioOut do
  @moduledoc """
  `:audio_out` adapter for a real speaker via PortAudio. The endpoint is a
  `Membrane.PortAudio.Sink`, fed 48 kHz s16le by the session's decoder; the device is open
  while a session's pipeline runs.

  Capability meta: `:device_id` (default `:default`), `:latency` (`:low`).
  """

  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, on?: false}}

  @impl true
  def start(state), do: {:ok, %{state | on?: true}}

  @impl true
  def stop(state), do: {:ok, %{state | on?: false}}

  @impl true
  def endpoint(%{cap: %{meta: meta}}) do
    %Membrane.PortAudio.Sink{
      device_id: Map.get(meta, :device_id, :default),
      latency: Map.get(meta, :latency, :low)
    }
  end
end
