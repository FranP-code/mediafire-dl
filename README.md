# mediafire-dl

Batch-download MediaFire folders/files with [`mediafire_rs`](https://github.com/nickoehler/mediafire_rs) (`mdrs`) running in Docker **on the homelab**. Nothing heavy runs on the Mac — only the Docker client CLI, talking to the remote daemon over SSH. Files **never land on the server**: they download into the container's filesystem and stream straight back to this Mac via `docker cp`.

## How it works

- `Dockerfile` builds `mdrs` from git main via a multi-stage build (`rust:1-bookworm` → `debian:bookworm-slim`). The image is built **on the homelab daemon**, never locally.
- `download.sh` loops over your `URLS` array, downloads inside one remote container (**no bind mount**, so no host files), then `docker cp`s the result to `~/Downloads/<FOLDER_NAME>` on this Mac and removes the container.
- Remote daemon: `192.168.1.10` (Docker VM) via `ssh://franp@192.168.1.10`.

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

## Why remote?

Local container runtimes on Apple Silicon (Colima / Docker Desktop / OrbStack) all run a Linux VM on the Mac. This setup skips that entirely: the Mac only sends API calls over SSH, all pulls/builds/downloads happen on the homelab's `linux/amd64` engine, and `docker cp` streams the bytes back — no server-side staging directory.
