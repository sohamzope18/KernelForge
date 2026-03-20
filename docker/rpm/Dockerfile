# ─────────────────────────────────────────────────────────────
# Kernel RPM Build Environment
# Base: Fedora 39 (best dnf package availability for cross-tools)
# Produces: .rpm packages for RHEL / CentOS / Fedora
# ─────────────────────────────────────────────────────────────
FROM fedora:39

LABEL maintainer="kernel-build-project"
LABEL description="Linux kernel RPM build environment — x86_64 and ARM64"

# ── Core build tools ──────────────────────────────────────────
RUN dnf update -y && \
    dnf groupinstall -y "Development Tools" && \
    dnf install -y \
        # Packaging
        rpm-build \
        rpmdevtools \
        rpmlint \
        # Kernel build requirements
        bc \
        bison \
        flex \
        openssl-devel \
        elfutils-libelf-devel \
        dwarves \
        ncurses-devel \
        # Utilities
        wget \
        curl \
        tar \
        xz \
        gzip \
        diffutils \
        hostname \
        perl \
        perl-interpreter \
        python3 \
        rsync \
        cpio \
        kmod && \
    dnf clean all

# ── ARM64 cross-compilation toolchain ────────────────────────
# Fedora ships gcc-aarch64-linux-gnu in main repos
RUN dnf install -y \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu && \
    dnf clean all

# Verify cross compiler is functional
RUN aarch64-linux-gnu-gcc --version

# ── Setup rpmbuild directory tree ────────────────────────────
RUN rpmdev-setuptree && \
    echo "%_topdir /root/rpmbuild" > /root/.rpmmacros

WORKDIR /workspace

CMD ["/bin/bash"]
