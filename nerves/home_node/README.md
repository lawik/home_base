# home_node

Nerves firmware for a home cluster node: it runs `home_base` (path dep `../..`) and
vends a display-less manifest: a presence sensor `pir0`, a temperature/humidity sensor
`temp0`, and a mic `mic0` that stays off until leased (`:on_request`). All three use
`Home.Adapters.Null` until real adapters exist.

Targets: `qemu_aarch64` (built and tested), plus `rpi0_2`, `rpi3`, `rpi4`, `rpi5` in
`mix.exs` (not built yet).

## Build

Toolchain comes from `mise.toml` (OTP 29.0.5, Elixir 1.20.3). `nerves_system_qemu_aarch64`
is pinned to `~> 0.4.2` because 0.4.x ships OTP 29.0.x; 0.5 moves to OTP 29.1.

```sh
cd nerves/home_node
MIX_TARGET=qemu_aarch64 mise exec -- mix deps.get
MIX_TARGET=qemu_aarch64 mise exec -- mix firmware
```

Membrane cross-compiles without changes: bundlex downloads a precompiled aarch64 libopus
(`opus_linux_arm.tar.gz`) and the release ships it next to the NIFs. The Opus encoder
loads and encodes on the guest.

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
`scripts/demo.exs` as host node `nv1`. The demo checks that:

1. the guest `home@10.0.3.15` and both host nodes mesh; the guest is checked from both
   sides;
2. `Home.Registry.list(node: guest)` on the host returns `mic0`, `pir0` and `temp0`;
3. `Home.Registry.list()` on the guest (via `:erpc`) returns `spk-nv1` and `spk-nv2`
   from the host nodes;
4. a lease from the host on `{guest, "mic0"}` turns its hardware on, and releasing the
   lease turns it off again. When the holder process on the host is killed, the lease is
   released as well;
5. after `Nerves.Runtime.reboot/0` on the guest, it drops out and rejoins by itself (about
   11 s here), with working leases;
6. after a hard power cycle (qemu killed and started again), the guest rejoins by itself
   (about 8 s after qemu starts).

Then it stops everything it started. `demo.exs` takes `--no-reboot` and
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
- Use `scripts/ssh.sh` for ssh: it skips the ssh-agent, which can hang on this host.
