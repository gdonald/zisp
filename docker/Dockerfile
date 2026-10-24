# The image the home lab's Jenkins runs ./test.sh in: Zig, plus kcov for
# `zig build coverage` and Python for test.sh's coverage summary.
#
# The base is pinned by digest, since a tag can be moved to point at a
# different image.
FROM debian@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
      ca-certificates \
      curl \
      kcov \
      python3 \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The version and checksums are the ones https://ziglang.org/download/index.json
# lists for each tarball.
ARG ZIG_VERSION=0.17.0
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) zig_arch=x86_64 ; zig_sha256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;; \
      arm64) zig_arch=aarch64 ; zig_sha256=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;; \
      *) echo "no Zig tarball for $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/zig.tar.xz \
         "https://ziglang.org/download/$ZIG_VERSION/zig-$zig_arch-linux-$ZIG_VERSION.tar.xz" \
    && echo "$zig_sha256  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /workspace
