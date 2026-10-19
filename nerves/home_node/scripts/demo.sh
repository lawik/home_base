#!/usr/bin/env bash
# End-to-end: boot the qemu guest, start host node nv2, run the checks in demo.exs as nv1,
# then stop everything that was started.
#
#   nerves/home_node/scripts/demo.sh [--build] [--keep] [-- demo.exs args...]
#
#   --build   (re)build the firmware first (MIX_TARGET=qemu_aarch64 mix firmware)
#   --keep    leave qemu and nv2 running afterwards
#
# Needs mise (erlang/elixir pinned in mise.toml). Ports used on 127.0.0.1: 41401-41402
# (host nodes), 41470 (guest dist), 41422 (guest ssh).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/../.." && pwd)"
mise="${MISE:-$(command -v mise || echo "$HOME/.local/bin/mise")}"
log_dir="$here/_build/qemu"
build=0
keep=0
demo_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) build=1 ;;
    --keep) keep=1 ;;
    --) shift; demo_args=("$@"); break ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

route_check() {
  # Guard for dev hosts: nothing here may start vintage_net on the host. If it ever did,
  # the default route would be gone.
  ip route 2>/dev/null | grep -q '^default' || echo "WARNING: no default route on this host"
}

if [[ $build == 1 ]]; then
  (cd "$here" && MIX_TARGET=qemu_aarch64 "$mise" exec -- mix deps.get)
  (cd "$here" && MIX_TARGET=qemu_aarch64 "$mise" exec -- mix firmware)
fi

# Host side runs home_base from the repo root (MIX_TARGET=host, no Nerves deps).
(cd "$root" && "$mise" exec -- mix deps.get >/dev/null && "$mise" exec -- mix compile)

nv2_pid=""
cleanup() {
  if [[ $keep == 0 ]]; then
    [[ -n "$nv2_pid" ]] && kill "$nv2_pid" 2>/dev/null || true
    "$here/scripts/qemu.sh" stop || true
  fi
  route_check
}
trap cleanup EXIT

route_check
"$here/scripts/qemu.sh" start --fresh

mkdir -p "$log_dir"
(cd "$root" && exec "$mise" exec -- mix run --no-start nerves/home_node/scripts/host_node.exs 2) \
  >"$log_dir/nv2.log" 2>&1 &
nv2_pid=$!
echo "nv2 started, pid $nv2_pid, log $log_dir/nv2.log"

cd "$root"
"$mise" exec -- mix run --no-start nerves/home_node/scripts/demo.exs "${demo_args[@]}"
