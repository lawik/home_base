# The kitchen: a wall display, a speaker and an always-on microphone.
#
# The mic is synthetic (a click a second) and the speaker records what it plays to a
# file instead of playing it, so the demo runs on any machine. On real hardware use
# Home.Adapters.Audio.PortAudioIn / PortAudioOut instead.
#
# The display is headless unless HOME_DISPLAY=window (needs a Wayland session).

output =
  case System.get_env("HOME_DISPLAY") do
    "window" -> %Emerge.Config.Window{title: "kitchen", size: {480, 270}}
    _ -> %Emerge.Config.Headless{size: {480, 270}}
  end

[
  device_id: "kitchen",
  capabilities: [
    %{
      id: "mic0",
      kind: :audio_in,
      availability: :always,
      adapter: Home.Adapters.Audio.SynthMic,
      meta: %{channels: 1, rate: 48_000}
    },
    %{
      id: "spk0",
      kind: :audio_out,
      adapter: Home.Adapters.Audio.CaptureSpeaker,
      meta: %{record: Path.join(System.tmp_dir!(), "home-kitchen-spk0.pcm")}
    },
    %{
      id: "disp0",
      kind: :display,
      adapter: {Home.Adapters.Display, output: output},
      meta: %{w: 480, h: 270, touch: true}
    }
  ]
]
