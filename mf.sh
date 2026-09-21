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
# Downloads land in the job's own HDD buffer subdir on the VM
# (/mnt/mediafire/<slug>/, an NFS mount from the Proxmox host — never the
# VM's own disk), so concurrent jobs can't mix files. Fetch streams them to
# this Mac via `docker cp`, then removes the subdir.
#
# Requires: docker CLI with context/host pointing at the homelab, e.g.
#   docker context use homelab   # ssh://franp@192.168.1.10

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — SET THESE BEFORE RUNNING
# ---------------------------------------------------------------------------

# Destination folder name inside ~/Downloads on THIS MAC.
FOLDER_NAME="dbz-2"

# MediaFire folder/file URLs to download.
URLS=(
    "https://www.mediafire.com/folder/xzh01qkcfoews/OVAs_de_Dragon_Ball_Z",
    "https://www.mediafire.com/folder/2x1r8vm7ebsc7/Películas_de_Dragon_Ball_Z",
    "https://www.mediafire.com/folder/zw3kxyy5get8p/Especiales_de_Dragon_Ball_Z"
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

# `docker rm` does NOT clean bind contents — remove the job's own subdir only
# (slug is sanitized to [a-z0-9-]; buffer root + sentinel stay untouched).
cleanup_job_dir() {
  local slug="$1"
  [[ -n "${slug}" ]] || return 0
  docker run --rm --entrypoint sh -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -c "rm -rf /buffer/${slug}" >/dev/null 2>&1 || true
}

# In-container download dir for a job: its own /buffer/<slug>.
# Falls back to /downloads for jobs started before per-folder subdirs.
job_path() {
  local slug
  slug="$(sanitize "$(job_folder "$1")")"
  if [[ -n "${slug}" ]] && docker run --rm --entrypoint test -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -d "/buffer/${slug}" >/dev/null 2>&1; then
    printf '/buffer/%s' "${slug}"
  else
    printf '/downloads'
  fi
}

cmd_start() {
  need_config
  need_docker
  ensure_image
  need_buffer
  local job slug urls
  job="$(job_name)"
  slug="$(sanitize "${FOLDER_NAME}")"
  [[ -n "${slug}" ]] || fail "FOLDER_NAME sanitizes to empty (use letters/digits)."
  if docker inspect "${job}" >/dev/null 2>&1; then
    fail "job ${job} already exists. ./mf.sh status | ./mf.sh logs | ./mf.sh fetch | ./mf.sh kill"
  fi
  mapfile -t urls < <(filtered_urls)
  log "starting detached job ${job} (${#urls[@]} urls) — safe to sleep/close this Mac."
  log "more jobs? Set another FOLDER_NAME + URLS and start again — each gets its own buffer subdir."
  docker create -t --name "${job}" \
    --label "${JOB_LABEL}" \
    --label "mediafire-dl.folder=${FOLDER_NAME}" \
    -v "${REMOTE_BUFFER}:/buffer" \
    --entrypoint sh "${IMAGE_NAME}" \
    -c "mkdir -p /buffer/${slug} && exec mdrs -o /buffer/${slug} -m ${MAX_CONCURRENT} -t ${TRIES} ${urls[*]}" >/dev/null
  docker start "${job}" >/dev/null
  log "running. Watch: ./mf.sh logs ${job} | Fetch later: ./mf.sh fetch ${job}"
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
  fetch_one "${job}" "${force}"
}

# Fetch a single resolved job container. Returns nonzero (no exit) when the
# job is still running and force is off, so fetch-all can skip and continue.
fetch_one() {
  local job="$1" force="$2" folder dest running srcdir slug
  running="$(docker inspect --format '{{.State.Running}}' "${job}")"
  if [[ "${running}" == "true" && "${force}" != "true" ]]; then
    printf '[mf] ERROR: job %s is still running. Wait + ./mf.sh logs, or ./mf.sh fetch %s --force for a partial move (kills the job).\n' "${job}" "${job}" >&2
    return 1
  fi
  folder="$(job_folder "${job}")"
  [[ -n "${folder}" ]] || { printf '[mf] ERROR: job %s has no folder label; refusing to guess the destination.\n' "${job}" >&2; return 1; }
  dest="${MAC_DIR%/}/${folder}"
  mkdir -p "${dest}" 2>/dev/null || { printf '[mf] ERROR: cannot create %s.\n' "${dest}" >&2; return 1; }
  if ! touch "${dest}/.mediafire-dl-write-test" 2>/dev/null; then
    printf '[mf] ERROR: LOCAL dest not writable: %s (external NTFS drives are read-only on macOS)\n' "${dest}" >&2
    return 1
  fi
  rm -f "${dest}/.mediafire-dl-write-test"
  srcdir="$(job_path "${job}")"
  slug="$(sanitize "${folder}")"
  log "moving ${job} (${srcdir}) -> ${dest}"
  docker cp "${job}:${srcdir}/." "${dest}/" || return 1
  # Sentinel can only arrive via the legacy /downloads fallback — keep it off the Mac.
  rm -f "${dest}/.mediafire-buffer"
  # Remove this job's subdir only; legacy fallback cleans nothing (shared root).
  if [[ "${srcdir}" == /buffer/* ]]; then
    cleanup_job_dir "${slug}"
  fi
  docker rm -f "${job}" >/dev/null 2>&1 || true
  log "done. ${folder} moved to ${dest} (job removed)"
}

cmd_fetch_all() {
  need_docker
  local job ok=0 skipped=0 failed=0
  while IFS= read -r job; do
    [[ -n "${job}" ]] || continue
    if [[ "$(docker inspect --format '{{.State.Running}}' "${job}")" == "true" ]]; then
      log "skipping ${job} (still running)"
      skipped=$((skipped + 1))
    elif fetch_one "${job}" "false"; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(docker ps -a --filter "label=${JOB_LABEL}" --format '{{.Names}}')
  log "fetch-all: ${ok} moved, ${skipped} skipped (running), ${failed} failed."
}

cmd_kill() {
  need_docker
  local job srcdir slug
  job="$(resolve_job "${1:-}")"
  srcdir="$(job_path "${job}")"
  slug="$(sanitize "$(job_folder "${job}")")"
  docker rm -f "${job}" >/dev/null
  if [[ "${srcdir}" == /buffer/* ]]; then
    cleanup_job_dir "${slug}"
  fi
  log "killed + removed ${job} (partial files discarded)"
}

cmd_retry() {
  need_docker
  local job folder slug failed n
  job="$(resolve_job "${1:-}")"
  if [[ "$(docker inspect --format '{{.State.Running}}' "${job}")" == "true" ]]; then
    fail "job ${job} is still running. Wait for it to finish (or kill it) before retrying."
  fi
  folder="$(job_folder "${job}")"
  [[ -n "${folder}" ]] || fail "job ${job} has no folder label; refusing to guess."
  slug="$(sanitize "${folder}")"
  [[ -n "${slug}" ]] || fail "folder sanitizes to empty."
  # mdrs ends its log with a "Failed downloads:" section; each line ends
  # with the file URL. Re-run exactly those (transient ApiError/NetworkError
  # failures deserve a second chance with -t/--tries). 
  failed="$(docker logs "${job}" 2>&1 | tr -d '\r' | sed -n '/^Failed downloads:$/,$p' | grep -o 'https\?://[^[:space:]]*$' | sort -u)"
  [[ -n "${failed}" ]] || fail "no failed URLs parsed from ${job} logs — nothing to retry (or mdrs changed its output format)."
  n="$(printf '%s\n' "${failed}" | grep -c .)"
  log "retrying ${n} failed file(s) from ${job} into the same subdir..."
  docker rm -f "${job}" >/dev/null
  ensure_image
  need_buffer
  # Legacy jobs (pre-subdir layout) kept files at the buffer root: migrate
  # leftovers into this job's subdir so fetch grabs everything together.
  if ! docker run --rm --entrypoint test -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -d "/buffer/${slug}" >/dev/null 2>&1; then
    docker run --rm --entrypoint sh -v "${REMOTE_BUFFER}:/buffer" "${IMAGE_NAME}" -c "mkdir -p /buffer/${slug} && find /buffer -maxdepth 1 -type f ! -name '.mediafire-buffer' -exec mv -t /buffer/${slug}/ {} +" >/dev/null 2>&1 || true
    log "migrated buffer-root leftovers into ${slug}/"
  fi
  local urls
  mapfile -t urls <<< "${failed}"
  docker create -t --name "${job}" \
    --label "${JOB_LABEL}" \
    --label "mediafire-dl.folder=${folder}" \
    -v "${REMOTE_BUFFER}:/buffer" \
    --entrypoint sh "${IMAGE_NAME}" \
    -c "mkdir -p /buffer/${slug} && exec mdrs -o /buffer/${slug} -m ${MAX_CONCURRENT} -t ${TRIES} ${urls[*]}" >/dev/null
  docker start "${job}" >/dev/null
  log "retry running as ${job}. Watch: ./mf.sh logs ${job} | Fetch later: ./mf.sh fetch ${job}"
}

usage() {
  cat <<'EOF'
Usage: ./mf.sh <command> [job] [--force]

  start          start detached download (Mac can sleep afterwards)
  status         list jobs (running / exited)
  logs [job]     stream progress (Ctrl-C detaches, download continues)
  fetch [job]    move finished files to ~/Downloads/<folder>, remove job
  fetch [job] --force   move partial files now (kills a running job)
  fetch-all        move ALL finished jobs (skips running ones)
  retry [job]    re-run only the failed files of a finished job (same subdir)
  kill [job]     abort + remove job (partial files discarded)

job = container name/id or the FOLDER_NAME. Defaults to FOLDER_NAME in CONFIG.
EOF
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  logs)   shift; cmd_logs "$@" ;;
  fetch)  shift; cmd_fetch "$@" ;;
  fetch-all) shift; cmd_fetch_all "$@" ;;
  retry)  shift; cmd_retry "$@" ;;
  kill)   shift; cmd_kill "$@" ;;
  *) usage; exit 1 ;;
esac
