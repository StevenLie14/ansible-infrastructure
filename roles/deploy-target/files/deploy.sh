#!/usr/bin/env bash
# Forced command for CI deploy keys. sshd runs this instead of whatever the
# client asked for, so a leaked key can only do what this script allows.
#
# authorized_keys binds each key to the apps it may touch:
#   command="/opt/deploy/bin/deploy.sh atlas-be",restrict ssh-ed25519 AAAA... slc-rdt/atlas-be
#
# The client then picks an action:
#   ssh deploy@host "deploy atlas-be <x.y.z release version | 40-hex commit sha>" < docker-compose.yml
#   ssh deploy@host "rollback atlas-be"
#   ssh deploy@host "stop atlas-be"
#
# Runtime secrets come from Vault on this host (AppRole in /etc/deploy/vault.env),
# so CI never holds them. The compose file sent by CI is checked against a
# denylist before anything runs, because docker access is root on this host.
set -euo pipefail
umask 077

readonly CONF_DIR=/etc/deploy
readonly APPS_DIR=$CONF_DIR/apps.d
readonly STATE_ROOT=/srv/deploy
readonly MAX_COMPOSE_BYTES=262144
readonly KEEP_RELEASES=5
readonly SAFE_PATH=/usr/local/bin:/usr/bin:/bin

die() { echo "deploy: $*" >&2; exit 1; }
log() { echo "deploy: $*" >&2; }

[ "$#" -gt 0 ] || die "this key is not bound to any app"

read -r -a req <<<"${SSH_ORIGINAL_COMMAND:-}"
[ "${#req[@]}" -ge 2 ] && [ "${#req[@]}" -le 3 ] || die "usage: deploy <app> <version|sha> | rollback <app> | stop <app>"
action=${req[0]}
app=${req[1]}
ref=${req[2]:-}

