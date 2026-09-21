#!/usr/bin/env bash
#
# Download MediaFire folders/files via mediafire_rs running in Docker
# on the homelab. Nothing runs locally on the Mac except the Docker CLI.
# Files download into an HDD-backed buffer bind-mounted into the container
# (NOT the container filesystem on the VM disk), then stream back to this
# Mac via `docker cp`, and the buffer is emptied afterwards.
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
FOLDER_NAME="estoy en la banda"

# MediaFire folder/file URLs to download.
URLS=(
  "https://www.mediafire.com/folder/25r9ml0iza4br/Estoy+En+La+Banda"
)

# ---------------------------------------------------------------------------
# OPTIONAL SETTINGS (sane defaults, change if needed)
# ---------------------------------------------------------------------------
IMAGE_NAME="mediafire-rs:latest"
MAX_CONCURRENT=10                  # mdrs -m flag
TRIES=1                            # mdrs -t flag
MAC_DIR="$HOME/Downloads"          # local destination base on this Mac
# Buffer dir INSIDE the Docker VM (HDD-backed NFS mount, not the VM disk).
# Host path: 192.168.1.11:/mnt/pve/HDD/mediafire (dedicated export, .10 only).
REMOTE_BUFFER="/mnt/mediafire"

# ---------------------------------------------------------------------------
# No config below this line
# ---------------------------------------------------------------------------

log()  { printf '[mediafire-dl] %s\n' "$*"; }
fail() { printf '[mediafire-dl] ERROR: %s\n' "$*" >&2; exit 1; }

sanitize() {
  # "Estoy En La Banda!" -> "estoy-en-la-banda" (safe for container/paths)
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/^-\{1,\}//' -e 's/-\{1,\}$//' | cut -c1-60
}

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

mkdir -p "${LOCAL_DEST}" 2>/dev/null || fail "cannot create ${LOCAL_DEST}."

# Fail fast: verify writability BEFORE the (possibly long) remote download.
# NTFS volumes mount read-only on stock macOS — use an internal/APFS/exFAT
# path for MAC_DIR, or reformat/install an NTFS driver out of band.
if ! touch "${LOCAL_DEST}/.mediafire-dl-write-test" 2>/dev/null; then
  fail "LOCAL_DEST not writable: ${LOCAL_DEST} (external NTFS drives are read-only on macOS; set MAC_DIR to a writable path)"
fi
rm -f "${LOCAL_DEST}/.mediafire-dl-write-test"

# --- download into the job's own HDD buffer subdir (never the VM disk) ----
# Layout: <buffer>/<slug>/ per job, so concurrent jobs can't mix files.
# The job/container name derives from the destination folder:
#   FOLDER_NAME="Estoy En La Banda" -> mediafire-dl-estoy-en-la-banda
# Guard first: without the NFS mount, Docker would auto-create a plain dir
# on the VM disk and download there. The sentinel proves the real buffer.
# -t allocates a pseudo-TTY so mdrs progress bars render and stream live
# through `docker start -a`.
SLUG="$(sanitize "${FOLDER_NAME}")"
[[ -n "${SLUG}" ]] || fail "FOLDER_NAME sanitizes to empty (use letters/digits)."
JOB="mediafire-dl-${SLUG}"
docker run --rm --entrypoint test -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -f /buffer/.mediafire-buffer \
  || fail "HDD buffer not mounted on remote daemon (${REMOTE_BUFFER}). Mount it: 192.168.1.11:/mnt/pve/HDD/mediafire"
docker rm -f "${JOB}" >/dev/null 2>&1 || true
CID="$(docker create -t --name "${JOB}" -v "${REMOTE_BUFFER}:/buffer" --entrypoint sh "${IMAGE_NAME}" \
  -c "mkdir -p /buffer/${SLUG} && exec mdrs -o /buffer/${SLUG} -m ${MAX_CONCURRENT} -t ${TRIES} ${FILTERED_URLS[*]}")"
trap 'docker rm -f "${CID}" >/dev/null 2>&1 || true' EXIT

log "downloading inside remote container ${JOB} (${CID})... (Ctrl-C kills + cleans up)"
docker start -a "${CID}"

# --- move files back to this Mac, then remove the job's buffer subdir -----
# Safest re-fetch: wipe dest copies of source files first, so an interrupted
# earlier run can never leave mixed stale + fresh files. The buffer subdir
# is only removed AFTER a successful cp, so this is always safe.
docker run --rm --entrypoint sh -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -c "cd '/buffer/${SLUG}' && find . -type f" 2>/dev/null | while IFS= read -r f; do
  [[ -n "${f}" ]] || continue
  [[ -e "${LOCAL_DEST}/${f}" ]] && rm -f "${LOCAL_DEST}/${f}" || true
done
find "${LOCAL_DEST}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
log "moving to Mac: ${LOCAL_DEST}"
docker cp "${CID}:/buffer/${SLUG}/." "${LOCAL_DEST}/"

trap - EXIT
# `docker rm` does NOT clean bind contents — remove this job's subdir only
# (SLUG is sanitized to [a-z0-9-], root + sentinel stay untouched).
docker run --rm --entrypoint sh -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -c "rm -rf /buffer/${SLUG}" || true
docker rm -f "${CID}" >/dev/null 2>&1 || true

log "done. ${FOLDER_NAME} moved to ${LOCAL_DEST} (job ${JOB} removed, its buffer subdir cleaned)"
