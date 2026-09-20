#!/usr/bin/env bash
#
# Download MediaFire folders/files via mediafire_rs running in Docker
# on the homelab. Nothing runs locally on the Mac except the Docker CLI,
# and files NEVER land on the server — they stream straight back to this
# Mac via `docker cp` (container filesystem only, removed afterwards).
#
#   1. Fill in FOLDER_NAME and URLS below.
#   2. Run: ./download.sh
#   3. Files appear in ~/Downloads/<FOLDER_NAME> on this Mac.
#
# Requires: docker CLI with context/host pointing at the homelab, e.g.
#   docker context use homelab   # ssh://franp@192.168.1.10
# or
#   export DOCKER_HOST=ssh://franp@192.168.1.10

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — SET THESE BEFORE RUNNING
# ---------------------------------------------------------------------------

# Destination folder name inside ~/Downloads on THIS MAC.
FOLDER_NAME="drawn together"

# MediaFire folder/file URLs to download.
URLS=(
  "https://www.mediafire.com/folder/tefje4xp55j18/LCDLD+T1",
  "https://www.mediafire.com/folder/82axxhsso9js8/LCDLD+T2",
  "https://www.mediafire.com/folder/kvlz1xf3ywspz/LCDLD+T3"
)

# ---------------------------------------------------------------------------
# OPTIONAL SETTINGS (sane defaults, change if needed)
# ---------------------------------------------------------------------------
IMAGE_NAME="mediafire-rs:latest"
MAX_CONCURRENT=10                  # mdrs -m flag
TRIES=1                            # mdrs -t flag
MAC_DIR="$HOME/Downloads"          # local destination base on this Mac

# ---------------------------------------------------------------------------
# No config below this line
# ---------------------------------------------------------------------------

log()  { printf '[mediafire-dl] %s\n' "$*"; }
fail() { printf '[mediafire-dl] ERROR: %s\n' "$*" >&2; exit 1; }

# --- validation -------------------------------------------------------------
[[ -n "${FOLDER_NAME}" ]] || fail 'FOLDER_NAME is empty. Set it, e.g. FOLDER_NAME="my-collection".'

# Drop empty-string placeholders so a half-filled array fails loudly instead
# of passing "" to mdrs.
FILTERED_URLS=()
for u in "${URLS[@]:-}"; do
  [[ -n "${u}" ]] && FILTERED_URLS+=("${u}")
done
((${#FILTERED_URLS[@]} > 0)) || fail 'URLS has no entries. Add at least one MediaFire folder/file URL.'

command -v docker >/dev/null 2>&1 || fail 'docker CLI not found. Install only the client: brew install docker'
docker info >/dev/null 2>&1 || fail 'cannot reach Docker daemon. Run: docker context use homelab  (or export DOCKER_HOST=ssh://franp@192.168.1.10)'

LOCAL_DEST="${MAC_DIR%/}/${FOLDER_NAME}"

log "local destination: ${LOCAL_DEST}"
log "urls: ${#FILTERED_URLS[@]} | max-concurrent=${MAX_CONCURRENT} tries=${TRIES}"

# --- ensure image exists on the remote daemon (built remotely, not on Mac) --
if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  log "image ${IMAGE_NAME} not found on remote daemon — building (runs on homelab)..."
  docker build -t "${IMAGE_NAME}" "$(cd "$(dirname "$0")" && pwd)"
else
  log "image ${IMAGE_NAME} present on remote daemon."
fi

mkdir -p "${LOCAL_DEST}"

# --- download into container filesystem (NO bind mount, nothing on host) ----
# -t allocates a pseudo-TTY so mdrs progress bars render and stream live
# through `docker start -a`. Fixed --name makes orphans easy to find/kill
# after a disconnect: docker rm -f mediafire-dl-tmp
docker rm -f mediafire-dl-tmp >/dev/null 2>&1 || true
CID="$(docker create -t --name mediafire-dl-tmp "${IMAGE_NAME}" \
  -o /downloads -m "${MAX_CONCURRENT}" -t "${TRIES}" \
  "${FILTERED_URLS[@]}")"
trap 'docker rm -f "${CID}" >/dev/null 2>&1 || true' EXIT

log "downloading inside remote container ${CID}... (Ctrl-C kills + cleans up)"
docker start -a "${CID}"

# --- move files back to this Mac (container removed after = move, not copy) --
log "moving to Mac: ${LOCAL_DEST}"
docker cp "${CID}:/downloads/." "${LOCAL_DEST}/"

trap - EXIT
docker rm -f "${CID}" >/dev/null 2>&1 || true

log "done. Files moved to ${LOCAL_DEST} (container removed, nothing left on server)"
