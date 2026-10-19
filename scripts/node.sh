#!/usr/bin/env bash
# Start a home_base node with a shell: scripts/node.sh NAME MANIFEST [mix home.node options]
#
#   scripts/node.sh home-kitchen examples/kitchen.exs
#   scripts/node.sh home-laptop  examples/laptop.exs
#   scripts/node.sh home-server  examples/server.exs
#
# Nodes named home-* on this machine find each other through epmd. Extra options go to
# `mix home.node` (see `mix help home.node`), e.g. --backend static --peers a@h,b@h.
# Uses mise if it is installed (see mise.toml), else whatever elixir is on PATH.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 NAME MANIFEST [options]" >&2
  exit 1
fi

name=$1
manifest=$2
shift 2

cd "$(dirname "$0")/.."

run=()
if command -v mise >/dev/null 2>&1; then
  run=(mise exec --)
elif [ -x "$HOME/.local/bin/mise" ]; then
  run=("$HOME/.local/bin/mise" exec --)
fi

exec "${run[@]}" iex -S mix home.node "$manifest" --name "$name" --require examples/demo.exs "$@"
