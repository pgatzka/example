#!/usr/bin/env bash
#
# Deploy a container image from GHCR with docker compose, wait on the Spring
# Boot Actuator health endpoint, and roll back to the previously running
# version on failure.
#
# Instead of checking out the whole repo, the compose file(s) are downloaded
# at the exact commit the image was built from (OCI revision label). This
# means the working tree is never touched, so this script is safe to run in
# place.
#
# Environment variables (defaults in brackets):
#   IMAGE                 required, e.g. ghcr.io/owner/repo
#   TAG                   [latest]
#   TRIGGER_SHA           fallback revision if the image carries no label
#   SERVICE               compose service to deploy/track [app]
#   COMPOSE_STACK_NAME  required
#   COMPOSE_FILE          required, colon-separated repo-relative paths
#   GITHUB_REPOSITORY     required, owner/repo (auto-set in Actions)
#   GH_TOKEN              token with contents:read (for private repos)
#   HOST_PORT             [8080]
#   ACTUATOR_PATH         [/actuator/health]
#   HEALTH_TIMEOUT        seconds [120]
#   HEALTH_INTERVAL       seconds [5]
set -euo pipefail

IMAGE="${IMAGE:?IMAGE is required (e.g. ghcr.io/owner/repo)}"
TAG="${TAG:-latest}"
TRIGGER_SHA="${TRIGGER_SHA:-}"
SERVICE="${SERVICE:-app}"
: "${COMPOSE_STACK_NAME:?COMPOSE_STACK_NAME is required}"; export COMPOSE_STACK_NAME
: "${COMPOSE_FILE:?COMPOSE_FILE is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required (owner/repo)}"
GH_TOKEN="${GH_TOKEN:-}"
HOST_PORT="${HOST_PORT}"
ACTUATOR_PATH="${ACTUATOR_PATH}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT}"
HEALTH_INTERVAL="${HEALTH_INTERVAL}"

# --- helpers ---------------------------------------------------------------
image_revision() {  # $1 = image ref/id -> git sha it was built from (or "")
  docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$1" 2>/dev/null || true
}

# Download the compose file(s) at a revision into a temp dir; echoes a
# colon-separated list of the local paths (to use as COMPOSE_FILE).
fetch_compose_files() {  # $1 = revision
  local sha="$1"
  local destdir="${RUNNER_TEMP:-/tmp}/compose-${sha}"
  rm -rf "$destdir"; mkdir -p "$destdir"
  local list=""
  IFS=':' read -ra files <<< "$COMPOSE_FILE"
  for f in "${files[@]}"; do
    local out="$destdir/$f"
    mkdir -p "$(dirname "$out")"
    echo "Fetching $f @ $sha" >&2
    curl -fsSL \
      ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
      -H "Accept: application/vnd.github.raw+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${f}?ref=${sha}" \
      -o "$out"
    list="${list:+$list:}$out"
  done
  echo "$list"
}

deploy() {  # $1 = image ref, $2 = revision for its compose files
  local files
  files="$(fetch_compose_files "$2")"
  APP_IMAGE="$1" COMPOSE_FILE="$files" docker compose up -d --remove-orphans
}

wait_healthy() {
  local url="http://localhost:${HOST_PORT}${ACTUATOR_PATH}"
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  echo "Waiting for health at $url (timeout ${HEALTH_TIMEOUT}s)..."
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "Actuator reports UP."; return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

# --- resolve NEW version ---------------------------------------------------
NEW_REF="${IMAGE}:${TAG}"
docker pull "$NEW_REF"

NEW_SHA="$(image_revision "$NEW_REF")"
if [ -z "$NEW_SHA" ]; then
  case "$TAG" in
    sha-*) NEW_SHA="${TAG#sha-}" ;;
    *)     NEW_SHA="$TRIGGER_SHA" ;;
  esac
fi
echo "New image $NEW_REF was built from revision: ${NEW_SHA:-<unknown>}"

# --- capture PREVIOUS version ---------------------------------------------
PREV_CID=$(docker ps -q \
  --filter "label=com.docker.compose.project=${COMPOSE_STACK_NAME}" \
  --filter "label=com.docker.compose.service=${SERVICE}" | head -n1)
PREV_IMAGE=""; PREV_SHA=""
if [ -n "$PREV_CID" ]; then
  PREV_IMAGE=$(docker inspect --format '{{.Image}}' "$PREV_CID")
  PREV_SHA=$(image_revision "$PREV_IMAGE")
  echo "Previous image: $PREV_IMAGE (revision ${PREV_SHA:-<unknown>})"
else
  echo "No running '$SERVICE' — first deploy, nothing to roll back to."
fi

# --- deploy NEW ------------------------------------------------------------
echo "::group::Deploying $NEW_REF"
deploy "$NEW_REF" "$NEW_SHA"
echo "::endgroup::"

if wait_healthy; then
  echo "✅ Deployment of $NEW_REF succeeded and is healthy."
  exit 0
fi
echo "❌ New version failed its health check."

# --- roll back to PREVIOUS -------------------------------------------------
if [ -z "$PREV_IMAGE" ]; then
  echo "::error::No previous version to roll back to. Leaving failed stack for inspection."
  docker compose logs --tail 100 "$SERVICE" 2>/dev/null || true
  exit 1
fi

echo "::group::Rolling back to $PREV_IMAGE"
deploy "$PREV_IMAGE" "$PREV_SHA"
echo "::endgroup::"

if wait_healthy; then
  echo "::error::Deploy failed; rolled back to previous version ($PREV_IMAGE)."
  exit 1
else
  echo "::error::Deploy failed AND rollback failed — environment may be down!"
  docker compose logs --tail 100 "$SERVICE" 2>/dev/null || true
  exit 1
fi