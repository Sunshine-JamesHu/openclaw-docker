#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE_TAR="$SCRIPT_DIR/openclaw.tar"
VERSION_FILE="$SCRIPT_DIR/VERSION"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

LAST_LOADED_IMAGE_REF=""
ACTION=""

PAIR_IP=""
PAIR_REQUEST_ID=""
EXEC_ARGS=()

compose_cmd() {
  COMPOSE_PROJECT_NAME="$(compose_project_name)" \
  OPENCLAW_GATEWAY_CONTAINER_NAME="$(gateway_container_name)" \
  OPENCLAW_CLI_CONTAINER_NAME="$(cli_container_name)" \
  OPENCLAW_HOST_DIR="$(host_dir)" \
  OPENCLAW_IMAGE="$(image_ref)" \
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

version_get() {
  [[ -f "$VERSION_FILE" ]] || fail "missing VERSION file in $SCRIPT_DIR"
  tr -d '[:space:]' < "$VERSION_FILE"
}

env_get() {
  local key="$1" fallback="${2:-}"
  local val
  val="$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//; s/['\"]$//")"
  echo "${val:-$fallback}"
}

env_set() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

project_name() {
  local name
  name="$(env_get OPENCLAW_PROJECT_NAME koala)"
  [[ "$name" =~ ^[a-z]+$ ]] || fail "OPENCLAW_PROJECT_NAME must contain only lowercase English letters"
  printf '%s\n' "$name"
}

compose_project_name() {
  local value
  value="$(env_get COMPOSE_PROJECT_NAME)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf 'openclaw-%s\n' "$(project_name)"
}

gateway_container_name() {
  local value
  value="$(env_get OPENCLAW_GATEWAY_CONTAINER_NAME)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf 'openclaw-gateway-%s\n' "$(project_name)"
}

cli_container_name() {
  local value
  value="$(env_get OPENCLAW_CLI_CONTAINER_NAME)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf 'openclaw-cli-%s\n' "$(project_name)"
}

host_dir() {
  local value
  value="$(env_get OPENCLAW_HOST_DIR)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '/data/openclaw-%s\n' "$(project_name)"
}

image_ref() {
  printf 'openclaw:%s\n' "$(version_get)"
}

gateway_port() {
  env_get OPENCLAW_GATEWAY_PORT 18789
}

gateway_token() {
  env_get OPENCLAW_GATEWAY_TOKEN 1234567890
}

docker_exec_cmd() {
  local container="$1"
  shift

  if [[ -t 0 && -t 1 ]]; then
    docker exec -it "$container" "$@"
  else
    docker exec -i "$container" "$@"
  fi
}

lan_ip() {
  hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\./) { print $i; exit }}'
}

require_files() {
  [[ -f "$COMPOSE_FILE" ]] || fail "missing docker-compose.yml in $SCRIPT_DIR"
  [[ -f "$ENV_FILE" ]] || fail "missing .env in $SCRIPT_DIR"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
  docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
}

ensure_env_defaults() {
  require_files

  if [[ -z "$(env_get OPENCLAW_PROJECT_NAME)" ]]; then
    env_set OPENCLAW_PROJECT_NAME "koala"
  fi

  project_name >/dev/null

  if [[ -z "$(env_get OPENCLAW_GATEWAY_TOKEN)" ]]; then
    env_set OPENCLAW_GATEWAY_TOKEN "1234567890"
  fi

  if [[ -z "$(env_get OPENCLAW_TZ)" ]]; then
    env_set OPENCLAW_TZ "Asia/Shanghai"
  fi
}

image_version_from_ref() {
  local ref="$1" repo tag
  [[ "$ref" == *:* ]] || return 1
  [[ "$ref" != *@* ]] || return 1
  repo="${ref%:*}"
  tag="${ref##*:}"
  case "$repo" in
    openclaw|*/openclaw) printf '%s\n' "$tag" ;;
    *) return 1 ;;
  esac
}

