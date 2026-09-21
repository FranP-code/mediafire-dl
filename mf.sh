#!/usr/bin/env bash
#
# mf.sh — detached MediaFire downloads on the homelab.
#
# The Mac is only needed to START the job and later FETCH the files.
# In between you can close the lid, sleep, disconnect — the download
# keeps running inside a remote container on 192.168.1.10.
#
#   1. Fill in FOLDER_NAME and URLS below.
#   2. ./mf.sh start          # Mac can go to sleep after this
#   3. ./mf.sh status         # from anywhere, anytime
#   4. ./mf.sh logs           # stream mdrs progress (reattach anytime)
#   5. ./mf.sh fetch          # move files to ~/Downloads/<FOLDER_NAME>, container removed
#
# Other commands: ./mf.sh kill   (abort + clean up)
#
# Downloads land in the HDD-backed buffer on the VM (/mnt/mediafire, an NFS
# mount from the Proxmox host — never the VM's own disk), and fetch streams
# them to this Mac via `docker cp`, then empties the buffer.
#
# Requires: docker CLI with context/host pointing at the homelab, e.g.
#   docker context use homelab   # ssh://franp@192.168.1.10

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — SET THESE BEFORE RUNNING
# ---------------------------------------------------------------------------

# Destination folder name inside ~/Downloads on THIS MAC.
FOLDER_NAME=""

# MediaFire folder/file URLs to download.
URLS=(
  ""
)

# ---------------------------------------------------------------------------
# OPTIONAL SETTINGS (sane defaults, change if needed)
# ---------------------------------------------------------------------------
IMAGE_NAME="mediafire-rs:latest"
MAX_CONCURRENT=10                  # mdrs -m flag
TRIES=1                            # mdrs -t flag
MAC_DIR="$HOME/Downloads"          # local destination base on this Mac
# Buffer dir INSIDE the Docker VM (HDD-backed NFS mount, not the VM disk).
# Host path: 192.168.1.11:/mnt/pve/HDD/mediafire. Shared by all jobs —
# only one job at a time (enforced in cmd_start).
REMOTE_BUFFER="/mnt/mediafire"

# ---------------------------------------------------------------------------
# No config below this line
# ---------------------------------------------------------------------------

JOB_LABEL="mediafire-dl.job=1"

log()  { printf '[mf] %s\n' "$*"; }
fail() { printf '[mf] ERROR: %s\n' "$*" >&2; exit 1; }

sanitize() {
  # "Drawn Together!" -> "drawn-together"
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/^-\{1,\}//' -e 's/-\{1,\}$//' | cut -c1-60
}

job_name() { printf 'mediafire-dl-%s' "$(sanitize "${FOLDER_NAME}")"; }

need_docker() {
  command -v docker >/dev/null 2>&1 || fail 'docker CLI not found. Install only the client: brew install docker'
  docker info >/dev/null 2>&1 || fail 'cannot reach Docker daemon. Run: docker context use homelab  (or export DOCKER_HOST=ssh://franp@192.168.1.10)'
}

need_config() {
  [[ -n "${FOLDER_NAME}" ]] || fail 'FOLDER_NAME is empty. Set it, e.g. FOLDER_NAME="my-collection".'
  local n=0 u
  for u in "${URLS[@]:-}"; do [[ -n "${u}" ]] && n=$((n + 1)); done
  ((n > 0)) || fail 'URLS has no entries. Add at least one MediaFire folder/file URL.'
}

filtered_urls() {
  local u
  for u in "${URLS[@]:-}"; do [[ -n "${u}" ]] && printf '%s\n' "${u}"; done
}

# Resolve a job reference (container name/id or folder name) to a container.
resolve_job() {
  local ref="${1:-}"
  if [[ -z "${ref}" ]]; then
    [[ -n "${FOLDER_NAME}" ]] || fail 'no job given and FOLDER_NAME is empty. Usage: ./mf.sh logs|fetch|kill <job|folder>'
    ref="$(job_name)"
  fi
  if docker inspect "${ref}" >/dev/null 2>&1; then
    printf '%s' "${ref}"
  elif docker inspect "mediafire-dl-$(sanitize "${ref}")" >/dev/null 2>&1; then
    printf 'mediafire-dl-%s' "$(sanitize "${ref}")"
  else
    fail "no such job: ${ref}. See: ./mf.sh status"
  fi
}

job_folder() {
  docker inspect --format '{{ index .Config.Labels "mediafire-dl.folder" }}' "$1" 2>/dev/null
}

ensure_image() {
  if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    log "image ${IMAGE_NAME} not found on remote daemon — building (runs on homelab)..."
    docker build -t "${IMAGE_NAME}" "$(cd "$(dirname "$0")" && pwd)"
  else
    log "image ${IMAGE_NAME} present on remote daemon."
  fi
}

# Guard: without the NFS mount, Docker would auto-create a plain dir on the
# VM disk and download there. The sentinel proves the real buffer is mounted.
need_buffer() {
  docker run --rm --entrypoint test -v "${REMOTE_BUFFER}:/downloads" "${IMAGE_NAME}" -f /downloads/.mediafire-buffer >/dev/null 2>&1 \
    || fail "HDD buffer not mounted on remote daemon (${REMOTE_BUFFER}). Mount it: 192.168.1.11:/mnt/pve/HDD/mediafire"
}

