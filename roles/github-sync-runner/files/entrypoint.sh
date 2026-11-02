#!/usr/bin/env bash
# config.sh writes the runner's identity into its install dir, which the image
# resets on every recreate. Keep those three files in /state and put them back
# on start, so registering (with a one-hour token) only happens once.
set -euo pipefail
cd /home/runner
files=(.runner .credentials .credentials_rsaparams)

if [ "${1:-}" = register ]; then
  ./config.sh --unattended --replace --no-default-labels \
    --url "$RUNNER_URL" --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" --labels "$RUNNER_LABELS"
  cp "${files[@]}" /state/
  exit 0
fi

for f in "${files[@]}"; do
  [ -f "/state/$f" ] || { echo "runner is not registered, run the register step first" >&2; exit 1; }
  cp "/state/$f" .
done
exec ./run.sh
