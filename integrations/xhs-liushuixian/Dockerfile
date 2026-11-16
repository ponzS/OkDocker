# Sources are staged explicitly; keys, production SQLite and host binaries never enter the build context.
FROM rust:1.93.1-slim-bookworm@sha256:5b9332190bb3b9ece73b810cd1f1e9f06343b294ce184bcb067f0747d7d333ea AS builder
WORKDIR /build/server
COPY server/Cargo.toml server/Cargo.lock ./
COPY server/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates=20250419~deb12u2 ffmpeg=7:5.1.9-0+deb12u1 adb=1:29.0.6-28 tzdata=2026f-0+deb12u1 \
    && mkdir -p /usr/share/okdocker /opt/homebrew/bin \
    && dpkg-query -W > /usr/share/okdocker/package-versions.txt \
    && ln -s /usr/bin/adb /opt/homebrew/bin/adb \
    && ln -s /usr/bin/ffmpeg /opt/homebrew/bin/ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/server/target/release/xhs-server /usr/local/bin/xhs-server
ENV TZ=Asia/Shanghai XHS_HOST=0.0.0.0 XHS_PORT=17865
CMD ["/usr/local/bin/xhs-server"]
