#!/bin/sh
# ssh to the qemu guest's IEx (nerves_ssh) through the hostfwd. Skips the ssh-agent, which
# can hang on this kind of host. Pass an Elixir expression to evaluate it and exit, or
# nothing for an interactive IEx.
exec ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -p "${HOME_NODE_SSH_PORT:-41422}" 127.0.0.1 "$@"
