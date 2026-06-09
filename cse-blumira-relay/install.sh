#!/usr/bin/env bash
#
# CSE -> Blumira relay :: one-command client installer (Compose-free)
#
# Pulls the relay engine from your repo, prompts for this client's secrets,
# and runs an isolated container per client via plain `docker run`. No Docker
# Compose required (works on appliance hosts that only ship the engine), and
# the container runs as root so a 0600 config needs no ownership juggling.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/m-timm/BlumiraScripts/main/cse-blumira-relay/install.sh | bash
#   ./install.sh
#
# Flags / env:
#   --update            re-pull the engine and rebuild the shared image
#   --no-start          write the config but don't start the container
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
  exec 3<&0
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

# ---- preflight -------------------------------------------------------------
say "${c_bold}CSE -> Blumira relay installer${c_rst}"
need_cmd curl
need_cmd docker
docker info >/dev/null 2>&1 || { err "Docker daemon not reachable (running? are you in the docker group?)"; exit 1; }

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
  prompt SLUG "Client slug (the part of the url before .portal.banyanops.com, e.g. trcs-hq)"
  if printf '%s' "$SLUG" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then break; fi
  err "  slug must be lowercase letters/digits/hyphens"
done

CLIENT_DIR="$BASE_DIR/$SLUG"
if [ -e "$CLIENT_DIR/config.yaml" ]; then
  prompt OVERWRITE "Config for '$SLUG' already exists. Overwrite? (y/N)" "N"
  case "$OVERWRITE" in [yY]*) : ;; *) err "Aborted."; exit 1 ;; esac
fi

prompt TENANT_NAME   "Display name for logs (press enter to take default)"   "$SLUG"
prompt CSE_CC        "CSE Command Center URL (press enter to take default)"  "https://net.banyanops.com"
prompt_secret CSE_KEY "CSE API Key Secret (hidden)"
prompt BLUM_URL      "Blumira ingestion service URL"
prompt_secret BLUM_TOKEN "Blumira token (JUST THE RAW TOKEN - after 'Blumira ' - hidden)"
prompt POLL_INT      "Poll interval seconds (press enter to take default)"   "60"

[ -n "$CSE_KEY" ]    || { err "CSE API key is required."; exit 1; }
[ -n "$BLUM_URL" ]   || { err "Blumira URL is required."; exit 1; }
[ -n "$BLUM_TOKEN" ] || { err "Blumira token is required."; exit 1; }

# ---- write the client config ----------------------------------------------
mkdir -p "$CLIENT_DIR"
PROJECT="cse-blumira-$SLUG"
VOLUME="${PROJECT}-state"

umask 077   # config.yaml created 0600; container runs as root so it can read it
cat > "$CLIENT_DIR/config.yaml" <<YAML
# Generated by install.sh for client: $SLUG
poll_interval_seconds: $POLL_INT
flatten: true
drop_debug: false

tenants:
  - name: "$TENANT_NAME"
    cse_command_center: "$CSE_CC"
    cse_api_key: "$CSE_KEY"
    blumira_url: "$BLUM_URL"
    blumira_token: "$BLUM_TOKEN"
YAML
umask 022

ok "Wrote config to $CLIENT_DIR/config.yaml"

# ---- run the container -----------------------------------------------------
if [ "$DO_START" = "1" ]; then
  say "Starting ${c_dim}${PROJECT}${c_rst} ..."
  docker rm -f "$PROJECT" >/dev/null 2>&1 || true
  docker run -d \
    --name "$PROJECT" \
    --restart unless-stopped \
    --user 0:0 \
    -v "$CLIENT_DIR/config.yaml:/config/config.yaml:ro" \
    -v "$VOLUME:/data" \
    -e RELAY_LOG_LEVEL=INFO \
    "$IMAGE" >/dev/null
  ok "Up. Tail logs with:  docker logs -f $PROJECT"
else
  say "Skipped start (--no-start). Start later with:"
  say "  docker run -d --name $PROJECT --restart unless-stopped --user 0:0 \\"
  say "    -v $CLIENT_DIR/config.yaml:/config/config.yaml:ro -v $VOLUME:/data $IMAGE"
fi

say ""
say "${c_bold}Manage:${c_rst}  logs: docker logs -f $PROJECT   |   restart after config edit: docker restart $PROJECT"
say "Re-run this installer for the next client (image is reused)."