load_image() {
  local tar="$1"
  local target_image="${2:-}"
  local force_load="${3:-0}"

  [[ -f "$tar" ]] || fail "image tar not found: $tar"

  LAST_LOADED_IMAGE_REF=""
  if [[ -n "$target_image" && "$force_load" != "1" ]] && docker image inspect "$target_image" >/dev/null 2>&1; then
    ok "image already present: $target_image"
    LAST_LOADED_IMAGE_REF="$target_image"
    return 0
  fi

  info "loading image from $(basename "$tar") ..."
  local output loaded_tag loaded_id source_ref
  output="$(docker load -i "$tar")"
  loaded_tag="$(printf '%s\n' "$output" | sed -n 's/^Loaded image: //p' | tail -1)"
  loaded_id="$(printf '%s\n' "$output" | sed -n 's/^Loaded image ID: //p' | tail -1)"
  source_ref="${loaded_tag:-$loaded_id}"
  [[ -n "$source_ref" ]] || fail "docker load did not return a usable image reference"

  LAST_LOADED_IMAGE_REF="$source_ref"
  if [[ -n "$target_image" && "$source_ref" != "$target_image" ]]; then
    docker tag "$source_ref" "$target_image"
    source_ref="$target_image"
  fi

  ok "image loaded: $source_ref"
}

ensure_image_present() {
  local ref
  ref="$(image_ref)"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    [[ -f "$IMAGE_TAR" ]] || fail "image $ref is missing and $IMAGE_TAR was not found"
    load_image "$IMAGE_TAR" "$ref"
  fi
}

require_gateway_container_running() {
  local container
  container="$(gateway_container_name)"

  docker inspect "$container" >/dev/null 2>&1 || fail "container is not running: $container; run ./setup.sh -s start first"
  [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == "true" ]] \
    || fail "container is not running: $container; run ./setup.sh -s start first"
}

ensure_host_layout() {
  local dir
  dir="$(host_dir)"
  sudo mkdir -p "$dir" "$dir/tls" "$dir/workspace"
  ok "host dir: $dir"
}

migrate_legacy_layout() {
  local dir legacy entry base moved=0
  dir="$(host_dir)"
  legacy="$dir/config"

  if sudo test -d "$legacy"; then
    info "migrating legacy config layout from $legacy"
    while IFS= read -r -d '' entry; do
      base="$(basename "$entry")"
      if ! sudo test -e "$dir/$base"; then
        sudo mv "$entry" "$dir/$base"
        moved=1
      fi
    done < <(sudo find "$legacy" -mindepth 1 -maxdepth 1 -print0)
    sudo rmdir "$legacy" 2>/dev/null || true
  fi

  if [[ "$moved" == "1" ]]; then
    ok "legacy config layout migrated"
  fi
}

seed_defaults() {
  local dir
  dir="$(host_dir)"

  [[ -f "$SCRIPT_DIR/openclaw.json" ]] || fail "missing bundled openclaw.json"
  [[ -f "$SCRIPT_DIR/tls/cert.pem" ]] || fail "missing bundled tls/cert.pem"
  [[ -f "$SCRIPT_DIR/tls/key.pem" ]] || fail "missing bundled tls/key.pem"

  if ! sudo test -f "$dir/openclaw.json"; then
    sudo install -m 0644 "$SCRIPT_DIR/openclaw.json" "$dir/openclaw.json"
    ok "installed default config -> $dir/openclaw.json"
  fi

  if ! sudo test -f "$dir/tls/cert.pem"; then
    sudo install -m 0644 "$SCRIPT_DIR/tls/cert.pem" "$dir/tls/cert.pem"
    ok "installed default TLS cert -> $dir/tls/cert.pem"
  fi

  if ! sudo test -f "$dir/tls/key.pem"; then
    sudo install -m 0600 "$SCRIPT_DIR/tls/key.pem" "$dir/tls/key.pem"
    ok "installed default TLS key -> $dir/tls/key.pem"
  fi
}

