#!/usr/bin/env bash
#
# CSE -> Blumira relay :: one-command client installer
#
# Pulls the relay engine from your repo, prompts for this client's secrets,
# and stands up an isolated Docker stack namespaced by a client slug. Run it
# once per client on the Ubuntu host.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/m-timm/NOCTeamTools/main/cse-blumira-relay/install.sh | bash
#   # or, after cloning:
#   ./install.sh
#
# Flags / env:
#   --update            re-pull the engine and rebuild the shared image
#   --no-start          write the stack but don't 'docker compose up'
#   REPO_RAW=<url>      override the raw base URL the engine is pulled from
#   BASE_DIR=<path>     override install root (default: ~/cse-blumira-relay)
#
set -euo pipefail

# ---- configuration ---------------------------------------------------------
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/m-timm/BlumiraScripts/main/cse-blumira-relay}"
BASE_DIR="${BASE_DIR:-$HOME/cse-blumira-relay}"
IMAGE="cse-blumira-relay:latest"
ENGINE_DIR="$BASE_DIR/_engine"
ENGINE_FILES=(relay.py Dockerfile requirements.txt)

DO_UPDATE=0
DO_START=1
for arg in "$@"; do
  case "$arg" in
    --update)   DO_UPDATE=1 ;;
    --no-start) DO_START=0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---- prompt plumbing (works under 'curl | bash' via /dev/tty) --------------
if [ -e /dev/tty ] && [ -z "${RELAY_NONINTERACTIVE:-}" ]; then
  exec 3</dev/tty
else
  exec 3<&0   # test / non-interactive: read from stdin
fi

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
err()  { printf '%s%s%s\n' "$c_red" "$*" "$c_rst" >&2; }

prompt() {  # prompt <var> <label> [default]
  local __var="$1" __label="$2" __def="${3:-}" __ans=""
  if [ -n "$__def" ]; then
    printf '%s [%s%s%s]: ' "$__label" "$c_dim" "$__def" "$c_rst" >&2
  else
    printf '%s: ' "$__label" >&2
  fi
  IFS= read -r -u 3 __ans || true
  [ -z "$__ans" ] && __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
}

prompt_secret() {  # prompt_secret <var> <label>
  local __var="$1" __label="$2" __ans=""
  printf '%s: ' "$__label" >&2
  IFS= read -r -s -u 3 __ans || true
  printf '\n' >&2
  printf -v "$__var" '%s' "$__ans"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }; }

compose() {  # wrapper for 'docker compose' vs legacy 'docker-compose'
  if docker compose version >/dev/null 2>&1; then docker compose "$@";
  else docker-compose "$@"; fi
}

# ---- preflight -------------------------------------------------------------
say "${c_bold}CSE -> Blumira relay installer${c_rst}"
need_cmd curl
need_cmd docker
docker info >/dev/null 2>&1 || { err "Docker daemon not reachable (is it running / are you in the docker group?)"; exit 1; }

# ---- pull engine + build shared image (once, or on --update) ---------------
build_needed=0
if [ "$DO_UPDATE" = "1" ] || [ ! -d "$ENGINE_DIR" ]; then build_needed=1; fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then build_needed=1; fi

if [ "$build_needed" = "1" ]; then
  say "Fetching engine from ${c_dim}${REPO_RAW}${c_rst}"
  mkdir -p "$ENGINE_DIR"
  for f in "${ENGINE_FILES[@]}"; do
    curl -fsSL "$REPO_RAW/$f" -o "$ENGINE_DIR/$f" \
      || { err "Failed to fetch $f from $REPO_RAW"; exit 1; }
  done
  say "Building image ${c_dim}${IMAGE}${c_rst} ..."
  docker build -t "$IMAGE" "$ENGINE_DIR" >/dev/null
  ok "Image ready."
else
  say "Engine image ${c_dim}${IMAGE}${c_rst} already present (use --update to refresh)."
fi

# ---- prompt for this client ------------------------------------------------
say ""
say "${c_bold}New client${c_rst}"

SLUG=""
while :; do
  prompt SLUG "Client slug (lowercase, hyphens, e.g. acme-corp)"
  if printf '%s' "$SLUG" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then break; fi
  err "  slug must be lowercase letters/digits/hyphens"
done

CLIENT_DIR="$BASE_DIR/$SLUG"
if [ -e "$CLIENT_DIR/config.yaml" ]; then
  prompt OVERWRITE "Stack for '$SLUG' already exists. Overwrite config? (y/N)" "N"
  case "$OVERWRITE" in [yY]*) : ;; *) err "Aborted."; exit 1 ;; esac
fi

prompt TENANT_NAME   "Display name for logs"                 "$SLUG"
prompt CSE_CC        "CSE Command Center URL"                "https://net.banyanops.com"
prompt_secret CSE_KEY "CSE API Key Secret (hidden)"
prompt BLUM_URL      "Blumira ingestion service URL"
prompt_secret BLUM_TOKEN "Blumira token (hidden)"
prompt POLL_INT      "Poll interval seconds"                 "60"

[ -n "$CSE_KEY" ]    || { err "CSE API key is required."; exit 1; }
[ -n "$BLUM_URL" ]   || { err "Blumira URL is required."; exit 1; }
[ -n "$BLUM_TOKEN" ] || { err "Blumira token is required."; exit 1; }

# ---- write the client stack ------------------------------------------------
mkdir -p "$CLIENT_DIR"
PROJECT="cse-blumira-$SLUG"
VOLUME="${PROJECT}-state"

umask 077   # config.yaml is created 0600
cat > "$CLIENT_DIR/config.yaml" <<YAML
# Generated by install.sh for client: $SLUG
poll_interval_seconds: $POLL_INT

tenants:
  - name: "$TENANT_NAME"
    cse_command_center: "$CSE_CC"
    cse_api_key: "$CSE_KEY"
    blumira_url: "$BLUM_URL"
    blumira_token: "$BLUM_TOKEN"
YAML
umask 022

cat > "$CLIENT_DIR/docker-compose.yml" <<YAML
name: $PROJECT
services:
  relay:
    image: $IMAGE
    container_name: $PROJECT
    restart: unless-stopped
    volumes:
      - ./config.yaml:/config/config.yaml:ro
      - state:/data
    environment:
      RELAY_LOG_LEVEL: INFO
    healthcheck:
      test: ["CMD", "python", "-c",
             "import os,time,sys; f='/data/heartbeat'; sys.exit(0 if os.path.exists(f) and time.time()-os.path.getmtime(f) < 600 else 1)"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
volumes:
  state:
    name: $VOLUME
YAML

ok "Wrote stack to $CLIENT_DIR"

# ---- start -----------------------------------------------------------------
if [ "$DO_START" = "1" ]; then
  say "Starting ${c_dim}${PROJECT}${c_rst} ..."
  ( cd "$CLIENT_DIR" && compose up -d )
  ok "Up. Tail logs with:  (cd $CLIENT_DIR && docker compose logs -f)"
else
  say "Skipped start (--no-start). Bring up with:  (cd $CLIENT_DIR && docker compose up -d)"
fi

say ""
say "${c_bold}Next:${c_rst} confirm the CSE time params / id field and Blumira POST mode"
say "in $CLIENT_DIR/config.yaml against this client's live data, then watch the log"
say "for 'forwarded N new'. Re-run this installer for the next client."
