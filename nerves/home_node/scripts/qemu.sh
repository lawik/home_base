#!/usr/bin/env bash
# Boot the qemu_aarch64 firmware in the background.
#
#   scripts/qemu.sh start [--fresh]   boot (--fresh: rewrite the disk from the .fw, wiping /data)
#   scripts/qemu.sh stop              kill the qemu process (by its pid file)
#   scripts/qemu.sh status
#
# Networking is qemu user-mode (slirp) on 10.0.3.0/24, so the guest is 10.0.3.15 and the
# host is 10.0.3.2 from inside. Host-side forwards (loopback only):
#   127.0.0.1:${HOME_NODE_DIST_PORT:-41470} -> guest 4370  (Erlang distribution)
#   127.0.0.1:${HOME_NODE_SSH_PORT:-41422}  -> guest 22    (nerves_ssh)
#   127.0.0.1:41480-41489/udp -> guest 41480-41489/udp     (media sinks on the guest; same
#                                                          port numbers, see qemu_aarch64.exs)
# Serial console output goes to _build/qemu/console.log.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/_build/qemu"
fw="$here/_build/qemu_aarch64_dev/nerves/images/home_node.fw"
disk="$dir/virtual-disk.img"
pidfile="$dir/qemu.pid"
log="$dir/console.log"
dist_port="${HOME_NODE_DIST_PORT:-41470}"
ssh_port="${HOME_NODE_SSH_PORT:-41422}"
media_ports=(41480 41481 41482 41483 41484 41485 41486 41487 41488 41489)

running() { [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

start() {
  if running; then
    echo "qemu already running, pid $(cat "$pidfile")"
    return 0
  fi

  [[ -f "$fw" ]] || { echo "no firmware at $fw; run: MIX_TARGET=qemu_aarch64 mix firmware" >&2; exit 1; }
  mkdir -p "$dir"

  if [[ "${1:-}" == "--fresh" || ! -f "$disk" || "$fw" -nt "$disk" ]]; then
    echo "writing $disk from $fw"
    rm -f "$disk"
    fwup -a -q -i "$fw" -d "$disk" -t complete
  fi

  version="$(cat "$here/deps/nerves_system_qemu_aarch64/VERSION")"
  loader="$HOME/.nerves/artifacts/nerves_system_qemu_aarch64-portable-$version/images/little_loader.elf"
  [[ -f "$loader" ]] || { echo "no bootloader at $loader" >&2; exit 1; }

  netdev="user,id=eth0,net=10.0.3.0/24,hostfwd=tcp:127.0.0.1:$dist_port-:4370,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
  for p in "${media_ports[@]}"; do netdev+=",hostfwd=udp:127.0.0.1:$p-:$p"; done

  : >"$log"
  qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 512M \
    -kernel "$loader" \
    -netdev "$netdev" \
    -device virtio-net-device,netdev=eth0,mac=fe:db:ed:de:d0:01 \
    -global virtio-mmio.force-legacy=false \
    -drive "if=none,file=$disk,format=raw,id=vdisk" \
    -device virtio-blk-device,drive=vdisk,bus=virtio-mmio-bus.0 \
    -display none -monitor none -serial "file:$log" \
    -daemonize -pidfile "$pidfile"

  echo "qemu started, pid $(cat "$pidfile"), console log $log"
}

stop() {
  if running; then
    pid="$(cat "$pidfile")"
    kill "$pid"
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    echo "qemu $pid stopped"
  else
    echo "qemu not running"
  fi
  rm -f "$pidfile"
}

case "${1:-}" in
  start) shift; start "$@" ;;
  stop) stop ;;
  status) if running; then echo "running, pid $(cat "$pidfile")"; else echo "not running"; exit 1; fi ;;
  *) echo "usage: $0 start [--fresh] | stop | status" >&2; exit 2 ;;
esac
