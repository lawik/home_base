defmodule Home.Adapters.Audio.PortAudioIn do
  @moduledoc """
  `:audio_in` adapter for a real microphone via PortAudio (laptops, desktops, a Pi with a
  sound card). The endpoint is a `Membrane.PortAudio.Source`; the device is opened when a
  session's pipeline starts and closed when it stops, so an `:on_request` mic is only open
  while a session holds it.

  Capability meta: `:device_id` (default `:default`, see `Membrane.PortAudio.print_devices/0`),
  `:channels` (1), `:rate` (48 000), `:latency` (`:low`).
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
    %Membrane.PortAudio.Source{
      device_id: Map.get(meta, :device_id, :default),
      channels: Map.get(meta, :channels, 1),
      sample_rate: Map.get(meta, :rate, 48_000),
      sample_format: :s16le,
      latency: Map.get(meta, :latency, :low)
    }
  end
end
