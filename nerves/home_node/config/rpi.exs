import Config

# A Raspberry Pi with real hardware (imported by rpi4.exs and rpi5.exs). Built, not yet
# run on a device: README "Raspberry Pi" lists what needs checking there.
#
#   * mic0 / spk0: PortAudio on ALSA's default device. A USB sound card or a HAT; the Pi 4's
#     headphone jack is output only and the Pi 5 has no analog audio at all.
#   * cam0: a V4L2 capture device through FFmpeg (Membrane.CameraCapture), i.e. a USB
#     (UVC) webcam. A CSI camera module needs libcamera, which plain V4L2 capture doesn't
#     drive on these boards. 640x480 YUYV at 30 fps is what nearly every UVC camera offers
#     uncompressed.
#   * disp0: emerge straight on DRM/KMS, CPU raster rendering. The card is the KMS (vc4)
#     device, not the v3d render node; check with EmergeSkia.drm_outputs/1.
#
# Media: sinks bind and advertise the node's own address (HomeNode.Distribution sets
# `ip:` from its interface) on the default ports. No NAT, so no routes.
drm_card =
  case Mix.target() do
    :rpi4 -> "/dev/dri/by-path/platform-gpu-card"
    :rpi5 -> "/dev/dri/by-path/platform-axi:gpu-card"
  end

config :home_base,
  capabilities: [
    %{
      id: "mic0",
      kind: :audio_in,
      availability: :on_request,
      adapter: Home.Adapters.Audio.PortAudioIn,
      meta: %{device_id: :default, channels: 1, rate: 48_000}
    },
    %{
      id: "spk0",
      kind: :audio_out,
      adapter: Home.Adapters.Audio.PortAudioOut,
      meta: %{device_id: :default}
    },
    %{
      id: "cam0",
      kind: :video_in,
      availability: :on_request,
      adapter: Home.Adapters.Video.Camera,
      meta: %{device: "/dev/video0", w: 640, h: 480, fps: 30, pixel_format: "yuyv422"}
    },
    %{
      id: "disp0",
      kind: :display,
      adapter:
        {Home.Adapters.Display,
         output: {:drm, card: drm_card, hotplug_interval_ms: 750}, renderer: [api: :raster]},
      meta: %{w: 1920, h: 1080, touch: false}
    }
  ],
  media: [ports: 50_000..50_099]
