#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
BUILD_DIR="$PROJECT_DIR/.build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

OPENCLAW_VERSION=""
RAW_TAG=""

usage() {
  cat <<'EOF'
Usage: ./build.sh [-v version]

Examples:
  ./build.sh
  ./build.sh -v 2026.3.23
EOF
}

latest_tag() {
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/openclaw/openclaw/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)"

  if [[ -z "$tag" ]]; then
    warn "GitHub API did not return a tag. Falling back to releases/latest ..."
    tag="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/openclaw/openclaw/releases/latest" 2>/dev/null \
      | sed -n 's#.*/tag/\(v[^/[:space:]]*\)$#\1#p' | tail -1 || true)"
  fi

  [[ -n "$tag" ]] || fail "unable to resolve the latest OpenClaw release tag"
  printf '%s\n' "$tag"
}

while getopts "v:h" opt; do
  case "$opt" in
    v) OPENCLAW_VERSION="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$OPENCLAW_VERSION" ]]; then
  RAW_TAG="$(latest_tag)"
  OPENCLAW_VERSION="${RAW_TAG#v}"
  OPENCLAW_VERSION="${OPENCLAW_VERSION%%-*}"
  ok "latest version: ${OPENCLAW_VERSION} (tag ${RAW_TAG})"
else
  RAW_TAG="v${OPENCLAW_VERSION}"
fi

IMAGE_TAG="openclaw:${OPENCLAW_VERSION}"
TAR_FILE="$DIST_DIR/openclaw.tar"
SRC_ZIP="$DIST_DIR/openclaw-src-${OPENCLAW_VERSION}.zip"

command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
command -v unzip >/dev/null 2>&1 || fail "unzip is not installed"
command -v openssl >/dev/null 2>&1 || fail "openssl is not installed"

mkdir -p "$DIST_DIR"

if [[ ! -f "$SRC_ZIP" ]]; then
  info "downloading source archive ${RAW_TAG} ..."
  curl -fSL -o "$SRC_ZIP" "https://github.com/openclaw/openclaw/archive/refs/tags/${RAW_TAG}.zip" \
    || fail "failed to download ${RAW_TAG}"
  ok "source archive saved: $SRC_ZIP"
else
  ok "source archive already exists: $SRC_ZIP"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
info "extracting source archive ..."
unzip -qo "$SRC_ZIP" -d "$BUILD_DIR"

EXTRACTED_DIR="$BUILD_DIR/$(ls "$BUILD_DIR" | head -1)"
[[ -d "$EXTRACTED_DIR" ]] || fail "unable to find extracted source directory"

DOCKERFILE="$EXTRACTED_DIR/Dockerfile"
[[ -f "$DOCKERFILE" ]] || fail "Dockerfile not found in extracted source"
sed -i '/^# syntax=/d' "$DOCKERFILE"

USTC_DEBIAN_PATCH="$(cat <<'EOF'
RUN set -eux; \
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
      if [ -f "$file" ]; then \
        sed -i \
          -e 's|http://deb.debian.org/debian|https://mirrors.ustc.edu.cn/debian|g' \
          -e 's|https://deb.debian.org/debian|https://mirrors.ustc.edu.cn/debian|g' \
          -e 's|http://security.debian.org/debian-security|https://mirrors.ustc.edu.cn/debian-security|g' \
          -e 's|https://security.debian.org/debian-security|https://mirrors.ustc.edu.cn/debian-security|g' \
          -e 's|http://deb.debian.org/debian-security|https://mirrors.ustc.edu.cn/debian-security|g' \
          -e 's|https://deb.debian.org/debian-security|https://mirrors.ustc.edu.cn/debian-security|g' \
          "$file"; \
      fi; \
    done
EOF
)"

DOCKERFILE_TMP="$DOCKERFILE.tmp"
awk -v patch="$USTC_DEBIAN_PATCH" '
  !done && $0 ~ /^FROM base-\$\{OPENCLAW_VARIANT\}/ {
    print
    print ""
    print patch
    done=1
    next
  }
  { print }
  END {
    if (!done) {
      exit 1
    }
  }
' "$DOCKERFILE" > "$DOCKERFILE_TMP" || fail "failed to patch Dockerfile with USTC apt mirror"
mv "$DOCKERFILE_TMP" "$DOCKERFILE"

DEFAULT_AGENT_CLI_PATCH="$(cat <<'EOF'
RUN npm install -g @openai/codex @google/gemini-cli @anthropic-ai/claude-code && \
    command -v codex && \
    command -v gemini && \
    command -v claude
EOF
)"

DOCKERFILE_TMP="$DOCKERFILE.tmp"
awk -v patch="$DEFAULT_AGENT_CLI_PATCH" '
  !done && $0 ~ /^ENV NODE_ENV=production$/ {
    print patch
    print ""
    done=1
  }
  { print }
  END {
    if (!done) {
      exit 1
    }
  }
' "$DOCKERFILE" > "$DOCKERFILE_TMP" || fail "failed to patch Dockerfile with default agent CLIs"
mv "$DOCKERFILE_TMP" "$DOCKERFILE"

info "building image ${IMAGE_TAG} ..."
docker build \
  -t "$IMAGE_TAG" \
  -t "openclaw:latest" \
  -f "$DOCKERFILE" \
  "$EXTRACTED_DIR"
ok "image build completed"

