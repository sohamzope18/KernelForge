# ─────────────────────────────────────────────────────────────
# Kernel DEB Build Environment
# Base: Ubuntu 22.04 LTS
# Produces: .deb packages for Ubuntu / Debian
# ─────────────────────────────────────────────────────────────
FROM ubuntu:22.04

LABEL maintainer="kernel-build-project"
LABEL description="Linux kernel DEB build environment — x86_64 and ARM64"

ENV DEBIAN_FRONTEND=noninteractive

# ── Enable arm64 foreign architecture for cross-build tools ──
RUN dpkg --add-architecture arm64

# ── Core build tools ──────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # Kernel build requirements
        build-essential \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        libncurses-dev \
        dwarves \
        # DEB packaging
        fakeroot \
        dpkg-dev \
        debhelper \
        # Utilities
        wget \
        curl \
        tar \
        xz-utils \
        gzip \
        rsync \
        git \
        python3 \
        cpio \
        kmod \
        file && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── ARM64 cross-compilation toolchain ────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        crossbuild-essential-arm64 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Verify cross compiler is functional
RUN aarch64-linux-gnu-gcc --version

WORKDIR /workspace

CMD ["/bin/bash"]
