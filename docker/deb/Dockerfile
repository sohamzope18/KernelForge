# ─────────────────────────────────────────────────────────────
# Kernel DEB Build Environment
# Base: Ubuntu 22.04
# Produces: .deb packages for Ubuntu / Debian
# ─────────────────────────────────────────────────────────────
FROM ubuntu:22.04

LABEL maintainer="kernel-build-project"
LABEL description="Linux kernel DEB build environment — x86_64 and ARM64"

# Non-interactive apt
ENV DEBIAN_FRONTEND=noninteractive

# ── Core build tools ──────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y \
        # Packaging
        build-essential \
        debhelper \
        dpkg-dev \
        fakeroot \
        lintian \
        # Kernel build requirements
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        dwarves \
        libncurses-dev \
        rsync \
        # Utilities
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

# ── ARM64 cross-compilation toolchain ────────────────────────
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