info "saving image tar ..."
docker save "$IMAGE_TAG" -o "$TAR_FILE"
TAR_SIZE="$(du -h "$TAR_FILE" | cut -f1)"
ok "image tar saved: $TAR_FILE (${TAR_SIZE})"

info "writing deployment files to dist/ ..."

cat > "$DIST_DIR/docker-compose.yml" <<'YAML'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE:-openclaw:latest}
    container_name: openclaw-gateway
    pull_policy: never
    restart: unless-stopped
    init: true
    user: ${OPENCLAW_CONTAINER_USER:-0:0}
    privileged: true
    ports:
      - "${OPENCLAW_GATEWAY_PORT:-18789}:18789"
      - "${OPENCLAW_BRIDGE_PORT:-18790}:18790"
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${OPENCLAW_TZ:-Asia/Shanghai}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN:-}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      ZAI_API_KEY: ${ZAI_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      GEMINI_API_KEY: ${GEMINI_API_KEY:-}
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:-}
      DISCORD_BOT_TOKEN: ${DISCORD_BOT_TOKEN:-}
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN:-}
      CLAUDE_AI_SESSION_KEY: ${CLAUDE_AI_SESSION_KEY:-}
      CLAUDE_WEB_SESSION_KEY: ${CLAUDE_WEB_SESSION_KEY:-}
      CLAUDE_WEB_COOKIE: ${CLAUDE_WEB_COOKIE:-}
    volumes:
      - ${OPENCLAW_HOST_DIR:-/data/openclaw}:/home/node/.openclaw
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--allow-unconfigured",
        "--bind",
        "lan",
        "--port",
        "18789",
      ]
    healthcheck:
      test:
        [
          "CMD",
          "curl",
          "-kfsS",
          "https://127.0.0.1:18789/healthz",
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  openclaw-cli:
    image: ${OPENCLAW_IMAGE:-openclaw:latest}
    container_name: openclaw-cli
    pull_policy: never
    network_mode: "service:openclaw-gateway"
    profiles:
      - cli
    stdin_open: true
    tty: true
    init: true
    user: ${OPENCLAW_CONTAINER_USER:-0:0}
    privileged: true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${OPENCLAW_TZ:-Asia/Shanghai}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN:-}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      BROWSER: echo
      ZAI_API_KEY: ${ZAI_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      GEMINI_API_KEY: ${GEMINI_API_KEY:-}
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:-}
      DISCORD_BOT_TOKEN: ${DISCORD_BOT_TOKEN:-}
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN:-}
      CLAUDE_AI_SESSION_KEY: ${CLAUDE_AI_SESSION_KEY:-}
      CLAUDE_WEB_SESSION_KEY: ${CLAUDE_WEB_SESSION_KEY:-}
      CLAUDE_WEB_COOKIE: ${CLAUDE_WEB_COOKIE:-}
    volumes:
      - ${OPENCLAW_HOST_DIR:-/data/openclaw}:/home/node/.openclaw
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway
YAML

cat > "$DIST_DIR/.env" <<EOF
# OpenClaw Docker deployment
OPENCLAW_VERSION=${OPENCLAW_VERSION}
OPENCLAW_IMAGE=openclaw:${OPENCLAW_VERSION}

# Fixed host mount directory
OPENCLAW_HOST_DIR=/data/openclaw

# Container runtime user. Root by default so OpenClaw can install packages.
OPENCLAW_CONTAINER_USER=0:0

# Gateway auth token
OPENCLAW_GATEWAY_TOKEN=1234567890

# Network ports
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790

# Timezone
OPENCLAW_TZ=Asia/Shanghai

# AI provider keys
# ZAI_API_KEY=
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...
# GEMINI_API_KEY=...

# Optional channel tokens
# TELEGRAM_BOT_TOKEN=
# DISCORD_BOT_TOKEN=
# SLACK_BOT_TOKEN=xoxb-...

# Optional advanced settings
# OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=
# CLAUDE_AI_SESSION_KEY=
# CLAUDE_WEB_SESSION_KEY=
# CLAUDE_WEB_COOKIE=
EOF

mkdir -p "$DIST_DIR/tls"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$DIST_DIR/tls/key.pem" \
  -out "$DIST_DIR/tls/cert.pem" \
  -days 3650 \
  -subj "/CN=openclaw-gateway" \
  >/dev/null 2>&1
ok "bundled self-signed TLS cert written to dist/tls/"

cat > "$DIST_DIR/openclaw.json" <<'JSONEOF'
{
  "gateway": {
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    },
    "tls": {
      "enabled": true,
      "certPath": "/home/node/.openclaw/tls/cert.pem",
      "keyPath": "/home/node/.openclaw/tls/key.pem"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "zai/glm-5"
      },
      "models": {
        "zai/glm-5": {}
      }
    }
  }
}
JSONEOF
ok "default openclaw.json written"

cp "$PROJECT_DIR/setup.sh" "$DIST_DIR/setup.sh"
chmod +x "$DIST_DIR/setup.sh"

echo ""
echo -e "${GREEN}Build complete.${NC}"
echo "dist/ contains:"
echo "  openclaw.tar (${TAR_SIZE})"
echo "  openclaw-src-${OPENCLAW_VERSION}.zip"
echo "  docker-compose.yml"
echo "  .env"
echo "  openclaw.json"
echo "  tls/cert.pem"
echo "  tls/key.pem"
echo "  setup.sh"
