# home_node

Nerves firmware for a home cluster node: it runs `home_base` (path dep `../..`) and
vends the manifest from `config/`:

- `qemu_aarch64` (built, booted and tested here): synthetic hardware, so the guest can
  source and sink real media in the cluster. `pir0` and `temp0` (`Home.Adapters.Null`),
  a synthetic mic `mic0` (`:on_request`, clicks every 300 ms), a capture speaker `spk0`
  that detects the clicks it plays, a synthetic H.264 camera `cam0` (`:on_request`,
  320x240@30, frame number drawn in) and a headless emerge display `disp0` (160x120).
- `rpi4`, `rpi5` (built, not run on hardware yet): PortAudio mic and speaker, a V4L2
  camera and an emerge display on DRM. See "Raspberry Pi" below.
- `rpi0_2`, `rpi3` are in `mix.exs` but not built.

## Build

Toolchain comes from `mise.toml` (OTP 29.0.5, Elixir 1.20.3). `nerves_system_qemu_aarch64`
is pinned to `~> 0.4.2` because 0.4.x ships OTP 29.0.x; 0.5 moves to OTP 29.1.

```sh
cd nerves/home_node
MIX_TARGET=qemu_aarch64 mise exec -- mix deps.get
MIX_TARGET=qemu_aarch64 mise exec -- mix firmware
```

What the build needed beyond `mix firmware`:

- **Bigger rootfs.** With Membrane's precompiled ffmpeg (H.264) and emerge's NIF the
  squashfs is about 85 MB, and the qemu system's partitions are 50 MB.
  `config/qemu_aarch64/fwup.conf` includes the system's `fwup.conf` with
  `ROOTFS_A_PART_COUNT` raised to 192 MB. The rpi systems' partitions are big enough.
- **Pruned native files.** `rel/prune_native.exs` is a release step after `:assemble`. It
  drops bundlex's download cache (`bundlex/priv/shared`), every file in a plugin's
  precompiled-library directory that its NIFs don't reach through `NEEDED` (the
  portaudio tarball alone brings libpython, glib, systemd, ...), and `.so` files built for
  another machine. emerge is a path dep, so its `priv/native` also holds the host NIF,
  which would fail Nerves' executable-format scrub. The release goes from 1.5 GB to 250 MB.
- **libgbm on qemu.** emerge's precompiled aarch64 NIF is the DRM variant and links
  `libgbm.so.1`, which the qemu system doesn't have (no Mesa). `scripts/qemu_gbm_overlay.sh`
  copies libgbm, libdrm and libexpat from the rpi4 system artifact (same toolchain and
  glibc) into `_build/qemu_gbm_overlay`, which `config/qemu_aarch64.exs` adds as a rootfs
  overlay when it exists. Headless rendering never opens a GBM device, so no Mesa drivers
  are needed. `demo.sh --build` runs it; without it the guest boots but has no display.
- Systems ship OTP 29.0.6 (qemu_aarch64 0.4.2, rpi4/rpi5 2.1.2); mise pins 29.0.5 on the
  host. Patch releases of the same OTP interoperate, and beams compiled on 29.0.5 load.
- When building for the target, Mix compiles emerge on the host and tries to load its
  aarch64 NIF there, which logs `Failed to load NIF library ... aarch64 ... --drm.so`.
  That is harmless.

## Boot

```sh
scripts/qemu.sh start [--fresh]   # background qemu, console in _build/qemu/console.log
scripts/ssh.sh                    # IEx on the guest over nerves_ssh
scripts/qemu.sh stop              # kills the qemu pid from _build/qemu/qemu.pid
```

`start` writes `_build/qemu/virtual-disk.img` from the `.fw` when the image is missing or
older than the firmware. `--fresh` always rewrites it, which also wipes `/data`.

## Demo

```sh
nerves/home_node/scripts/demo.sh [--build] [--keep]
```

This boots the guest, starts host node `nv2` in the background, and runs
`scripts/demo.exs` as host node `nv1`. `nv1` has a capture speaker `spk-nv1`, a synthetic
mic `mic-nv1` and a headless display `disp-nv1`. The demo checks that:

1. the guest `home@10.0.3.15` and both host nodes mesh; the guest is checked from both
   sides;
2. `Home.Registry.list(node: guest)` on the host returns `cam0`, `disp0`, `mic0`, `pir0`,
   `spk0` and `temp0`;
