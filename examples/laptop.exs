# A laptop: its mic and camera are off until something leases them, and off again when
# the lease ends (release, holder gone, safety timeout or revoke_all). Its screen is a
# display too.
#
# The mic and camera are synthetic (clicks; a test pattern with a frame counter). For
# the real ones use Home.Adapters.Audio.PortAudioIn and Home.Adapters.Video.Camera
# (meta: %{device: "/dev/video0", w: 1280, h: 720, fps: 30}).
#
# The display is headless unless HOME_DISPLAY=window (needs a Wayland session).

output =
  case System.get_env("HOME_DISPLAY") do
    "window" -> %Emerge.Config.Window{title: "laptop", size: {480, 270}}
    _ -> %Emerge.Config.Headless{size: {480, 270}}
  end

[
  device_id: "laptop",
  capabilities: [
    %{
      id: "mic0",
      kind: :audio_in,
      availability: :on_request,
      adapter: Home.Adapters.Audio.SynthMic,
      meta: %{channels: 1, rate: 48_000}
    },
    %{
      id: "cam0",
      kind: :video_in,
      availability: :on_request,
      adapter: Home.Adapters.Video.SynthCamera,
      meta: %{w: 320, h: 240, fps: 15}
    },
    %{
      id: "disp0",
      kind: :display,
      adapter: {Home.Adapters.Display, output: output},
      meta: %{w: 480, h: 270}
    }
  ]
]
