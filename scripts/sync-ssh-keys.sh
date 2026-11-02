#!/usr/bin/env bash
# keys/ is bind-mounted from Windows, where every file shows up as 0777, and
# ssh refuses private keys that others can read. Copy the top-level keys into
# the container with 0600; the inventory points at these copies.
# Runs on container start. Run it again after adding a key to keys/:
#   docker exec ansible bash scripts/sync-ssh-keys.sh
set -euo pipefail
src=/workdir/keys
dst=/root/.ssh/ansible

install -d -m 700 "$dst"
for f in "$src"/*; do
  [ -f "$f" ] || continue
  case "$f" in *.pub|*.pem) continue ;; esac
  install -m 600 "$f" "$dst/$(basename "$f")"
done
