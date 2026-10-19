defmodule HomeNode.MixProject do
  use Mix.Project

  @app :home_node
  @version "0.1.0"
  @all_targets [:qemu_aarch64, :rpi0_2, :rpi3, :rpi4, :rpi5]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.17"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {HomeNode.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # The home cluster library. `runtime: false` keeps it out of this app's
      # `applications`, so the boot script does not start it: home_base must start after
      # distribution is up (it keys :pg groups on node()), and distribution needs an IP
      # address. The release still includes it (see `applications:` in release/0) and
      # HomeNode.Distribution starts it.
      # Target-only: compiling it for the host would make bundlex download the x86
      # libopus into deps/bundlex/priv, which is shared with target builds and then fails
      # the firmware's executable-format scrub. Host nodes run home_base from the repo root.
      {:home_base, path: "../..", runtime: false, targets: @all_targets},

      # Dependencies for all targets except :host. Never start vintage_net on a dev host.
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets.
      # qemu_aarch64 0.4.x ships OTP 29.0.x, which matches the erlang pinned in mise.toml.
      {:nerves_system_qemu_aarch64, "~> 0.4.2", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi0_2, "~> 2.0", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5}
    ]
  end

  def release do
    [
      overwrite: true,
      # The shared home cluster cookie (plan §2.2). Distribution itself is started by
      # HomeNode.Distribution once the network interface has an address.
      cookie: "home_cluster_cookie",
      # Loaded, not started, at boot: HomeNode.Distribution starts it after Node.start/2.
      applications: [home_base: :load],
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp listeners(_, _), do: []
end
