#!/usr/bin/env bash
# emerge's precompiled aarch64 NIF (the DRM variant) links libgbm.so.1, which the
# qemu_aarch64 system doesn't have (no Mesa), so the NIF fails to load there. This copies
# libgbm and what it needs (libdrm, libexpat) from the rpi4 system into a rootfs overlay
# that config/qemu_aarch64.exs adds when it exists. Same toolchain and glibc (2.43) as the
# qemu system. Headless rendering never opens a GBM device, so no Mesa drivers are needed.
#
#   scripts/qemu_gbm_overlay.sh      # writes _build/qemu_gbm_overlay/usr/lib
#
# Needs the rpi4 system artifact in ~/.nerves/artifacts (MIX_TARGET=rpi4 mix deps.get).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
version="${RPI4_SYSTEM_VERSION:-2.1.2}"
src="${NERVES_ARTIFACTS_DIR:-$HOME/.nerves/artifacts}/nerves_system_rpi4-portable-$version/staging/usr/lib"
dst="$here/_build/qemu_gbm_overlay/usr/lib"

[[ -d "$src" ]] || { echo "no rpi4 system at $src (MIX_TARGET=rpi4 mix deps.get)" >&2; exit 1; }

rm -rf "$dst"
mkdir -p "$dst"
for lib in libgbm.so.1 libdrm.so.2 libexpat.so.1; do
  cp -L "$src/$lib" "$dst/$lib"
done
echo "gbm overlay in $dst: $(ls "$dst" | tr '\n' ' ')"