require_initialized_config() {
  local dir
  dir="$(host_dir)"

  sudo test -f "$dir/openclaw.json" || fail "missing $dir/openclaw.json; run ./setup.sh -s install first"
  sudo test -f "$dir/tls/cert.pem" || fail "missing $dir/tls/cert.pem; run ./setup.sh -s install first"
  sudo test -f "$dir/tls/key.pem" || fail "missing $dir/tls/key.pem; run ./setup.sh -s install first"
}

fix_permissions() {
  local dir extensions_dir needs_fix=0
  dir="$(host_dir)"
  extensions_dir="$dir/extensions"

  # --- ownership: everything should be 0:0 ---
  local bad_owner
  bad_owner="$(sudo find "$dir" -not -uid 0 -o -not -gid 0 2>/dev/null | head -1)"
  if [[ -n "$bad_owner" ]]; then
    info "fixing ownership under $dir ..."
    sudo chown -R 0:0 "$dir" 2>/dev/null || warn "failed to chown $dir; run sudo chown -R 0:0 $dir"
    needs_fix=1
  fi

  # --- extensions: dirs 0755, files not group/other writable ---
  if sudo test -d "$extensions_dir"; then
    local bad_ext
    bad_ext="$(sudo find "$extensions_dir" \( -type d -not -perm 0755 \) -o \( -type f -perm /022 \) 2>/dev/null | head -1)"
    if [[ -n "$bad_ext" ]]; then
      info "hardening plugin permissions under $extensions_dir ..."
      sudo find "$extensions_dir" -type d -exec chmod 0755 {} + 2>/dev/null \
        || warn "failed to chmod plugin directories under $extensions_dir"
      sudo find "$extensions_dir" -type f -exec chmod go-w {} + 2>/dev/null \
        || warn "failed to chmod plugin files under $extensions_dir"
      needs_fix=1
    fi
  fi

  # --- openclaw.json: 0644 ---
  if sudo test -f "$dir/openclaw.json"; then
    local cur_perm
    cur_perm="$(sudo stat -c '%a' "$dir/openclaw.json" 2>/dev/null)"
    if [[ "$cur_perm" != "644" ]]; then
      sudo chmod 0644 "$dir/openclaw.json" 2>/dev/null || warn "failed to chmod $dir/openclaw.json"
      needs_fix=1
    fi
  fi

  # --- cert.pem: 0644 ---
  if sudo test -f "$dir/tls/cert.pem"; then
    local cur_perm
    cur_perm="$(sudo stat -c '%a' "$dir/tls/cert.pem" 2>/dev/null)"
    if [[ "$cur_perm" != "644" ]]; then
      sudo chmod 0644 "$dir/tls/cert.pem" 2>/dev/null || warn "failed to chmod $dir/tls/cert.pem"
      needs_fix=1
    fi
  fi

  # --- key.pem: 0600 ---
  if sudo test -f "$dir/tls/key.pem"; then
    local cur_perm
    cur_perm="$(sudo stat -c '%a' "$dir/tls/key.pem" 2>/dev/null)"
    if [[ "$cur_perm" != "600" ]]; then
      sudo chmod 0600 "$dir/tls/key.pem" 2>/dev/null || warn "failed to chmod $dir/tls/key.pem"
      needs_fix=1
    fi
  fi

  if [[ "$needs_fix" == "0" ]]; then
    ok "permissions OK"
  fi
}

wait_healthy() {
  local waited=0
  while [[ $waited -lt 60 ]]; do
    if compose_cmd ps openclaw-gateway 2>/dev/null | grep -q "healthy"; then
      ok "gateway is healthy"
      return 0
    fi
    if compose_cmd ps openclaw-gateway 2>/dev/null | grep -q "unhealthy"; then
      fail "gateway is unhealthy; inspect docker compose logs openclaw-gateway"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  warn "gateway did not report healthy within 60s"
}

pair_list_json() {
  docker exec -i "$(gateway_container_name)" node dist/index.js devices list --json
}

