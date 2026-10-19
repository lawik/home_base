defmodule Home.Adapters.Video.Camera do
  @moduledoc """
  `:video_in` adapter for a real camera through FFmpeg's capture devices (V4L2 on Linux,
  AVFoundation on macOS) via `Membrane.CameraCapture`. The device is opened when a
  session's source pipeline starts and closed when it stops, so an `:on_request` camera
  is only open while a session holds it.

      %{id: "cam0", kind: :video_in, availability: :on_request,
        adapter: Home.Adapters.Video.Camera,
        meta: %{device: "/dev/video0", w: 1280, h: 720, fps: 30}}

  Capability meta: `:device` (default `"/dev/video0"`), `:w` and `:h` (requested size;
  both or neither, default the device's), `:fps` (30), `:pixel_format` (FFmpeg name,
  default `"yuv420p"`; the session converts anything else to I420 for the encoder).
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
    size =
      case meta do
        %{w: w, h: h} -> {w, h}
        _ -> nil
      end

    %Membrane.CameraCapture{
      device: Map.get(meta, :device, "/dev/video0"),
      framerate: Map.get(meta, :fps, 30),
      pixel_format: Map.get(meta, :pixel_format, "yuv420p"),
      video_size: size
    }
  end
end
