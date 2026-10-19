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
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end
end