parse_pair_list() {
  docker exec -i "$(gateway_container_name)" node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8").trim();
if (!raw) {
  console.error("No JSON received from devices list.");
  process.exit(1);
}
const data = JSON.parse(raw);
const pending = Array.isArray(data.pending) ? data.pending.slice() : [];
const paired = Array.isArray(data.paired) ? data.paired.slice() : [];
pending.sort((a, b) => Number(b.ts || 0) - Number(a.ts || 0));

if (!pending.length) {
  console.log("No pending pairing requests.");
} else {
  console.log("Pending pairing requests:");
  for (const item of pending) {
    const ip = item.remoteIp || "-";
    const platform = item.platform || "-";
    const requestId = item.requestId || "-";
    console.log(`  ${requestId}  ip=${ip}  platform=${platform}`);
  }
}

if (paired.length) {
  console.log("");
  console.log("Paired devices:");
  for (const item of paired) {
    const deviceId = item.deviceId || "-";
    const clientId = item.clientId || "-";
    const platform = item.platform || "-";
    console.log(`  ${deviceId}  client=${clientId}  platform=${platform}`);
  }
}
'
}

resolve_request_id_by_ip() {
  local ip="$1"
  docker exec -i "$(gateway_container_name)" node -e '
const fs = require("fs");
const targetIp = process.argv[1];
const raw = fs.readFileSync(0, "utf8").trim();
if (!raw) {
  console.error("No JSON received from devices list.");
  process.exit(1);
}
const data = JSON.parse(raw);
const pending = Array.isArray(data.pending) ? data.pending.slice() : [];
const matches = pending
  .filter((item) => item && item.remoteIp === targetIp)
  .sort((a, b) => Number(b.ts || 0) - Number(a.ts || 0));

if (!matches.length) {
  console.error(`No pending request matched IP ${targetIp}.`);
  process.exit(2);
}

process.stdout.write(String(matches[0].requestId || ""));
' "$ip"
}

print_access_summary() {
  local port token ip
  port="$(gateway_port)"
  token="$(gateway_token)"
  ip="$(lan_ip)"

  echo ""
  echo -e "${GREEN}================================================${NC}"
  echo -e "${GREEN}OpenClaw $(version_get) is ready${NC}"
  echo -e "${GREEN}================================================${NC}"
  echo -e "Project:     $(project_name)"
  echo -e "Gateway:     $(gateway_container_name)"
  echo -e "CLI:         $(cli_container_name)"
  echo -e "HTTPS URL:   ${BLUE}https://localhost:${port}/#token=${token}${NC}"
  if [[ -n "$ip" ]]; then
    echo -e "HTTPS URL:   ${BLUE}https://${ip}:${port}/#token=${token}${NC} ${YELLOW}(LAN)${NC}"
  fi
  echo -e "Host dir:    $(host_dir)"
  echo -e "Config file: $(host_dir)/openclaw.json"
  echo -e "TLS files:   $(host_dir)/tls/"
  echo ""
  echo "If the browser says 'pairing required':"
  echo "  ./setup.sh -s pair-list"
  echo "  ./setup.sh -s pair-approve -i <ip-from-pair-list>"
  echo ""
}

do_install() {
  require_docker
  ensure_env_defaults
  [[ -f "$IMAGE_TAR" ]] || fail "image tar not found: $IMAGE_TAR"

  load_image "$IMAGE_TAR" "$(image_ref)"
  ensure_host_layout
  migrate_legacy_layout
  seed_defaults
  fix_permissions

  info "starting gateway ..."
  compose_cmd up -d openclaw-gateway
  wait_healthy
  print_access_summary
}

do_start() {
  require_docker
  ensure_env_defaults
  ensure_image_present
  ensure_host_layout
  migrate_legacy_layout
  require_initialized_config
  fix_permissions

  info "starting gateway ..."
  compose_cmd up -d openclaw-gateway
  wait_healthy
  ok "gateway started"
}

