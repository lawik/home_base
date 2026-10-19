defmodule HomeBase.MixProject do
  use Mix.Project

  def project do
    [
      app: :home_base,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Home.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:mint_web_socket, "~> 1.0"},
      {:membrane_core, "~> 1.2"},
      {:membrane_rtp_plugin, "~> 0.31"},
      {:membrane_rtp_opus_plugin, "~> 0.10"},
      {:membrane_opus_plugin, "~> 0.20"},
      {:membrane_udp_plugin, "~> 0.14"},
      {:membrane_raw_audio_format, "~> 0.12"},
      {:membrane_raw_video_format, "~> 0.4"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32"},
      {:membrane_h26x_plugin, "~> 0.10"},
      {:membrane_rtp_h264_plugin, "~> 0.20"},
      {:membrane_ffmpeg_swscale_plugin, "~> 0.16"},
      {:membrane_camera_capture_plugin, "~> 0.7"},
      # emerge 0.5.0 plus the scene-forwarding hooks in docs/EMERGE-FORWARDING.md.
      {:emerge, path: System.get_env("EMERGE_PATH", "/root/workspace/emerge-home")},
      {:solve, "~> 0.3.1"},
      {:membrane_portaudio_plugin, "~> 0.19"},
      {:membrane_audio_mix_plugin, "~> 0.16"},
      # ONVIF cameras (Home.Onvif): SOAP device/media services, RTSP client.
      {:ex_onvif, "~> 0.9"},
      {:rtsp, "~> 0.8"},
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end
end
