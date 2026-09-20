FROM rust:1-bookworm AS builder

# Build from git main: crates.io 0.1.3 is old (single URL, no -m/-t flags).
# Main supports <URLS>..., -m/--max, -t/--tries, -r/--reverse, -p/--proxy.
RUN cargo install --git https://github.com/nickoehler/mediafire_rs --locked

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/cargo/bin/mdrs /usr/local/bin/mdrs

WORKDIR /downloads
ENTRYPOINT ["mdrs"]
CMD ["--help"]