do_stop() {
  require_docker
  ensure_env_defaults
  info "stopping gateway ..."
  compose_cmd down --remove-orphans 2>/dev/null || true
  ok "gateway stopped"
}

do_update() {
  require_docker
  ensure_env_defaults
  [[ -f "$IMAGE_TAR" ]] || fail "image tar not found: $IMAGE_TAR"

  local target_image
  target_image="$(image_ref)"

  if docker image inspect "$target_image" >/dev/null 2>&1; then
    ok "image already present: $target_image"
  else
    info "image $target_image not found locally, loading from tar ..."
    load_image "$IMAGE_TAR" "$target_image" 1
    docker image inspect "$target_image" >/dev/null 2>&1 \
      || fail "image $target_image still not found after loading tar; check that openclaw.tar matches VERSION ($target_image)"
  fi

  info "stopping old containers ..."
  compose_cmd down --remove-orphans 2>/dev/null || true

  ensure_host_layout
  migrate_legacy_layout
  require_initialized_config
  fix_permissions

  info "starting updated gateway ..."
  compose_cmd up -d openclaw-gateway
  wait_healthy
  ok "gateway updated"
}

do_pair_list() {
  require_docker
  ensure_env_defaults
  require_gateway_container_running
  pair_list_json | parse_pair_list
}

do_pair_approve() {
  require_docker
  ensure_env_defaults
  require_gateway_container_running

  local request_id
  request_id="$PAIR_REQUEST_ID"

  if [[ -z "$request_id" && -n "$PAIR_IP" ]]; then
    request_id="$(pair_list_json | resolve_request_id_by_ip "$PAIR_IP")"
  fi

  [[ -n "$request_id" ]] || fail "use -i <client-ip> or -r <requestId>"

  docker exec -i "$(gateway_container_name)" node dist/index.js devices approve "$request_id"
  ok "approved pairing request: $request_id"
}

do_exec() {
  require_docker
  ensure_env_defaults
  require_gateway_container_running
  [[ ${#EXEC_ARGS[@]} -gt 0 ]] || fail "usage: ./setup.sh -s exec -- <command> [args...]"

  info "executing in $(gateway_container_name): ${EXEC_ARGS[*]}"
  docker_exec_cmd "$(gateway_container_name)" "${EXEC_ARGS[@]}"
}

usage() {
  cat <<'EOF'
Usage: ./setup.sh -s <action> [options]

Actions:
  install       Load the image tar, seed config/TLS into the fixed host dir, and start OpenClaw
  start         Start OpenClaw
  stop          Stop OpenClaw
  update        Reload openclaw.tar and restart OpenClaw (version auto-detected)
  exec          Execute a command inside the running gateway container
  pair-list     Show pending pairing requests and paired devices
  pair-approve  Approve a pending pairing request by IP or request id

Options:
  -i <client-ip>    Client IP for pair-approve
  -r <requestId>    Request id for pair-approve
  -h                Show this help

Environment:
  OPENCLAW_PROJECT_NAME in .env must be lowercase English letters only.

Examples:
  ./setup.sh -s exec -- openclaw plugins install @tencent-connect/openclaw-qqbot@latest
  ./setup.sh -s exec -- bash -lc 'npm config get registry'
EOF
}

while getopts "s:i:r:h" opt; do
  case "$opt" in
    s) ACTION="$OPTARG" ;;
    i) PAIR_IP="$OPTARG" ;;
    r) PAIR_REQUEST_ID="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

shift $((OPTIND - 1))

if [[ "$ACTION" == "exec" ]]; then
  EXEC_ARGS=("$@")
fi

[[ -n "$ACTION" ]] || { usage; exit 1; }

case "$ACTION" in
  install) do_install ;;
  start) do_start ;;
  stop) do_stop ;;
  update) do_update ;;
  exec) do_exec ;;
  pair-list) do_pair_list ;;
  pair-approve) do_pair_approve ;;
  *) fail "unknown action: $ACTION" ;;
esac
