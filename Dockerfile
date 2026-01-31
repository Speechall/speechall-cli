# Build static Linux binaries for both amd64 and arm64.
#
# Usage:
#   DOCKER_BUILDKIT=1 docker build --output type=local,dest=. .
#
# This produces two fully static, musl-based binaries in the current directory:
#   speechall-linux-amd64
#   speechall-linux-arm64

FROM swift:6.2.3 AS builder

RUN swift sdk install \
    https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz \
    --checksum f30ec724d824ef43b5546e02ca06a8682dafab4b26a99fbb0e858c347e507a2c

WORKDIR /build

# Copy package manifest first for dependency caching
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Copy source code
COPY Sources/ Sources/

# Build for x86_64
RUN swift build -c release --swift-sdk x86_64-swift-linux-musl \
    && mkdir -p /output \
    && cp "$(swift build -c release --swift-sdk x86_64-swift-linux-musl --show-bin-path)/speechall" \
       /output/speechall-linux-amd64

# Build for aarch64
RUN swift build -c release --swift-sdk aarch64-swift-linux-musl \
    && cp "$(swift build -c release --swift-sdk aarch64-swift-linux-musl --show-bin-path)/speechall" \
       /output/speechall-linux-arm64

# Install cross-architecture strip tools and strip debug symbols
RUN apt-get update \
    && apt-get install -y --no-install-recommends binutils-x86-64-linux-gnu binutils-aarch64-linux-gnu \
    && rm -rf /var/lib/apt/lists/* \
    && x86_64-linux-gnu-strip /output/speechall-linux-amd64 \
    && aarch64-linux-gnu-strip /output/speechall-linux-arm64

# Export stage - only the binaries
FROM scratch
COPY --from=builder /output/ /
