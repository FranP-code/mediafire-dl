# mediafire-dl

Batch-download MediaFire folders/files with [`mediafire_rs`](https://github.com/nickoehler/mediafire_rs) (`mdrs`) running in Docker **on the homelab**. Nothing heavy runs on the Mac — only the Docker client CLI, talking to the remote daemon over SSH. Files download into an **HDD-backed buffer** bind-mounted into the container (never the VM's own disk), stream back to this Mac via `docker cp`, and the buffer is emptied afterwards.

## How it works

- `Dockerfile` builds `mdrs` from git main via a multi-stage build (`rust:1-bookworm` → `debian:bookworm-slim`). The image is built **on the homelab daemon**, never locally.
- `download.sh` downloads inside one remote container into its own buffer subdir (`/mnt/mediafire/<folder-slug>` in the VM → `/buffer/<folder-slug>` in the container), then `docker cp`s the result to `~/Downloads/<FOLDER_NAME>` on this Mac, removes the subdir, and removes the container. The job name derives from the folder: `FOLDER_NAME="Estoy En La Banda"` → `mediafire-dl-estoy-en-la-banda`.
- Remote daemon: `192.168.1.10` (Docker VM) via `ssh://franp@192.168.1.10`.

## Buffer (HDD, not VM disk)

- Host dir: `/mnt/pve/HDD/mediafire` (dedicated single-purpose dir — the whole HDD is deliberately NOT exposed). Exported via NFS scoped to the Docker VM only:
  `/mnt/pve/HDD/mediafire 192.168.1.10(rw,sync,no_subtree_check,no_root_squash)` (`no_root_squash` is safe here: single dir, single client IP; the container runs as root).
- VM mount (`/etc/fstab`): `192.168.1.11:/mnt/pve/HDD/mediafire /mnt/mediafire nfs defaults,_netdev 0 0` (needs `nfs-common` in the VM).
- A sentinel file `.mediafire-buffer` lives in the buffer dir. The script verifies it inside the container before downloading — if the NFS mount ever drops, it fails loudly instead of silently downloading onto the VM disk (Docker auto-creates missing bind sources).
- After a successful run the job's subdir is removed (sentinel stays). After Ctrl-C, partials stay in the job's subdir — next run with the same folder overwrites same-named files; empty manually if needed.
- Concurrent jobs are isolated: each uses its own `<folder-slug>` subdir. Start another by setting a different `FOLDER_NAME` + `URLS` and running again.

## Prerequisites (Mac)

Client only — no Docker Desktop, Colima, or OrbStack:

```bash
brew install docker
docker context create homelab --docker "host=ssh://franp@192.168.1.10"
docker context use homelab
docker ps   # runs on .10
```

## Usage

1. Edit `download.sh` and set the two required values:

```bash
FOLDER_NAME="my-collection"
URLS=(
  "https://www.mediafire.com/folder/xxxx/first"
  "https://www.mediafire.com/folder/yyyy/second"
)
```

2. Run:

```bash
./download.sh
# → ~/Downloads/my-collection/ on this Mac, nothing left on the server
```

Optional knobs in `download.sh`: `MAX_CONCURRENT` (`-m`, default 10), `TRIES` (`-t`, default 1), `IMAGE_NAME`, `MAC_DIR` (default `$HOME/Downloads`).

## Detached mode (`mf.sh`) — Mac can sleep

Same buffer design, but the download runs detached: start it, close the Mac, fetch later.

```bash
./mf.sh start          # needs FOLDER_NAME + URLS set in mf.sh; Mac can sleep after this
./mf.sh status         # list jobs (running / exited)
./mf.sh logs           # stream progress (Ctrl-C detaches, download continues)
./mf.sh fetch          # move finished files to ~/Downloads/<folder>, remove job subdir, remove job
./mf.sh fetch --force  # move partial files now (kills a running job)
./mf.sh fetch-all      # move ALL finished jobs (skips running ones)
./mf.sh retry          # re-run only the failed files of a finished job (same subdir)
./mf.sh kill           # abort + remove job, remove its subdir
```

`retry` parses `mdrs`' trailing `Failed downloads:` section from the job's logs and starts a fresh container with just those URLs — existing files in the subdir stay put. (Transient `ApiError: NetworkError` failures like the odd part-file are exactly what it's for; raise `TRIES` if they keep recurring.)

Notes:

- Run several jobs at once: each `FOLDER_NAME` gets its own job (`mediafire-dl-<slug>`) and its own buffer subdir — they can't mix. `status` lists them all.
- `fetch` refuses while the job is still running unless `--force`.
- If the Mac disconnects mid-download, the job keeps running; reattach with `./mf.sh logs`, finish with `./mf.sh fetch`. Orphan cleanup: `./mf.sh kill`.

## Why remote?

Local container runtimes on Apple Silicon (Colima / Docker Desktop / OrbStack) all run a Linux VM on the Mac. This setup skips that entirely: the Mac only sends API calls over SSH, all pulls/builds/downloads happen on the homelab's `linux/amd64` engine, and `docker cp` streams the bytes back — no server-side staging directory.