# `docker rm` does NOT clean bind contents — empty the buffer explicitly
# (.[!.]* covers dotfiles but can never match . or ..; the sentinel is
# deleted by the globs and recreated right after).
empty_buffer() {
  docker run --rm --entrypoint sh -v "${REMOTE_BUFFER}:/downloads" "${IMAGE_NAME}" -c 'rm -rf /downloads/* /downloads/.[!.]*; touch /downloads/.mediafire-buffer' >/dev/null 2>&1 || true
}

cmd_start() {
  need_config
  need_docker
  ensure_image
  need_buffer
  local job urls
  job="$(job_name)"
  if docker inspect "${job}" >/dev/null 2>&1; then
    fail "job ${job} already exists. ./mf.sh status | ./mf.sh logs | ./mf.sh fetch | ./mf.sh kill"
  fi
  # The buffer is shared: refuse a second job so downloads can't mix.
  if docker ps -a --filter "label=${JOB_LABEL}" --format '{{.Names}}' | grep -q .; then
    fail "another job exists (shared buffer). ./mf.sh status, then fetch/kill it first."
  fi
  mapfile -t urls < <(filtered_urls)
  log "starting detached job ${job} (${#urls[@]} urls) — safe to sleep/close this Mac."
  docker create -t --name "${job}" \
    --label "${JOB_LABEL}" \
    --label "mediafire-dl.folder=${FOLDER_NAME}" \
    -v "${REMOTE_BUFFER}:/downloads" \
    "${IMAGE_NAME}" \
    -o /downloads -m "${MAX_CONCURRENT}" -t "${TRIES}" \
    "${urls[@]}" >/dev/null
  docker start "${job}" >/dev/null
  log "running. Watch: ./mf.sh logs | Fetch later: ./mf.sh fetch"
}

cmd_status() {
  need_docker
  local out
  out="$(docker ps -a --filter "label=${JOB_LABEL}" --format 'table {{.Names}}\t{{.Status}}\t{{.Label "mediafire-dl.folder"}}')"
  if [[ "$(printf '%s\n' "${out}" | wc -l)" -le 1 ]]; then
    log "no jobs."
  else
    printf '%s\n' "${out}"
  fi
}

cmd_logs() {
  need_docker
  local job
  job="$(resolve_job "${1:-}")"
  log "streaming logs for ${job} (Ctrl-C detaches, download keeps running)..."
  docker logs -f --tail 50 "${job}"
}

cmd_fetch() {
  need_docker
  local job="${1:-}" force="false" folder dest running
  [[ "${2:-}" == "--force" || "${1:-}" == "--force" ]] && force="true"
  [[ "${1:-}" == "--force" ]] && job=""
  job="$(resolve_job "${job}")"
  running="$(docker inspect --format '{{.State.Running}}' "${job}")"
  if [[ "${running}" == "true" && "${force}" != "true" ]]; then
    fail "job ${job} is still running. Wait + ./mf.sh logs, or ./mf.sh fetch ${job} --force for a partial move (kills the job)."
  fi
  folder="$(job_folder "${job}")"
  [[ -n "${folder}" ]] || fail "job ${job} has no folder label; refusing to guess the destination."
  dest="${MAC_DIR%/}/${folder}"
  mkdir -p "${dest}" 2>/dev/null || fail "cannot create ${dest}."
  if ! touch "${dest}/.mediafire-dl-write-test" 2>/dev/null; then
    fail "LOCAL dest not writable: ${dest} (external NTFS drives are read-only on macOS)"
  fi
  rm -f "${dest}/.mediafire-dl-write-test"
  log "moving ${job} -> ${dest}"
  docker cp "${job}:/downloads/." "${dest}/"
  # Exclude the sentinel from the move aftermath: empty the whole buffer.
  # (cp already skipped nothing — sentinel would otherwise land on the Mac.)
  rm -f "${dest}/.mediafire-buffer"
  empty_buffer
  docker rm -f "${job}" >/dev/null 2>&1 || true
  log "done. Files moved to ${dest} (job removed, buffer emptied)"
}

cmd_kill() {
  need_docker
  local job
  job="$(resolve_job "${1:-}")"
  docker rm -f "${job}" >/dev/null
  empty_buffer
  log "killed + removed ${job} (partial files discarded, buffer emptied)"
}

usage() {
  cat <<'EOF'
Usage: ./mf.sh <command> [job] [--force]

  start          start detached download (Mac can sleep afterwards)
  status         list jobs (running / exited)
  logs [job]     stream progress (Ctrl-C detaches, download continues)
  fetch [job]    move finished files to ~/Downloads/<folder>, remove job
  fetch [job] --force   move partial files now (kills a running job)
  kill [job]     abort + remove job (partial files discarded)

job = container name/id or the FOLDER_NAME. Defaults to FOLDER_NAME in CONFIG.
EOF
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  logs)   shift; cmd_logs "$@" ;;
  fetch)  shift; cmd_fetch "$@" ;;
  kill)   shift; cmd_kill "$@" ;;
  *) usage; exit 1 ;;
esac
