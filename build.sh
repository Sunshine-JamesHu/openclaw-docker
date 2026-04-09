#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
BUILD_DIR="$PROJECT_DIR/.build"
TEMPLATE_DIR="$PROJECT_DIR/templates"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

require_templates() {
  [[ -f "$TEMPLATE_DIR/docker-compose.yml" ]] || fail "missing template: $TEMPLATE_DIR/docker-compose.yml"
  [[ -f "$TEMPLATE_DIR/.env" ]] || fail "missing template: $TEMPLATE_DIR/.env"
  [[ -f "$TEMPLATE_DIR/openclaw.json" ]] || fail "missing template: $TEMPLATE_DIR/openclaw.json"
}

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
CACHE_DIR="$PROJECT_DIR/.cache"
SRC_ZIP="$CACHE_DIR/openclaw-src-${OPENCLAW_VERSION}.zip"

command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
command -v unzip >/dev/null 2>&1 || fail "unzip is not installed"
command -v openssl >/dev/null 2>&1 || fail "openssl is not installed"

mkdir -p "$DIST_DIR" "$CACHE_DIR"
require_templates

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

NPM_MIRROR_PATCH="$(cat <<'EOF'
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com/
RUN npm config --location=global set registry "$NPM_CONFIG_REGISTRY" && \
    npm install -g npm@latest --registry="$NPM_CONFIG_REGISTRY"
EOF
)"

DOCKERFILE_TMP="$DOCKERFILE.tmp"
awk -v patch="$NPM_MIRROR_PATCH" '
  !done && $0 ~ /^RUN corepack enable$/ {
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
' "$DOCKERFILE" > "$DOCKERFILE_TMP" || fail "failed to patch Dockerfile with npm mirror for build stage"
mv "$DOCKERFILE_TMP" "$DOCKERFILE"

DOCKERFILE_TMP="$DOCKERFILE.tmp"
awk -v patch="$NPM_MIRROR_PATCH" '
  !done && $0 ~ /^RUN chown node:node \/app$/ {
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
' "$DOCKERFILE" > "$DOCKERFILE_TMP" || fail "failed to patch Dockerfile with npm mirror for runtime stage"
mv "$DOCKERFILE_TMP" "$DOCKERFILE"

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
rm -f "$DIST_DIR/docker-compose.yml" "$DIST_DIR/.env" "$DIST_DIR/openclaw.json" "$DIST_DIR/setup.sh" "$DIST_DIR/VERSION"
rm -rf "$DIST_DIR/tls"

cp "$TEMPLATE_DIR/docker-compose.yml" "$DIST_DIR/docker-compose.yml"
cp "$TEMPLATE_DIR/.env" "$DIST_DIR/.env"
cp "$TEMPLATE_DIR/openclaw.json" "$DIST_DIR/openclaw.json"

printf '%s\n' "$OPENCLAW_VERSION" > "$DIST_DIR/VERSION"
ok "VERSION -> $OPENCLAW_VERSION"

mkdir -p "$DIST_DIR/tls"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$DIST_DIR/tls/key.pem" \
  -out "$DIST_DIR/tls/cert.pem" \
  -days 3650 \
  -subj "/CN=openclaw-gateway" \
  >/dev/null 2>&1
ok "bundled self-signed TLS cert written to dist/tls/"
ok "default openclaw.json written"

cp "$PROJECT_DIR/setup.sh" "$DIST_DIR/setup.sh"
chmod +x "$DIST_DIR/setup.sh"

echo ""
echo -e "${GREEN}Build complete.${NC}"
echo "dist/ contains:"
echo "  openclaw.tar (${TAR_SIZE})"
echo "  VERSION (${OPENCLAW_VERSION})"
echo "  docker-compose.yml"
echo "  .env"
echo "  openclaw.json"
echo "  tls/cert.pem"
echo "  tls/key.pem"
echo "  setup.sh"
