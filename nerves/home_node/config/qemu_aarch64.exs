import Config

# qemu user-mode networking (see README "Networking"). scripts/qemu.sh starts the guest with
# `-netdev user,net=10.0.3.0/24,hostfwd=tcp:127.0.0.1:41470-:4370,...`, so:
#
#   * the guest is 10.0.3.15 and its node is home@10.0.3.15, listening on 4370;
#   * 10.0.3.2 is the qemu gateway, which slirp maps to the host's 127.0.0.1. Host nodes
#     are therefore named nvN@10.0.3.2 (the address the guest dials), each on its own
#     port since they share one address.
#
# The routes give those host nodes' ports. They are dialed at 10.0.3.2 as named.
host_nodes = %{
  "nv1@10.0.3.2" => {{10, 0, 3, 2}, 41401},
  "nv2@10.0.3.2" => {{10, 0, 3, 2}, 41402}
}

config :home_node, :epmd, port: 4370, routes: host_nodes

# Bigger rootfs partitions than the system's 50 MB (Membrane's ffmpeg + emerge's NIF).
config :nerves, :firmware, fwup_conf: "config/qemu_aarch64/fwup.conf"

# libgbm for emerge's NIF, copied from the rpi4 system by scripts/qemu_gbm_overlay.sh.
# Without it the guest still boots and does audio and video, but has no display.
gbm_overlay = Path.expand("../_build/qemu_gbm_overlay", __DIR__)

if File.dir?(gbm_overlay) do
  config :nerves, :firmware, rootfs_overlay: ["rootfs_overlay", gbm_overlay]
end

# Synthetic hardware, so the guest can source and sink real media in the cluster. The
# adapters report timestamps to HomeNode.Probe (a manifest can't name a pid); the demo
# subscribes to it over distribution.
caps = [
  %{id: "pir0", kind: :presence, adapter: Home.Adapters.Null, meta: %{sensor: :pir}},
  %{
    id: "temp0",
    kind: :sensor,
    adapter: Home.Adapters.Null,
    meta: %{measures: [:temperature, :humidity]}
  },
  %{
    id: "mic0",
    kind: :audio_in,
    availability: :on_request,
    adapter: Home.Adapters.Audio.SynthMic,
    meta: %{channels: 1, rate: 48_000, click_every: 300, notify: HomeNode.Probe}
  },
  %{
    id: "spk0",
    kind: :audio_out,
    adapter: Home.Adapters.Audio.CaptureSpeaker,
    meta: %{channels: 2, rate: 48_000, notify: HomeNode.Probe}
  },
  %{
    id: "cam0",
    kind: :video_in,
    availability: :on_request,
    adapter: Home.Adapters.Video.SynthCamera,
    meta: %{w: 320, h: 240, fps: 30, notify: HomeNode.Probe}
  },
  %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 160, h: 120}}
]

# Media under NAT (README "Media across qemu NAT"):
#
#   * The guest's sinks bind and advertise its own address, 10.0.3.15 (HomeNode.Distribution
#     sets `ip:` from eth0), on 41480..41489. scripts/qemu.sh forwards those UDP ports
#     one to one from the host's 127.0.0.1, and host nodes route 10.0.3.15 there.
#   * Host nodes' sinks bind and advertise 127.0.0.1, the only address the host has for
#     them that other host nodes can use too. The guest can't send to 127.0.0.1, so it
#     routes it to the gateway 10.0.3.2, which slirp delivers to the host's 127.0.0.1.
config :home_base,
  device_id: "nerves-qemu",
  capabilities: caps,
  media: [ports: 41480..41489, routes: %{{127, 0, 0, 1} => {10, 0, 3, 2}}],
  cluster: [
    backend: {Home.Cluster.Static, nodes: Enum.map(Map.keys(host_nodes), &String.to_atom/1)},
    interval: 5_000
  ]