3. `Home.Registry.list()` on the guest (via `:erpc`) returns the host nodes'
   capabilities;
4. a lease from the host on `{guest, "mic0"}` turns its hardware on, and releasing the
   lease turns it off again. When the holder process on the host is killed, the lease is
   released as well;
5. media across the NAT (`scripts/media_checks.exs`, skipped with `--no-media`), every
   session started on `nv1`:
   - guest `mic0` -> `nv1`'s capture speaker (Opus over RTP): at least 8 clicks in 4 s,
     p95 click-to-played latency <= 250 ms, and `mic0` is off again afterwards;
   - `nv1`'s mic -> guest `spk0`: the same;
   - guest `cam0` -> `nv1`'s headless display with `Home.Render.show_video/2` (H.264):
     at least 60 frames shown in 4 s, p95 capture-to-screen <= 250 ms, `cam0` off after;
   - an emerge app running on `nv1` shown on the guest's `disp0` with `Home.Render.show/2`
     (scene forwarding; the guest renders with emerge's NIF): the guest's frame shows the
     app, and pressing its button on the guest changes the colour the guest draws;
6. after `Nerves.Runtime.reboot/0` on the guest, it drops out and rejoins by itself (about
   11 s here), with working leases;
7. after a hard power cycle (qemu killed and started again), the guest rejoins by itself
   (about 8.5 s after qemu starts).

Latency numbers from two runs on this dev VM (qemu is TCG-emulated, no KVM):

| path | median | p95 |
|---|---|---|
| guest mic -> host speaker (click to played) | 90-118 ms | 90-119 ms |
| host mic -> guest speaker | 79-106 ms | 79-106 ms |
| guest camera -> host screen (capture to shown) | 16-85 ms | 27-88 ms |
| press on guest -> app on host -> new colour on guest | 211-213 ms | 215-217 ms |
| of which press on guest -> app on host | 1.7-2.2 ms | 2.5-3.4 ms |

Guest timestamps come from the synthetic adapters through `HomeNode.Probe` (a registered
relay; a manifest in config can't name a pid), which `nv1` subscribes to over
distribution. They are shifted by the guest-host clock offset, estimated from the fastest
of 20 `:erpc` round trips (about 0.5 ms, so +-0.25 ms). The audio numbers are almost
constant within a run: they are mostly the receiver's jitter buffer and playout queue,
which settle at session start. The scene-forwarding round trip is dominated by emerge's
CPU rasterizer under emulation on the guest.

Then it stops everything it started. `demo.exs` takes `--no-media`, `--no-reboot` and
`--no-power-cycle`; pass them after `--`. A long-running host member on its own:

```sh
cd <repo root>
mise exec -- mix run --no-start nerves/home_node/scripts/host_node.exs 2
```

Host nodes run `home_base` from the repo root (`mix run --no-start`). They use the same
epmd module as the guest, loaded from `lib/home_node/epmd.ex` by
`scripts/host_setup.exs`.

## Networking

This is how the setup works now. The Tailscale section below covers what changes.

**No epmd, one fixed port.** Every node listens on one distribution port, and peers
dial it at the host part of the node name. That is plan §2.2, and stock `erl_epmd` does
it with `-start_epmd false -erl_epmd_port 4370`. Here `rel/vm.args.eex` sets
`-start_epmd false -epmd_module Elixir.HomeNode.Epmd` instead, because of the NAT below.

**Naming at runtime.** The node can only be named once it has an address, so
`home_base` is in the release with `applications: [home_base: :load]`, which loads it
but does not start it. `HomeNode.Distribution` polls `eth0` until it has an IPv4
address, runs `Node.start(:"home@<ip>", :longnames)` (the cookie is already set by
`-setcookie` in vm.args), and then starts `:home_base`. home_base has to come after
distribution because it keys its `:pg` groups and node state on `node()`.

**The NAT problem.** On qemu user networking, the host can reach the guest only through
a `hostfwd` port on 127.0.0.1. The guest reaches the host at the slirp gateway address,
which slirp maps to the host's 127.0.0.1. Erlang refuses a connection when the name the
peer gives in the handshake differs from the name that was dialed. So each node needs one
name that both sides can use, even though the addresses differ.

**The trick.**

- qemu runs with `-netdev user,net=10.0.3.0/24,hostfwd=tcp:127.0.0.1:41470-:4370` (see
  `scripts/qemu.sh`). A non-default subnet avoids clashing with this dev VM's own
  `10.0.2.0/24`: here the host itself is 10.0.2.15 and its gateway is 10.0.2.2.
- The guest is **`home@10.0.3.15`**, its real address, listening on 4370.
- Host nodes are named after the address the guest uses to reach them:
  **`nvN@10.0.3.2`**. They all share that one address, so each listens on its own port
  (`127.0.0.1:4140N`).
- `HomeNode.Epmd` takes static routes `"name@host" => {ip, port}` (app env
  `:home_node, :epmd`). Routes only change where the TCP connection goes. Names never
  change.
  - On the guest (`config/qemu_aarch64.exs`): `nvN@10.0.3.2 => {10.0.3.2, 4140N}`.
  - On the host (`scripts/host_setup.exs`): `home@10.0.3.15 => {127.0.0.1, 41470}` and
    `nvN@10.0.3.2 => {127.0.0.1, 4140N}`. Host nodes also bind distribution to
    127.0.0.1 (`inet_dist_use_interface`).
  - Any node without a route is dialed at the host part of its name on the fixed port.
    That default is what Tailscale needs.
- Clustering uses `Home.Cluster.Static` on both sides. The guest lists `nv1` and `nv2`,
  and each host node lists the guest and the other host node. Either side can start the
  connection, and `:pg` plus the full mesh handle the rest.

Running two guests at once would need different `net=` subnets (or `dhcpstart=`) and
different hostfwd ports.

## Media across qemu NAT

Media is RTP over UDP straight between the source and sink nodes. A sink binds
`media: [ip:, ports:]` and advertises that `{ip, port}` to the source through the session.
Under qemu user networking no single address works from both sides, so sources rewrite
destinations with `media: [routes: %{...}]` (`Home.Media.route/2`): an exact
`{ip, port} => {ip, port}`, or `ip => ip` that keeps the port. Like `HomeNode.Epmd`
routes, they change where packets go, never what is advertised.

| node | binds and advertises | UDP ports | routes |
|---|---|---|---|
| guest `home@10.0.3.15` | `10.0.3.15` (eth0; `HomeNode.Distribution` sets `ip:`) | 41480-41489 | `127.0.0.1 => 10.0.3.2` |
| host `nvN@10.0.3.2` | `127.0.0.1` | `41420+10N .. +9` (nv1: 41430-41439, nv2: 41440-41449) | `10.0.3.15 => 127.0.0.1` |

- **Host -> guest.** `scripts/qemu.sh` adds `hostfwd=udp:127.0.0.1:P-:P` for P in
  41480-41489, the same port numbers inside and out, so routing the ip alone is enough. A
  host node sends to the advertised `10.0.3.15:P` and the route turns it into
  `127.0.0.1:P`.
- **Guest -> host.** Host nodes advertise `127.0.0.1`, the address every host node can
  use. The guest can't send there (that would be its own loopback), so it routes
  `127.0.0.1` to the slirp gateway `10.0.3.2`, which slirp delivers to the host's
  127.0.0.1 on the same port.
- Host to host needs no route.
- Several guests would each need their own forwarded range, and an exact
  `{ip, port}` route per port on the host, since they share 127.0.0.1.

With Tailscale there is no NAT: every node binds and advertises its tailnet address and
`routes:` goes away (allow the media UDP range in the ACLs).

## When Tailscale is in

- `config :home_node, :distribution, interface: "tailscale0"`, so the node is
  `home@<tailscale ip>`. Tailscale IPs are stable, so the name survives reboots and
  network changes. With `eth0`, the name follows whatever DHCP hands out at boot.
- The cluster backend becomes `{Home.Cluster.Tailscale, []}` instead of `Static`, which
  needs a `tailscale` CLI or local API on the device (plan §9, open).
- No NAT means no routes. Drop `config/qemu_aarch64.exs`'s routes, or drop
  `HomeNode.Epmd` entirely for stock `erl_epmd` with
  `-start_epmd false -erl_epmd_port 4370`.
- Bind distribution to the tailnet address only (`inet_dist_use_interface`), and allow
  tag:homecluster → tag:homecluster on 4370 in the ACLs.
- In qemu, the guest would run tailscaled itself, which needs userspace networking or a
  TUN device in the guest kernel. Then hostfwd is not needed for distribution.

## Raspberry Pi

`MIX_TARGET=rpi4` (or `rpi5`) `mise exec -- mix deps.get && mix firmware` builds
`_build/rpi4_dev/nerves/images/home_node.fw` (about 100 MB; rpi5 115 MB). The manifest is
`config/rpi.exs`:

| cap | adapter | meta |
|---|---|---|
| `mic0` (`:on_request`) | `Home.Adapters.Audio.PortAudioIn` | ALSA default device, mono 48 kHz |
| `spk0` | `Home.Adapters.Audio.PortAudioOut` | ALSA default device |
| `cam0` (`:on_request`) | `Home.Adapters.Video.Camera` | `/dev/video0`, 640x480 YUYV @ 30 |
| `disp0` | `Home.Adapters.Display` | `{:drm, card: ...}`, raster renderer, 1920x1080 |

Media binds the node's own address on 50000-50099, no routes.

Checked at build time: every `NEEDED` library of every NIF in the release resolves
against the system's rootfs or the plugin's bundled libraries (libasound, libgbm, libEGL
and libdrm are in both rpi systems; portaudio brings its own libjack), and the precompiled
ffmpeg's libavdevice has the V4L2 input device.

Needs checking on real hardware:

- **Audio.** Which ALSA device is `default`. The Pi 4's headphone jack is output only and
  the Pi 5 has no analog audio, so the mic needs a USB sound card or HAT; set
  `device_id:` from `Membrane.PortAudio.print_devices/0` if the default is wrong. That
  portaudio's ALSA backend finds the alsa config in the Nerves rootfs.
- **Display.** The DRM card path: `/dev/dri/by-path/platform-gpu-card` (Pi 4) and
  `platform-axi:gpu-card` (Pi 5) are meant to be the vc4 KMS device, not the v3d render
  node; check with `EmergeSkia.drm_outputs(drm_card: ...)`. Whether the precompiled
  DRM NIF presents with CPU raster; `renderer: [api: :opengl]` against Mesa's vc4/v3d is
  the next thing to try. Touch input if the panel has it (`touch: true`). The size in
  meta is only a hint; the mode decides.
- **Camera.** A USB UVC webcam on `/dev/video0` and its supported formats
  (`v4l2-ctl --list-formats-ext` is not on the rootfs; ffmpeg's error lists them). CSI
  camera modules need libcamera and are not covered. H.264 encoding is software (x264
  in the precompiled ffmpeg): 640x480@30 should fit a Pi 4, 1080p probably not. That
  ffmpeg also has `h264_v4l2m2m`, the Pi 4's hardware encoder, which the session doesn't
  use yet (the Pi 5 has no H.264 encoder).
- **Network.** `config/target.exs` names the node after `eth0`. On Wi-Fi set
  `interface: "wlan0"` (and Wi-Fi credentials), with Tailscale `"tailscale0"`. The
  cluster backend is `Static` with no nodes until Tailscale discovery is in.

## Gotchas

- **Never start vintage_net on a dev host.** `nerves_pack` (and with it vintage_net) is a
  target-only dep. `HomeNode.Application` only starts distribution when
  `:home_node, :distribution` is configured, which happens in `config/target.exs` only.
  `config/host.exs` also sets `nerves_uevent` to leave the host's udevd alone. `mix test`
  on the host is safe.
- **`home_base` is a target-only dep here.** Compiling it for the host inside this project
  made bundlex download the x86 libopus into `deps/bundlex/priv`. That directory is shared
  with target builds, so the next firmware build failed in `scrub-otp-release.sh`
  ("Unexpected executable format"). If that happens, delete
  `deps/bundlex/priv/shared/precompiled/*x86*`.
- `config :kernel, ...` in `config/*.exs` triggers Mix's "Cannot configure base
  applications" warning, so `-epmd_module` lives in `rel/vm.args.eex`.
- On a guest reboot, a host node may log `'global' ... requested disconnect ... to prevent
  overlapping partitions`. That is `global`'s partition protection reacting to the node
  going away, and it is harmless here.
- `rel/prune_native.exs` decides by `NEEDED` closure. A bundled library that is only
  `dlopen`ed (not linked) would be pruned; system libraries are never touched.
- The guest's `CaptureSpeaker`/`SynthMic`/`SynthCamera` notify `HomeNode.Probe` by name, so
  `HomeNode.Application` starts the probe before distribution (and home_base).
- Use `scripts/ssh.sh` for ssh: it skips the ssh-agent, which can hang on this host.
