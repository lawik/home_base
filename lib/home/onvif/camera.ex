defmodule Home.Onvif.Camera do
  @moduledoc """
  `:video_in` adapter for an ONVIF camera configured with `Home.Onvif.add_camera/2`.

  The capability is `:on_request` and `shared: true`. Turning the hardware on (the first
  lease) starts a `Home.Onvif.Relay`, the one RTSP connection to the camera; turning it
  off (the last release, the holder dying, expiry, revoke, `Home.Onvif.remove_camera/1`)
  stops it. The endpoint is a `%Home.Media.H264Relay{}` on that relay, so each media
  session's source pipeline subscribes to the same stream and only re-packetizes it.

  The stream URI and credentials are read from `Home.Onvif` on this node when the
  stream starts; they are not in the capability (which every node can read).

  The relay is linked to the capability server: if it crashes, the capability server
  restarts and every session on the camera ends (holders see the capability go down).
  Camera disconnects don't crash it; it reconnects (see `Home.Onvif.Relay`).
  """

  @behaviour Home.Adapter

  alias Home.Onvif.Relay

  @impl true
  def init(cap), do: {:ok, %{cap: cap, relay: nil}}

  @impl true
  def start(%{cap: cap} = state) do
    {:ok, stream} = Home.Onvif.stream(cap.id)
    {:ok, relay} = Relay.start_link(id: cap.id, uri: stream.uri, transport: stream.transport)
    {:ok, %{state | relay: relay}}
  end

  @impl true
  def stop(%{relay: nil} = state), do: {:ok, state}

  def stop(%{relay: relay} = state) do
    GenServer.stop(relay, :normal, 5_000)
    {:ok, %{state | relay: nil}}
  catch
    :exit, _ -> {:ok, %{state | relay: nil}}
  end

  @impl true
  def endpoint(%{relay: nil}), do: nil
  def endpoint(%{relay: relay}), do: %Home.Media.H264Relay{feed: relay}
end
