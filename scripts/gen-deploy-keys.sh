#!/usr/bin/env bash
# Run inside the ansible control container (run_gen_deploy_keys.bat):
#   - one ed25519 keypair per repo listed in deploy-targets.yml, under keys/deploy/
#     (existing keys are kept; delete a pair to rotate it)
#   - keys/deploy_known_hosts with the SSH host keys of every deploy host
# Then run the forgejo-secret tag to push the private keys as DEPLOY_SSH_KEY
# and the deploy-target tag to install the public keys behind deploy.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p keys/deploy
chmod 700 keys/deploy

repos=$(python3 - <<'EOF'
import yaml
targets = yaml.safe_load(open("inventory/host_vars/deploy-targets.yml"))["deploy_targets"]
print("\n".join(sorted({k["repo"] for t in targets.values() for k in t["repo_keys"]})))
EOF
)

for repo in $repos; do
  if [ -f "keys/deploy/$repo" ]; then
    echo "keep     $repo"
  else
    ssh-keygen -q -t ed25519 -N "" -C "forgejo-ci/$repo" -f "keys/deploy/$repo"
    echo "created  $repo"
  fi
done

: >keys/deploy_known_hosts
for var in DEPLOY_HOST_DOCKER_APPS DEPLOY_HOST_GALAXION DEPLOY_HOST_SYAHDAN DEPLOY_HOST_WEB_LINUX; do
  host=${!var:-}
  if [ -z "$host" ]; then
    echo "skip     $var is not set" >&2
    continue
  fi
  ssh-keyscan -t ed25519 "$host" 2>/dev/null >>keys/deploy_known_hosts
  echo "scanned  $host"
done
echo "Check keys/deploy_known_hosts against each host (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) before pushing it."
