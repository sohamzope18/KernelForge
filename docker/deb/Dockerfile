# ─────────────────────────────────────────────────────────────
# Kernel DEB Build Environment
# Base: Ubuntu 22.04
# Produces: .deb packages for Ubuntu / Debian
#
# Multi-layer structure for optimal Docker build caching.
# ─────────────────────────────────────────────────────────────
FROM ubuntu:22.04

LABEL maintainer="kernel-build-project"
LABEL description="Linux kernel DEB build environment — x86_64 and ARM64"

# Non-interactive apt
ENV DEBIAN_FRONTEND=noninteractive

# ── Layer 1: System update + build-essential ─────────────────
RUN apt-get update && \
    apt-get install -y \
        build-essential && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── Layer 2: Packaging tools ────────────────────────────────
RUN apt-get update && \
    apt-get install -y \
        debhelper \
        dpkg-dev \
        fakeroot \
        lintian && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── Layer 3: Kernel build dependencies ───────────────────────
RUN apt-get update && \
    apt-get install -y \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        dwarves \
        libncurses-dev \
        rsync && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── Layer 4: Utility tools ──────────────────────────────────
RUN apt-get update && \
    apt-get install -y \
        wget \
        curl \
        tar \
        xz-utils \
        gzip \
        python3 \
        cpio \
        kmod \
        git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── Layer 5: ARM64 cross-compilation toolchain ──────────────
RUN apt-get update && \
    apt-get install -y \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Verify cross compiler is functional
RUN aarch64-linux-gnu-gcc --version

# ── Workspace Setup ──────────────────────────────────────────
WORKDIR /workspace

CMD ["/bin/bash"]
