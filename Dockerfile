# What a deployment runs: one image carrying both workspace binaries — `api`
# (the server) and `migrate` (run as a one-shot container before each rollout).
# Built for linux/arm64 because the target box is a Graviton instance; an Apple
# Silicon Mac builds that natively, no emulation involved.

FROM rust:1.96-slim-bookworm AS build

# protoc: build.rs runs prost-build, which needs the binary from the
# environment — the same reason mise pins it in .mise.toml.
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# The committed .sqlx cache stands in for a live database, exactly as it does
# for `mise run check` — a Docker build must never need Postgres.
ENV SQLX_OFFLINE=true
RUN cargo build --release -p api -p migrate

FROM debian:bookworm-slim

# CA roots for outbound TLS (rustls reads the system store); nothing needs them
# yet, but M6's Anthropic client will, and a missing root store fails obscurely.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/target/release/api /src/target/release/migrate /usr/local/bin/

# Unprivileged by default; the container has no reason to be root.
RUN useradd --system --no-create-home breathe
USER breathe

EXPOSE 18100
CMD ["api"]
