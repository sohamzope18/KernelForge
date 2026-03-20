# ─────────────────────────────────────────────────────────────
# Kernel RPM Build Environment
# Base: Fedora 39 (best dnf package availability for cross-tools)
# Produces: .rpm packages for RHEL / CentOS / Fedora
#
# Multi-layer structure for optimal Docker build caching.
# ─────────────────────────────────────────────────────────────
FROM fedora:39

LABEL maintainer="kernel-build-project"
LABEL description="Linux kernel RPM build environment — x86_64 and ARM64"

# ── Layer 1: System update + Development Tools group ─────────
RUN dnf update -y && \
    dnf groupinstall -y "Development Tools" && \
    dnf clean all

# ── Layer 2: Kernel build dependencies ───────────────────────
RUN dnf install -y \
        bc \
        bison \
        flex \
        openssl \
        openssl-devel \
        elfutils-libelf-devel \
        dwarves \
        ncurses-devel \
        perl \
        perl-interpreter \
        python3 && \
    dnf clean all

# ── Layer 3: Packaging tools ────────────────────────────────
RUN dnf install -y \
        rpm-build \
        rpmdevtools \
        rpmlint && \
    dnf clean all

# ── Layer 4: Utility tools ──────────────────────────────────
RUN dnf install -y \
        wget \
        curl \
        tar \
        xz \
        gzip \
        diffutils \
        hostname \
        rsync \
        cpio \
        kmod && \
    dnf clean all

# ── Layer 5: ARM64 cross-compilation toolchain ──────────────
RUN dnf install -y \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu && \
    dnf clean all

# Verify cross compiler is functional
RUN aarch64-linux-gnu-gcc --version

# ── Layer 6: Setup rpmbuild directory tree ──────────────────
RUN rpmdev-setuptree && \
    echo "%_topdir /root/rpmbuild" > /root/.rpmmacros

WORKDIR /workspace

CMD ["/bin/bash"]