[[ $app =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "invalid app name"
bound=0
for a in "$@"; do [ "$a" = "$app" ] && bound=1; done
[ "$bound" = 1 ] || die "this key may not touch $app"
[ -f "$APPS_DIR/$app.conf" ] || die "$app is not configured on this host"

# Per-app settings, written by Ansible:
#   PROJECT          compose project name (keeps existing containers and volumes)
#   VAULT_PATH       KV path read at deploy time, e.g. kv/data/atlas-be
#   ALLOWED_BINDS    space-separated host paths a bind mount may use, besides $base/data
#   ROLLOUT_SERVICE  service to replace with docker-rollout (zero downtime), empty = plain recreate
#   DRAIN_SECONDS    how long an old container keeps serving after it starts failing its healthcheck
#   WAIT_TIMEOUT     seconds to wait for containers to become healthy
PROJECT=
VAULT_PATH=
ALLOWED_BINDS=
ROLLOUT_SERVICE=
DRAIN_SECONDS=10
WAIT_TIMEOUT=180
# shellcheck source=/dev/null
. "$APPS_DIR/$app.conf"
# shellcheck source=/dev/null
. "$CONF_DIR/deploy.env"
[[ $PROJECT =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "$app.conf: invalid PROJECT"
[ -n "$VAULT_PATH" ] || die "$app.conf: VAULT_PATH is empty"
[[ $WAIT_TIMEOUT =~ ^[0-9]+$ ]] || die "$app.conf: invalid WAIT_TIMEOUT"
[[ $DRAIN_SECONDS =~ ^[0-9]+$ ]] || die "$app.conf: invalid DRAIN_SECONDS"

base=$STATE_ROOT/$app
mkdir -p "$base/releases" "$base/data"
exec 9>"$base/.lock"
flock -w 600 9 || die "another deploy of $app is still running"

# Reads the app's KV entry into the array secret_env as KEY=value pairs. The
# values go straight into docker compose's environment, never onto disk or argv.
load_secrets() {
  # Declared local first so sourcing vault.env cannot leak into the caller.
  local VAULT_ADDR VAULT_ROLE_ID VAULT_SECRET_ID VAULT_CACERT token raw
  # shellcheck source=/dev/null
  . "$CONF_DIR/vault.env"

  token=$(
    jq -n --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id: $r, secret_id: $s}' |
      curl -fsS --cacert "$VAULT_CACERT" -X POST --data @- "$VAULT_ADDR/v1/auth/approle/login" |
      jq -er '.auth.client_token'
  ) || die "Vault login failed"

  # The token goes in through a header file so it never shows up in ps.
  raw=$(curl -fsS --cacert "$VAULT_CACERT" -H @<(printf 'X-Vault-Token: %s\n' "$token") \
    "$VAULT_ADDR/v1/$VAULT_PATH") || die "cannot read $VAULT_PATH from Vault"
  curl -fsS --cacert "$VAULT_CACERT" -H @<(printf 'X-Vault-Token: %s\n' "$token") \
    -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null || true

  # Some values were stored wrapped in double quotes; the old workflows stripped
  # them by hand, so strip one surrounding pair here. Keys are upper-cased like
  # vault-action did, since the compose files reference ${UPPER_CASE} names.
  # Keys that would steer compose or this script itself are dropped.
  secret_env=()
  readarray -d '' secret_env < <(
    jq -j '
      (.data.data // .data) | to_entries[]
      | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
      | .key |= ascii_upcase
      | select(.key | test("^(PATH|HOME|IMAGE_TAG|REGISTRY_URL|COMPOSE_.*|DOCKER_.*)$") | not)
      | "\(.key)=\(.value | tostring | sub("^\"(?<v>.*)\"$"; "\(.v)"))\u0000"
    ' <<<"$raw"
  )
}

compose() {
  local file=$1 tag=$2
  shift 2
  env -i PATH="$SAFE_PATH" HOME="$HOME" COMPOSE_PROJECT_NAME="$PROJECT" \
    "${secret_env[@]}" IMAGE_TAG="$tag" REGISTRY_URL="$REGISTRY_URL" \
    docker compose --project-directory "$base" -f "$file" "$@"
}

# Rejects anything in the compose file that would let a container reach the
# host: privileged mode, host namespaces, extra capabilities, devices, the
# docker socket, or bind mounts outside $base/data and ALLOWED_BINDS.
check_policy() {
  local file=$1 tag=$2

  # Keys that make compose read other files from this host while rendering.
  if grep -Eq '(^|[[:space:]{,"'\''])(env_file|extends|include)["'\'']?[[:space:]]*:' "$file"; then
    die "compose file uses env_file, extends or include, which are not allowed"
  fi

  local rendered
  rendered=$(compose "$file" "$tag" config --format json 2>/dev/null) || die "compose file does not render"

  local problems
  problems=$(jq -r '
    def host_ns: . == "host" or ((. // "") | tostring | startswith("container:"));
    (.services // {} | to_entries[] | .key as $s | .value | (
      (select(.privileged == true) | "\($s): privileged"),
      (select((.cap_add // []) | length > 0) | "\($s): cap_add"),
      (select((.devices // []) | length > 0) | "\($s): devices"),
      (select((.device_cgroup_rules // []) | length > 0) | "\($s): device_cgroup_rules"),
      (select((.network_mode // "") | host_ns) | "\($s): network_mode \(.network_mode)"),
      (select((.pid // "") | host_ns) | "\($s): pid \(.pid)"),
      (select((.ipc // "") | host_ns) | "\($s): ipc \(.ipc)"),
      (select(.uts == "host") | "\($s): uts host"),
      (select(.userns_mode == "host") | "\($s): userns_mode host"),
      (select(.cgroup == "host") | "\($s): cgroup host"),
      (select(.cgroup_parent != null) | "\($s): cgroup_parent"),
      (select(.runtime != null) | "\($s): runtime"),
      (select((.volumes_from // []) | length > 0) | "\($s): volumes_from"),
      (select((.security_opt // []) | map(test("unconfined|label[:=]disable|no-new-privileges[:=]false")) | any) | "\($s): security_opt"),
      (.volumes // [] | .[] | select(.type != "bind" and .type != "volume" and .type != "tmpfs") | "\($s): volume type \(.type)")
    )),
    (.volumes // {} | to_entries[] | select(.value.driver_opts != null) | "volume \(.key): driver_opts"),
    (.secrets // {}, .configs // {} | to_entries[] | select(.value.file != null) | "secret/config \(.key): file source")
  ' <<<"$rendered")
  [ -z "$problems" ] || die "compose file rejected:"$'\n'"$problems"

  # Bind sources are resolved on the host, so a symlink planted inside
  # $base/data cannot point a later mount somewhere else.
  local src real ok allowed
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    real=$(realpath -m -- "$src")
    case $real in *docker.sock*) die "bind mount of the docker socket is not allowed" ;; esac
    ok=0
    if [ "$real" = "$base/data" ] || [[ $real == "$base/data/"* ]]; then ok=1; fi
    for allowed in $ALLOWED_BINDS; do
      if [ "$real" = "$allowed" ] || [[ $real == "$allowed/"* ]]; then ok=1; fi
    done
    [ "$ok" = 1 ] || die "bind mount of $real is not allowed (use $base/data or ask an admin to allow it)"
  done < <(jq -r '.services // {} | .[] | .volumes // [] | .[] | select(.type == "bind") | .source' <<<"$rendered")
}

# Brings the release up. With ROLLOUT_SERVICE set and the docker-rollout plugin
# installed, that service is replaced without downtime: the new container has
# to pass its healthcheck before the old one is stopped. Everything else is
# recreated in place, which costs a few seconds per changed container.
roll_out() {
  local file=$1 tag=$2
  compose "$file" "$tag" pull --quiet
  if [ -n "$ROLLOUT_SERVICE" ] && docker rollout --help >/dev/null 2>&1; then
    compose "$file" "$tag" up -d --no-build --no-recreate --remove-orphans
    # $file lives in $base, so compose inside docker-rollout resolves the same
    # project directory without being told.
    # Docker's own DNS starts handing out the new container before it is ready
    # and keeps handing out the old one while it stops, so this only reaches
    # zero downtime behind a proxy that follows healthchecks (Traefik). The
    # hook makes the old container report unhealthy first, the proxy drops it,
    # and only then is it stopped. The service's healthcheck must fail once
    # /tmp/drain exists for this to work.
    env -i PATH="$SAFE_PATH" HOME="$HOME" COMPOSE_PROJECT_NAME="$PROJECT" \
      "${secret_env[@]}" IMAGE_TAG="$tag" REGISTRY_URL="$REGISTRY_URL" \
      docker rollout -f "$file" -t "$WAIT_TIMEOUT" \
      --pre-stop-hook "touch /tmp/drain && sleep $DRAIN_SECONDS" "$ROLLOUT_SERVICE"
  else
    compose "$file" "$tag" up -d --no-build --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"
  fi
}

prune_releases() {
  local keep_current keep_previous
  keep_current=$(cat "$base/current" 2>/dev/null || true)
  keep_previous=$(cat "$base/previous" 2>/dev/null || true)
  ls -1t "$base/releases" | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
    [ "$old" != "$keep_current" ] && [ "$old" != "$keep_previous" ] || continue
    # Every release pulls a :<tag> image, which image prune never removes
    # because it is still tagged. Drop the ones this forgotten release used,
    # taken from its own compose file: a version such as 1.0.1 is not unique
    # across apps on the host the way a commit sha is.
    compose "$base/releases/$old/docker-compose.yml" "$old" config --images 2>/dev/null </dev/null |
      awk -v t=":$old" 'length($0) > length(t) && substr($0, length($0) - length(t) + 1) == t' |
      xargs -r docker image rm >/dev/null 2>&1 || true
    rm -rf -- "${base:?}/releases/$old"
  done
}

release_to() {
  local target=$1
  local file=$base/releases/$target/docker-compose.yml
  [ -f "$file" ] || die "release $target is not on this host"
  check_policy "$file" "$target"
  cp "$file" "$base/docker-compose.yml"

  local before
  before=$(cat "$base/current" 2>/dev/null || true)
  log "rolling out $app at ${target:0:12}"
  if roll_out "$base/docker-compose.yml" "$target"; then
    if [ "$before" != "$target" ]; then
      [ -z "$before" ] || echo "$before" >"$base/previous"
      echo "$target" >"$base/current"
    fi
    docker image prune -f >/dev/null
    prune_releases
    log "$app is running ${target:0:12}"
    return 0
  fi

  log "rollout of ${target:0:12} failed"
  if [ -n "$before" ] && [ "$before" != "$target" ] && [ -f "$base/releases/$before/docker-compose.yml" ]; then
    log "restoring ${before:0:12}"
    cp "$base/releases/$before/docker-compose.yml" "$base/docker-compose.yml"
    roll_out "$base/docker-compose.yml" "$before" || log "restore failed too, check the host"
  fi
  return 1
}

case $action in
  deploy)
    [[ $ref =~ ^[0-9a-f]{40}$ || $ref =~ ^[0-9]{1,5}.[0-9]{1,5}.[0-9]{1,5}$ ]] ||
      die "deploy needs an x.y.z release version or a full 40-character commit sha"
    rel=$base/releases/$ref
    mkdir -p "$rel"
    head -c $((MAX_COMPOSE_BYTES + 1)) >"$rel/docker-compose.yml.part"
    [ "$(stat -c %s "$rel/docker-compose.yml.part")" -le "$MAX_COMPOSE_BYTES" ] || die "compose file too large"
    [ -s "$rel/docker-compose.yml.part" ] || die "no compose file on stdin"
    mv "$rel/docker-compose.yml.part" "$rel/docker-compose.yml"
    load_secrets
    release_to "$ref"
    ;;
  rollback)
    [ -z "$ref" ] || die "rollback takes no version, it returns to the previous release"
    prev=$(cat "$base/previous" 2>/dev/null || true)
    [ -n "$prev" ] || die "$app has no previous release to return to"
    load_secrets
    release_to "$prev"
    ;;
  stop)
    [ -z "$ref" ] || die "stop takes no version"
    [ -f "$base/docker-compose.yml" ] || die "$app has never been deployed through this script"
    load_secrets
    compose "$base/docker-compose.yml" "$(cat "$base/current")" down --remove-orphans
    ;;
  *)
    die "unknown action $action"
    ;;
esac
