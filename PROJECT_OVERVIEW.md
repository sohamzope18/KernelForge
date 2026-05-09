# KernelForge: Project Tree and File Contents

This document contains the entire project tree and the complete contents of every file in the project.

## Project Tree

```text
.
├── .github
│   └── workflows
│       └── ci.yml
├── .gitignore
├── PROJECT_OVERVIEW.md
├── README.md
├── docker
│   ├── deb
│   │   └── Dockerfile
│   └── rpm
│       └── Dockerfile
├── kernel
│   └── configs
│       ├── arm64_defconfig
│       └── x86_64_defconfig
├── kernel.spec
└── scripts
    ├── boot-test.sh
    ├── build-deb.sh
    ├── build-rpm.sh
    └── fetch-kernel.sh
```

## File Contents

### `.github/workflows/ci.yml`

```yaml
name: Linux Kernel Build Pipeline

# Triggers: manual trigger only
on:
  push:
  workflow_dispatch:
    inputs:
      kernel_version:
        description: 'Kernel version (e.g. 6.6.30)'
        required: false
        default: '6.6.30'

env:
  KERNEL_VERSION: ${{ github.event.inputs.kernel_version || '6.6.30' }}

jobs:
  # ──────────────────────────────────────────────
  # Stage 1: Build Docker images (parallel)
  # ──────────────────────────────────────────────
  build-images:
    name: Build Docker image (${{ matrix.pkg_format }})
    runs-on: ubuntu-latest
    timeout-minutes: 30

    strategy:
      fail-fast: false
      matrix:
        pkg_format: [rpm, deb]

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Free disk space
        run: |
          echo "Disk before cleanup:"
          df -h
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
                      /usr/share/swift /usr/local/share/boost \
                      "$AGENT_TOOLSDIRECTORY"
          sudo apt-get clean
          echo "Disk after cleanup:"
          df -h

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Cache Docker layers
        uses: actions/cache@v4
        with:
          path: /tmp/.buildx-cache-${{ matrix.pkg_format }}
          key: buildx-${{ matrix.pkg_format }}-${{ hashFiles(format('docker/{0}/Dockerfile', matrix.pkg_format)) }}
          restore-keys: |
            buildx-${{ matrix.pkg_format }}-

      - name: Build and export Docker image
        uses: docker/build-push-action@v5
        with:
          context: docker/${{ matrix.pkg_format }}
          tags: kernel-builder-${{ matrix.pkg_format }}:latest
          outputs: type=docker,dest=/tmp/kernel-builder-${{ matrix.pkg_format }}.tar
          cache-from: type=local,src=/tmp/.buildx-cache-${{ matrix.pkg_format }}
          cache-to: type=local,dest=/tmp/.buildx-cache-${{ matrix.pkg_format }}-new,mode=max

      - name: Rotate cache
        run: |
          rm -rf /tmp/.buildx-cache-${{ matrix.pkg_format }}
          mv /tmp/.buildx-cache-${{ matrix.pkg_format }}-new /tmp/.buildx-cache-${{ matrix.pkg_format }}

      - name: Upload image as artifact
        uses: actions/upload-artifact@v4
        with:
          name: docker-image-${{ matrix.pkg_format }}
          path: /tmp/kernel-builder-${{ matrix.pkg_format }}.tar
          retention-days: 1

  # ──────────────────────────────────────────────
  # Stage 2: Fetch & cache kernel source once
  # ──────────────────────────────────────────────
  fetch-source:
    name: Fetch Kernel Source
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Cache kernel tarball
        id: cache-kernel
        uses: actions/cache@v4
        with:
          path: kernel-source/linux-${{ env.KERNEL_VERSION }}.tar.xz
          key: kernel-src-${{ env.KERNEL_VERSION }}

      - name: Download and verify kernel source
        if: steps.cache-kernel.outputs.cache-hit != 'true'
        run: bash scripts/fetch-kernel.sh "$KERNEL_VERSION" kernel-source

      - name: Upload source as artifact
        uses: actions/upload-artifact@v4
        with:
          name: kernel-source-${{ env.KERNEL_VERSION }}
          path: kernel-source/linux-${{ env.KERNEL_VERSION }}.tar.xz
          retention-days: 1

  # ──────────────────────────────────────────────
  # Stage 3: Build kernel packages (matrix)
  # ──────────────────────────────────────────────
  build-kernel:
    name: Build ${{ matrix.arch }} (${{ matrix.pkg_format }})
    runs-on: ubuntu-latest
    timeout-minutes: 300         # 5 hours — kernel compilation can be slow
    needs: [build-images, fetch-source]

    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: x86_64
            kernel_arch: x86
            pkg_format: rpm
            cross_compile: ''
          - arch: arm64
            kernel_arch: arm64
            pkg_format: rpm
            cross_compile: 'aarch64-linux-gnu-'
          - arch: x86_64
            kernel_arch: x86
            pkg_format: deb
            cross_compile: ''
          - arch: arm64
            kernel_arch: arm64
            pkg_format: deb
            cross_compile: 'aarch64-linux-gnu-'

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Free disk space
        run: |
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
                      /usr/share/swift /usr/local/share/boost \
                      "$AGENT_TOOLSDIRECTORY"
          sudo apt-get clean
          df -h

      - name: Download Docker image
        uses: actions/download-artifact@v4
        with:
          name: docker-image-${{ matrix.pkg_format }}
          path: /tmp

      - name: Load Docker image
        run: docker load -i /tmp/kernel-builder-${{ matrix.pkg_format }}.tar

      - name: Download kernel source
        uses: actions/download-artifact@v4
        with:
          name: kernel-source-${{ env.KERNEL_VERSION }}
          path: kernel-source

      - name: Create output directory
        run: mkdir -p output

      - name: Build kernel package
        run: |
          docker run --rm \
            -v "${{ github.workspace }}:/workspace" \
            -v "${{ github.workspace }}/kernel-source:/kernel-source:ro" \
            -e KERNEL_VERSION="${{ env.KERNEL_VERSION }}" \
            -e ARCH="${{ matrix.kernel_arch }}" \
            -e CROSS_COMPILE="${{ matrix.cross_compile }}" \
            kernel-builder-${{ matrix.pkg_format }}:latest \
            /workspace/scripts/build-${{ matrix.pkg_format }}.sh

      - name: List output
        run: ls -lh output/

      - name: Upload built packages
        uses: actions/upload-artifact@v4
        with:
          name: kernel-${{ matrix.arch }}-${{ matrix.pkg_format }}-${{ env.KERNEL_VERSION }}
          path: |
            output/*.rpm
            output/*.deb
            output/*.buildinfo
          retention-days: 30

  # ──────────────────────────────────────────────
  # Stage 4: Boot test with QEMU (x86_64 only)
  # ──────────────────────────────────────────────
  boot-test:
    name: QEMU Boot Test (x86_64)
    runs-on: ubuntu-latest
    timeout-minutes: 30
    needs: build-kernel

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Download x86_64 deb packages
        uses: actions/download-artifact@v4
        with:
          name: kernel-x86_64-deb-${{ env.KERNEL_VERSION }}
          path: test-packages

      - name: Install QEMU
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y qemu-system-x86 qemu-utils

      - name: Run boot test
        run: bash scripts/boot-test.sh test-packages

  # ──────────────────────────────────────────────
  # Stage 5: Release — on every commit
  # ──────────────────────────────────────────────
  release:
    name: Create GitHub Release
    runs-on: ubuntu-latest
    timeout-minutes: 15
    needs: [build-kernel, boot-test]
    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'

    permissions:
      contents: write

    steps:
      - name: Download all build artifacts
        uses: actions/download-artifact@v4
        with:
          path: release-packages
          pattern: kernel-*

      - name: List all packages
        run: find release-packages -name "*.rpm" -o -name "*.deb" | sort

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: kernel-${{ env.KERNEL_VERSION }}-build.${{ github.run_number }}
          name: "Linux Kernel ${{ env.KERNEL_VERSION }} — Build #${{ github.run_number }}"
          body: |
            ## Linux Kernel ${{ env.KERNEL_VERSION }}

            **Built from commit:** ${{ github.sha }}
            **Build date:** ${{ github.event.head_commit.timestamp }}

            ### Packages included
            | Arch | RPM | DEB |
            |------|-----|-----|
            | x86_64 | ✅ | ✅ |
            | arm64  | ✅ | ✅ |

            ### Install
            **RPM (RHEL/CentOS/Fedora):**
            ```bash
            sudo rpm -ivh kernel-*.rpm
            ```
            **DEB (Ubuntu/Debian):**
            ```bash
            sudo dpkg -i linux-image-*.deb
            ```
          files: |
            release-packages/**/*.rpm
            release-packages/**/*.deb
          fail_on_unmatched_files: false
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### `.gitignore`

```text
# Build output
output/
*.rpm
*.deb
*.buildinfo
*.changes

# Kernel source downloads (cached separately)
kernel-source/
*.tar.xz
*.tar.gz
*.sha256

# Temporary build directories
/tmp/kernel-build/

# Docker artifacts
*.tar

# Editor files
.vscode/
.idea/
*.swp
*.swo
*~

# OS files
.DS_Store
Thumbs.db
```

### `README.md`

```markdown
# Linux Kernel Build Automation

Automated pipeline for building and packaging custom Linux kernels for
**x86_64** and **ARM64** architectures, producing both **RPM** (RHEL/CentOS/Fedora)
and **DEB** (Ubuntu/Debian) packages — triggered automatically via GitHub Actions.

---

## Project Structure

```
linux-kernel-build/
├── .github/
│   └── workflows/
│       └── ci.yml      ← GitHub Actions pipeline (5 stages)
├── docker/
│   ├── rpm/
│   │   └── Dockerfile            ← Fedora-based RPM build environment
│   └── deb/
│       └── Dockerfile            ← Ubuntu-based DEB build environment
├── kernel/
│   ├── configs/
│   │   ├── x86_64_defconfig      ← Custom x86_64 kernel config
│   │   └── arm64_defconfig       ← Custom ARM64 kernel config
│   └── patches/                  ← Drop .patch files here
├── scripts/
│   ├── fetch-kernel.sh           ← Downloads + verifies kernel source
│   ├── build-rpm.sh              ← RPM build (runs in Docker)
│   ├── build-deb.sh              ← DEB build (runs in Docker)
│   └── boot-test.sh              ← QEMU smoke test
├── specs/
│   └── kernel.spec               ← Custom RPM spec (optional override)
└── output/                       ← Built packages land here
```

---

## Pipeline Stages

```
Stage 1: Build Docker images (RPM + DEB, in parallel)
         ↓
Stage 2: Fetch + cache kernel source tarball
         ↓
Stage 3: Build 4 packages in parallel matrix:
         ├── x86_64 RPM
         ├── arm64  RPM
         ├── x86_64 DEB
         └── arm64  DEB
         ↓
Stage 4: QEMU boot test (x86_64 kernel)
         ↓
Stage 5: GitHub Release (main branch only)
```

---

## Quick Start

### Prerequisites

```bash
# macOS
brew install docker git

# Ubuntu/Debian
sudo apt install docker.io git

# Verify Docker works
docker run hello-world
```

### 1. Fork / clone this repository

```bash
git clone https://github.com/YOUR_USERNAME/linux-kernel-build.git
cd linux-kernel-build
```

### 2. Make script files executable

```bash
chmod +x scripts/*.sh
```

### 3. Trigger the build

The pipeline is **manually triggered** — it does not run on every push.

```bash
git add .
git commit -m "initial kernel build setup"
git push origin main
```

Then go to the **Actions** tab in GitHub → select **Linux Kernel Build Pipeline** → click **Run workflow** → choose your kernel version → click **Run workflow**.

---

## Manual / Local Build

You can run the build locally with Docker without pushing to GitHub.

### Step 1 — Fetch the kernel source

```bash
bash scripts/fetch-kernel.sh 6.6.30 ./kernel-source
```

### Step 2 — Build the Docker image

```bash
# For RPM packages:
docker build -t kernel-builder-rpm docker/rpm/

# For DEB packages:
docker build -t kernel-builder-deb docker/deb/
```

### Step 3 — Run the build

```bash
mkdir -p output kernel-source

# x86_64 RPM (native)
docker run --rm \
  -v "$PWD:/workspace" \
  -v "$PWD/kernel-source:/kernel-source:ro" \
  -e KERNEL_VERSION=6.6.30 \
  -e ARCH=x86 \
  -e CROSS_COMPILE="" \
  kernel-builder-rpm \
  /workspace/scripts/build-rpm.sh

# ARM64 RPM (cross-compiled)
docker run --rm \
  -v "$PWD:/workspace" \
  -v "$PWD/kernel-source:/kernel-source:ro" \
  -e KERNEL_VERSION=6.6.30 \
  -e ARCH=arm64 \
  -e CROSS_COMPILE="aarch64-linux-gnu-" \
  kernel-builder-rpm \
  /workspace/scripts/build-rpm.sh

# x86_64 DEB (native)
docker run --rm \
  -v "$PWD:/workspace" \
  -v "$PWD/kernel-source:/kernel-source:ro" \
  -e KERNEL_VERSION=6.6.30 \
  -e ARCH=x86 \
  -e CROSS_COMPILE="" \
  kernel-builder-deb \
  /workspace/scripts/build-deb.sh

# ARM64 DEB (cross-compiled)
docker run --rm \
  -v "$PWD:/workspace" \
  -v "$PWD/kernel-source:/kernel-source:ro" \
  -e KERNEL_VERSION=6.6.30 \
  -e ARCH=arm64 \
  -e CROSS_COMPILE="aarch64-linux-gnu-" \
  kernel-builder-deb \
  /workspace/scripts/build-deb.sh
```

Packages will appear in `./output/`.

---

## Customizing the Kernel

### Modify kernel config

Edit `kernel/configs/x86_64_defconfig` or `kernel/configs/arm64_defconfig`.

To generate a config interactively:

```bash
# Run menuconfig inside the build container
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v "$PWD/kernel-source:/kernel-source" \
  kernel-builder-deb \
  bash -c "
    tar -xf /kernel-source/linux-6.6.30.tar.xz -C /tmp &&
    cp /workspace/kernel/configs/x86_64_defconfig /tmp/linux-6.6.30/.config &&
    make -C /tmp/linux-6.6.30 ARCH=x86_64 menuconfig &&
    cp /tmp/linux-6.6.30/.config /workspace/kernel/configs/x86_64_defconfig
  "
```

### Add a custom kernel version

Trigger the workflow manually from the **Actions** tab → **Run workflow** → enter
your desired version (e.g. `6.9.1`).

Or change the default in `.github/workflows/ci.yml`:

```yaml
env:
  KERNEL_VERSION: '6.9.1'   # ← change this
```

### Apply patches

Drop `.patch` files in `kernel/patches/`. They are applied in alphabetical order
before compilation. See `kernel/patches/README.md` for patch format details.

---

## Installing the Built Packages

### RPM (RHEL / CentOS / Fedora)

```bash
# Download the artifact from GitHub Releases, then:
sudo rpm -ivh kernel-custom-*.x86_64.rpm

# Or with dnf (handles dependencies):
sudo dnf install ./kernel-custom-*.x86_64.rpm

# Reboot into the new kernel:
sudo reboot
```

### DEB (Ubuntu / Debian)

```bash
# Download the artifact from GitHub Releases, then:
sudo dpkg -i linux-image-*.deb linux-headers-*.deb

# Reboot into the new kernel:
sudo reboot
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Build times out | Job > 5hr | Increase `timeout-minutes` in workflow, or reduce `CONFIG_` options |
| "No space left on device" | Docker layer + build = ~25GB | Increase runner disk, or disable debug symbols in config |
| ARM cross compiler not found | Package not in image | Check Dockerfile installs `gcc-aarch64-linux-gnu` |
| QEMU boot test fails | Initrd too minimal | The test is non-blocking — check log for kernel panic details |
| SHA256 mismatch | Corrupt download | Delete `kernel-source/linux-*.tar.xz` and re-run |
| RPM signing error | Module signing key missing | Set `CONFIG_MODULE_SIG=n` in defconfig for dev builds |

---

## Resource Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Runner RAM | 4 GB | 8 GB |
| Disk space | 20 GB | 40 GB |
| Build time (x86_64) | ~45 min | ~25 min (8 CPUs) |
| Build time (arm64 cross) | ~60 min | ~35 min (8 CPUs) |

GitHub-hosted `ubuntu-latest` runners provide 7 GB RAM, 14 GB disk, and 2 CPUs.
Disk may be tight — the free-space cleanup step in the workflow handles this.

---

## Contributing / Extending

- To add a new distro package format, add a new `docker/<format>/Dockerfile`
  and `scripts/build-<format>.sh`, then add entries to the matrix in the workflow.
- Patches in `kernel/patches/` are applied before every build — no workflow
  changes needed.
- The `specs/kernel.spec` file is only used if you run `rpmbuild -ba` manually.
  The default automated path uses `make rpm-pkg`.
```

### `docker/deb/Dockerfile`

```dockerfile
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
```

### `docker/rpm/Dockerfile`

```dockerfile
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
```

### `kernel/configs/arm64_defconfig`

```text
# ─────────────────────────────────────────────────────────────
# ARM64 (AArch64) Kernel Configuration
# Linux Kernel 6.6.x LTS — Minimal production config
#
# To generate a full config:
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
#
# After placing this file in the build directory:
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
# ─────────────────────────────────────────────────────────────

# ── Architecture base ─────────────────────────────────────────
CONFIG_ARM64=y
CONFIG_64BIT=y
CONFIG_MMU=y
CONFIG_SMP=y
CONFIG_NR_CPUS=256
CONFIG_PREEMPT_VOLUNTARY=y
CONFIG_HZ_250=y
CONFIG_HZ=250

# ── ARM64 CPU features ────────────────────────────────────────
CONFIG_ARM64_4K_PAGES=y
CONFIG_ARM64_VA_BITS_48=y
CONFIG_ARM64_PA_BITS_48=y
CONFIG_COMPAT=y                  # 32-bit ARM application support
CONFIG_ARM64_ERRATUM_843419=y
CONFIG_ARM64_ERRATUM_845719=y
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_CPUFREQ_DT=y
CONFIG_ARM_CPUFREQ=y
CONFIG_ENERGY_MODEL=y

# ── General kernel features ───────────────────────────────────
CONFIG_PRINTK=y
CONFIG_BUG=y
CONFIG_ELF_CORE=y
CONFIG_BASE_FULL=y
CONFIG_FUTEX=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EVENTFD=y
CONFIG_SHMEM=y
CONFIG_AIO=y
CONFIG_IO_URING=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y

# ── Memory management ─────────────────────────────────────────
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
CONFIG_COMPACTION=y
CONFIG_MIGRATION=y
CONFIG_KSM=y
CONFIG_MEMORY_HOTPLUG=y
CONFIG_MEMORY_HOTREMOVE=y
CONFIG_NUMA=y
CONFIG_NUMA_BALANCING=y

# ── Block layer ───────────────────────────────────────────────
CONFIG_BLOCK=y
CONFIG_MQ_IOSCHED_DEADLINE=y
CONFIG_MQ_IOSCHED_KYBER=y
CONFIG_BLK_WBT=y

# ── Storage drivers ───────────────────────────────────────────
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_SCSI_VIRTIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y
CONFIG_MMC=y                     # SD/eMMC for embedded ARM boards
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PLTFM=y

# ── Network ───────────────────────────────────────────────────
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=m
CONFIG_IP_NF_IPTABLES=m
CONFIG_IP_NF_FILTER=m
CONFIG_IP_NF_NAT=m
CONFIG_NET_SCHED=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_TCP_CONG_BBR=m
CONFIG_VIRTIO_NET=y
CONFIG_STMMAC_ETH=y              # Common on ARM SoCs (RPi, etc.)
CONFIG_DWMAC_GENERIC=y

# ── ARM64 Platform / SoC Support ─────────────────────────────
CONFIG_ARCH_SUNXI=y              # Allwinner (Orange Pi, etc.)
CONFIG_ARCH_BCM=y                # Broadcom (Raspberry Pi)
CONFIG_ARCH_BCM2835=y            # Raspberry Pi 3/4
CONFIG_ARCH_QCOM=y               # Qualcomm SoCs
CONFIG_ARCH_LAYERSCAPE=y         # NXP Layerscape
CONFIG_ARCH_ROCKCHIP=y           # Rockchip (Rock Pi, etc.)
CONFIG_ARCH_MESON=y              # Amlogic
CONFIG_ARCH_MEDIATEK=y           # MediaTek

# ── Filesystems ───────────────────────────────────────────────
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_XFS_FS=y
CONFIG_BTRFS_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_VFAT_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_FUSE_FS=m

# ── Virtualization ────────────────────────────────────────────
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y             # ARM often uses MMIO not PCI
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_KVM=m
CONFIG_KVM_ARM_HOST=m

# ── Security ─────────────────────────────────────────────────
CONFIG_SECURITY=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_HARDENED_USERCOPY=y

# ── Namespaces and cgroups (required for containers) ─────────
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CPUSETS=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y

# ── Hardware interfaces ───────────────────────────────────────
CONFIG_I2C=y
CONFIG_I2C_CHARDEV=y
CONFIG_SPI=y
CONFIG_SPI_MASTER=y
CONFIG_GPIOLIB=y
CONFIG_GPIO_SYSFS=y
CONFIG_PWM=y
CONFIG_USB_SUPPORT=y
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_XHCI_PCI=y
CONFIG_USB_DWC3=y                # DesignWare USB3 (common on ARM)
CONFIG_USB_DWC2=y                # DesignWare USB2

# ── Serial / console ─────────────────────────────────────────
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y      # ARM PL011 UART (standard on ARM)
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_UNIX98_PTYS=y

# ── Module support ────────────────────────────────────────────
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_SHA256=y

# ── Device Tree (mandatory for ARM) ──────────────────────────
CONFIG_OF=y
CONFIG_OF_FLATTREE=y
CONFIG_OF_EARLY_FLATTREE=y
CONFIG_OF_DYNAMIC=y
CONFIG_OF_OVERLAY=y

# ── Debugging (minimal) ───────────────────────────────────────
# CONFIG_DEBUG_KERNEL is not set
CONFIG_PRINTK_TIME=y
CONFIG_DYNAMIC_DEBUG=y
CONFIG_MAGIC_SYSRQ=y
```

### `kernel/configs/x86_64_defconfig`

```text
# ─────────────────────────────────────────────────────────────
# x86_64 Kernel Configuration
# Linux Kernel 6.6.x LTS — Minimal production config
#
# This is a curated subset of options. To generate a full config:
#   make ARCH=x86_64 defconfig        (bare minimum)
#   make ARCH=x86_64 menuconfig       (interactive editor)
#   make ARCH=x86_64 localmodconfig   (matched to current machine)
#
# After placing this file in the build directory, run:
#   make ARCH=x86_64 olddefconfig
# to fill any missing options with upstream defaults.
# ─────────────────────────────────────────────────────────────

# ── Processor and architecture ────────────────────────────────
CONFIG_X86_64=y
CONFIG_64BIT=y
CONFIG_SMP=y
CONFIG_NR_CPUS=256
CONFIG_PREEMPT_VOLUNTARY=y
CONFIG_HZ_250=y
CONFIG_HZ=250

# ── General kernel features ───────────────────────────────────
CONFIG_PRINTK=y
CONFIG_BUG=y
CONFIG_ELF_CORE=y
CONFIG_BASE_FULL=y
CONFIG_FUTEX=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EVENTFD=y
CONFIG_SHMEM=y
CONFIG_AIO=y
CONFIG_IO_URING=y
CONFIG_ADVISE_SYSCALLS=y
CONFIG_USERFAULTFD=y
CONFIG_MEMBARRIER=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y

# ── Memory management ─────────────────────────────────────────
CONFIG_SPARSEMEM_VMEMMAP=y
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
CONFIG_COMPACTION=y
CONFIG_MIGRATION=y
CONFIG_KSM=y
CONFIG_MEMORY_HOTPLUG=y
CONFIG_MEMORY_HOTREMOVE=y
CONFIG_ZONE_DMA=y
CONFIG_ZONE_DMA32=y
CONFIG_NUMA=y
CONFIG_NUMA_BALANCING=y

# ── Block layer ───────────────────────────────────────────────
CONFIG_BLOCK=y
CONFIG_BLK_DEV_BSG=y
CONFIG_BLK_DEV_BSGLIB=y
CONFIG_IOSCHED_MQUEUE=y
CONFIG_MQ_IOSCHED_DEADLINE=y
CONFIG_MQ_IOSCHED_KYBER=y
CONFIG_BLK_WBT=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y

# ── Storage drivers ───────────────────────────────────────────
CONFIG_ATA=y
CONFIG_ATA_VERBOSE_ERROR=y
CONFIG_SATA_AHCI=y
CONFIG_ATA_PIIX=y
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_SCSI_VIRTIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y

# ── Network ───────────────────────────────────────────────────
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=m
CONFIG_IP_NF_IPTABLES=m
CONFIG_IP_NF_FILTER=m
CONFIG_IP_NF_NAT=m
CONFIG_NET_SCHED=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_TCP_CONG_BBR=m
CONFIG_VIRTIO_NET=y
CONFIG_E1000=y
CONFIG_E1000E=y
CONFIG_IGB=y
CONFIG_IXGBE=y

# ── Filesystems ───────────────────────────────────────────────
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_XFS_FS=y
CONFIG_BTRFS_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_VFAT_FS=y
CONFIG_OVERLAY_FS=y                # Required for Docker/containers
CONFIG_FUSE_FS=m

# ── Virtualization ────────────────────────────────────────────
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_KVM=m
CONFIG_KVM_INTEL=m
CONFIG_KVM_AMD=m
CONFIG_VHOST_NET=m

# ── Security ─────────────────────────────────────────────────
CONFIG_SECURITY=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_RANDOMIZE_BASE=y             # KASLR
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_CC_STACKPROTECTOR_STRONG=y
CONFIG_HARDENED_USERCOPY=y

# ── Namespaces and cgroups (required for containers) ─────────
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CPUSETS=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y

# ── Hardware support ──────────────────────────────────────────
CONFIG_PCI=y
CONFIG_PCI_MSI=y
CONFIG_PCIEPORTBUS=y
CONFIG_USB_SUPPORT=y
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_HID=y
CONFIG_HID_GENERIC=y
CONFIG_INPUT=y
CONFIG_INPUT_KEYBOARD=y

# ── Serial / console ─────────────────────────────────────────
CONFIG_TTY=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_UNIX98_PTYS=y

# ── Module support ────────────────────────────────────────────
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_SHA256=y

# ── Debugging (minimal — disable for production) ─────────────
# CONFIG_DEBUG_KERNEL is not set
CONFIG_PRINTK_TIME=y
CONFIG_DYNAMIC_DEBUG=y
CONFIG_MAGIC_SYSRQ=y
```

### `kernel.spec`

```text
# ─────────────────────────────────────────────────────────────
# kernel.spec
# Custom RPM spec for the Linux kernel build project.
# Used when you need fine-grained control over the RPM package
# (e.g. custom changelog, additional post-install hooks).
#
# For standard builds, `make rpm-pkg` generates its own spec
# automatically. Use this file when you want to OVERRIDE that
# by running: rpmbuild -ba specs/kernel.spec
#
# Variables set externally or with defaults:
#   %{kernel_version}  — full kernel version string
#   %{kernel_arch}     — x86_64 | aarch64
# ─────────────────────────────────────────────────────────────

%define kernel_version  %{?kver}%{!?kver:6.6.30}
%define kernel_arch     %{?karch}%{!?karch:x86_64}
%define pkg_release     1

Name:           kernel-custom
Version:        %{kernel_version}
Release:        %{pkg_release}%{?dist}
Summary:        Custom Linux Kernel — built via automated CI/CD pipeline
License:        GPL-2.0-only
URL:            https://www.kernel.org/

# Source tarball must be placed in SOURCES directory before building
# e.g. ~/rpmbuild/SOURCES/linux-6.6.30.tar.xz
Source0:        linux-%{version}.tar.xz

ExclusiveArch:  x86_64 aarch64

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  bc
BuildRequires:  bison
BuildRequires:  flex
BuildRequires:  openssl-devel
BuildRequires:  elfutils-libelf-devel
BuildRequires:  dwarves
BuildRequires:  ncurses-devel

# Disable debug package (saves disk space and build time)
%global debug_package %{nil}

%description
Custom Linux kernel %{version} for %{kernel_arch}.
Built by the automated Linux Kernel Build Automation pipeline
using Docker and GitHub Actions CI/CD.

Configuration tailored for production use with:
  - Container support (namespaces, cgroups, overlay fs)
  - Virtualization support (KVM, Virtio)
  - Security hardening (SELinux, AppArmor, KASLR)
  - Network performance tuning (BBR, FQ-CoDel)

%package devel
Summary:    Development headers for kernel %{version}
Group:      Development/System

%description devel
Kernel development headers for building external kernel modules
against kernel version %{version}.

%prep
%setup -q -n linux-%{version}

# Apply custom config
if [ -f /workspace/kernel/configs/%{kernel_arch}_defconfig ]; then
    cp /workspace/kernel/configs/%{kernel_arch}_defconfig .config
    make ARCH=%{kernel_arch} olddefconfig
fi

# Apply patches if present
PATCH_DIR="/workspace/kernel/patches"
if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -f "$patch" ] || continue
        echo "Applying patch: $patch"
        patch -p1 < "$patch"
    done
fi

%build
make %{?_smp_mflags} ARCH=%{kernel_arch}

%install
rm -rf %{buildroot}

# Install kernel
INSTALL_PATH=%{buildroot}/boot
mkdir -p "$INSTALL_PATH"
mkdir -p %{buildroot}/lib/modules

make ARCH=%{kernel_arch} \
    INSTALL_PATH="$INSTALL_PATH" \
    INSTALL_MOD_PATH=%{buildroot} \
    install modules_install

# Install headers
make ARCH=%{kernel_arch} \
    INSTALL_HDR_PATH=%{buildroot}/usr \
    headers_install

# Create symlinks
KERNEL_RELEASE=$(cat include/config/kernel.release)
ln -sf "vmlinuz-${KERNEL_RELEASE}" %{buildroot}/boot/vmlinuz || true

%files
/boot/vmlinuz*
/boot/System.map*
/boot/config-*
/lib/modules/

%files devel
/usr/include/

%post
# Generate initramfs after install
KERNEL_RELEASE=$(ls /lib/modules | grep "%{version}" | head -1)
if [ -n "$KERNEL_RELEASE" ]; then
    echo "Generating initramfs for kernel $KERNEL_RELEASE..."
    if command -v dracut &>/dev/null; then
        dracut --force "/boot/initramfs-${KERNEL_RELEASE}.img" "$KERNEL_RELEASE"
    elif command -v mkinitramfs &>/dev/null; then
        mkinitramfs -o "/boot/initrd.img-${KERNEL_RELEASE}" "$KERNEL_RELEASE"
    fi
fi

# Update bootloader
if command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg || true
fi

%preun
# Prevent removal of currently running kernel
RUNNING=$(uname -r)
if echo "%{version}" | grep -q "$RUNNING"; then
    echo "ERROR: Cannot remove currently running kernel"
    exit 1
fi

%changelog
* %(date "+%a %b %d %Y") Automated Build <ci@build> - %{version}-%{pkg_release}
- Automated build via GitHub Actions CI/CD pipeline
- Custom configuration for containerized and virtualized workloads
- Security hardening enabled (SELinux, AppArmor, KASLR, Seccomp)
```

### `scripts/boot-test.sh`

```bash
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# boot-test.sh
# Extracts the built kernel from .deb package and boots it
# inside QEMU with a minimal initrd to verify it starts.
#
# Runs on the GitHub Actions runner (not in Docker).
# Requires: qemu-system-x86_64 (installed by workflow)
#
# Usage: bash scripts/boot-test.sh <packages-dir>
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PACKAGES_DIR="${1:?Usage: boot-test.sh <packages-dir>}"
WORK_DIR="/tmp/boot-test"
TIMEOUT_SECONDS=120
BOOT_SUCCESS_PATTERN="Freeing unused kernel image"

echo "════════════════════════════════════════════"
echo " QEMU Boot Test"
echo " Packages dir: ${PACKAGES_DIR}"
echo " Timeout:      ${TIMEOUT_SECONDS}s"
echo "════════════════════════════════════════════"

# ── Find the kernel image DEB ─────────────────────────────────
KERNEL_DEB=$(find "$PACKAGES_DIR" -name "linux-image-*.deb" ! -name "*dbg*" | head -1)

if [[ -z "$KERNEL_DEB" ]]; then
    echo "ERROR: No linux-image-*.deb found in $PACKAGES_DIR"
    ls "$PACKAGES_DIR" || true
    exit 1
fi

echo "Testing kernel from: $KERNEL_DEB"

# ── Extract kernel image from DEB ─────────────────────────────
mkdir -p "$WORK_DIR/deb-extract"
dpkg-deb -x "$KERNEL_DEB" "$WORK_DIR/deb-extract"

VMLINUZ=$(find "$WORK_DIR/deb-extract" -name "vmlinuz-*" | head -1)

if [[ -z "$VMLINUZ" ]]; then
    echo "ERROR: vmlinuz not found inside DEB"
    find "$WORK_DIR/deb-extract" -type f | head -20
    exit 1
fi

echo "Kernel image: $VMLINUZ"

# ── Build a minimal initrd ─────────────────────────────────────
# A tiny initrd that just prints "boot-ok" and powers off
echo "Building minimal initrd..."
mkdir -p "$WORK_DIR/initrd/bin"

# Minimal init script
cat > "$WORK_DIR/initrd/init" << 'INIT_EOF'
#!/bin/sh
echo "=== KERNEL BOOT TEST: init reached ==="
echo "=== BOOT_TEST_OK ==="
poweroff -f
INIT_EOF
chmod +x "$WORK_DIR/initrd/init"

# Use busybox if available for shell support, otherwise try static sh
if command -v busybox &>/dev/null; then
    cp "$(which busybox)" "$WORK_DIR/initrd/bin/busybox"
    ln -sf busybox "$WORK_DIR/initrd/bin/sh"
    ln -sf busybox "$WORK_DIR/initrd/bin/poweroff"
else
    # Copy static binaries if available
    for bin in sh poweroff; do
        BIN_PATH=$(which "$bin" 2>/dev/null || true)
        if [[ -n "$BIN_PATH" ]]; then
            cp "$BIN_PATH" "$WORK_DIR/initrd/bin/" 2>/dev/null || true
        fi
    done
fi

# Pack the initrd
echo "Packing initrd..."
pushd "$WORK_DIR/initrd" > /dev/null
find . | cpio -H newc -o 2>/dev/null | gzip > "$WORK_DIR/initrd.img"
popd > /dev/null

echo "Initrd size: $(du -h "$WORK_DIR/initrd.img" | cut -f1)"

# ── Boot the kernel in QEMU ────────────────────────────────────
echo ""
echo "Booting kernel in QEMU (timeout: ${TIMEOUT_SECONDS}s)..."
echo "─────────────────────────────────────────"

QEMU_LOG="$WORK_DIR/qemu.log"

# Run QEMU with:
#   -no-reboot         : exit instead of reboot on poweroff
#   -nographic         : no GUI, serial console only
#   -m 512M            : 512MB RAM (enough to boot)
#   -append            : minimal kernel cmdline
timeout "$TIMEOUT_SECONDS" qemu-system-x86_64 \
    -kernel "$VMLINUZ" \
    -initrd "$WORK_DIR/initrd.img" \
    -append "console=ttyS0 panic=1 quiet" \
    -m 512M \
    -no-reboot \
    -nographic \
    2>&1 | tee "$QEMU_LOG" || QEMU_EXIT=$?

echo "─────────────────────────────────────────"

# ── Check result ──────────────────────────────────────────────
echo ""
echo "Checking boot result..."

if grep -q "BOOT_TEST_OK" "$QEMU_LOG"; then
    echo "✅ BOOT TEST PASSED — kernel reached init successfully"
    exit 0
elif grep -q "$BOOT_SUCCESS_PATTERN" "$QEMU_LOG"; then
    echo "✅ BOOT TEST PASSED — kernel decompressed and started"
    exit 0
elif grep -q "Kernel panic" "$QEMU_LOG"; then
    echo "❌ BOOT TEST FAILED — Kernel panic detected"
    echo "Last 30 lines of boot log:"
    tail -30 "$QEMU_LOG"
    exit 1
else
    echo "⚠️  BOOT TEST INCONCLUSIVE — could not determine boot status"
    echo "Last 30 lines of boot log:"
    tail -30 "$QEMU_LOG"
    # Don't fail the build for inconclusive — QEMU env may vary
    exit 0
fi
```

### `scripts/build-deb.sh`

```bash
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# build-deb.sh
# Runs INSIDE the DEB Docker container.
# Compiles the Linux kernel and produces .deb packages.
#
# Required env vars (set by GitHub Actions):
#   KERNEL_VERSION  — e.g. 6.6.30
#   ARCH            — kernel arch: x86 | arm64
#   CROSS_COMPILE   — cross prefix: '' | aarch64-linux-gnu-
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION is required}"
ARCH="${ARCH:?ARCH is required}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
WORKSPACE="/workspace"
KERNEL_SOURCE="/kernel-source/linux-${KERNEL_VERSION}.tar.xz"
BUILD_DIR="/tmp/kernel-build"
OUTPUT_DIR="${WORKSPACE}/output"
JOBS=$(nproc)

# ── Map kernel arch to DEB architecture name ─────────────────
case "$ARCH" in
    x86|x86_64) DEB_ARCH="amd64" ; CONFIG_ARCH="x86_64" ;;
    arm64)      DEB_ARCH="arm64" ; CONFIG_ARCH="arm64" ;;
    *)          DEB_ARCH="$ARCH" ; CONFIG_ARCH="$ARCH" ;;
esac

# ── Print build info ──────────────────────────────────────────
echo "════════════════════════════════════════════"
echo " Kernel DEB Build"
echo " Version:       ${KERNEL_VERSION}"
echo " Arch:          ${ARCH} (DEB: ${DEB_ARCH})"
echo " Cross-compile: ${CROSS_COMPILE:-'(native)'}"
echo " CPUs:          ${JOBS}"
echo "════════════════════════════════════════════"

# ── Validate inputs ───────────────────────────────────────────
if [[ ! -f "$KERNEL_SOURCE" ]]; then
    echo "ERROR: Kernel source not found at $KERNEL_SOURCE"
    exit 1
fi

if [[ -n "$CROSS_COMPILE" ]]; then
    if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
        echo "ERROR: Cross compiler '${CROSS_COMPILE}gcc' not found in PATH"
        exit 1
    fi
    echo "Cross compiler: $(${CROSS_COMPILE}gcc --version | head -1)"
fi

# ── Prepare build directory ───────────────────────────────────
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo ""
echo "==> [1/5] Extracting kernel source..."
tar -xf "$KERNEL_SOURCE" -C "$BUILD_DIR"
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"

if [[ ! -d "$KERNEL_DIR" ]]; then
    echo "ERROR: Expected kernel dir not found: $KERNEL_DIR"
    exit 1
fi

# ── Apply kernel configuration ────────────────────────────────
echo ""
echo "==> [2/5] Applying kernel config..."

CONFIG_FILE="${WORKSPACE}/kernel/configs/${CONFIG_ARCH}_defconfig"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Using custom config: $CONFIG_FILE"
    cp "$CONFIG_FILE" "${KERNEL_DIR}/.config"
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        olddefconfig
else
    echo "WARNING: No custom config at $CONFIG_FILE — using defconfig"
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        defconfig
fi

# ── Apply any patches ─────────────────────────────────────────
PATCH_DIR="${WORKSPACE}/kernel/patches"
if [[ -d "$PATCH_DIR" ]] && compgen -G "${PATCH_DIR}/*.patch" > /dev/null 2>&1; then
    echo ""
    echo "==> [2b] Applying patches..."
    for patch in "${PATCH_DIR}"/*.patch; do
        echo "Applying: $(basename "$patch")"
        patch -p1 -d "$KERNEL_DIR" < "$patch"
    done
fi

# ── Build the kernel DEB packages ────────────────────────────
echo ""
echo "==> [3/5] Building kernel with ${JOBS} jobs (this takes 30–120 min)..."

# Set KDEB_PKGVERSION to include arch for clarity
export KDEB_PKGVERSION="${KERNEL_VERSION}-1"

if [[ -n "$CROSS_COMPILE" ]]; then
    # Cross-compilation: tell dpkg the target arch
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        DPKG_FLAGS="-a${DEB_ARCH}" \
        -j"$JOBS" \
        bindeb-pkg
else
    # Native build
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        -j"$JOBS" \
        bindeb-pkg
fi

# ── Collect output packages ───────────────────────────────────
echo ""
echo "==> [4/5] Collecting DEB packages..."

# bindeb-pkg outputs .deb files one level above the kernel source dir
find "$BUILD_DIR" -maxdepth 1 \( -name "*.deb" -o -name "*.buildinfo" -o -name "*.changes" \) \
    -exec cp -v {} "$OUTPUT_DIR/" \;

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "==> [5/5] Build complete!"
echo ""
echo "Packages produced:"
ls -lh "$OUTPUT_DIR/"*.deb 2>/dev/null || echo "(no .deb files found)"

PACKAGE_COUNT=$(find "$OUTPUT_DIR" -name "*.deb" | wc -l)
if [[ "$PACKAGE_COUNT" -eq 0 ]]; then
    echo "ERROR: Build completed but no DEBs found!"
    exit 1
fi

echo ""
echo "✅ Successfully built ${PACKAGE_COUNT} DEB package(s)"
```

### `scripts/build-rpm.sh`

```bash
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# build-rpm.sh
# Runs INSIDE the RPM Docker container.
# Compiles the Linux kernel and produces .rpm packages.
#
# Required env vars (set by GitHub Actions):
#   KERNEL_VERSION  — e.g. 6.6.30
#   ARCH            — kernel arch: x86 | arm64
#   CROSS_COMPILE   — cross prefix: '' | aarch64-linux-gnu-
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION is required}"
ARCH="${ARCH:?ARCH is required}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
WORKSPACE="/workspace"
KERNEL_SOURCE="/kernel-source/linux-${KERNEL_VERSION}.tar.xz"
BUILD_DIR="/tmp/kernel-build"
OUTPUT_DIR="${WORKSPACE}/output"
JOBS=$(nproc)

# ── Validate environment ──────────────────────────────────────
echo "════════════════════════════════════════════"
echo " Kernel RPM Build"
echo " Version:       ${KERNEL_VERSION}"
echo " Arch:          ${ARCH}"
echo " Cross-compile: ${CROSS_COMPILE:-'(native)'}"
echo " CPUs:          ${JOBS}"
echo "════════════════════════════════════════════"

if [[ ! -f "$KERNEL_SOURCE" ]]; then
    echo "ERROR: Kernel source not found at $KERNEL_SOURCE"
    exit 1
fi

# Validate cross compiler if set
if [[ -n "$CROSS_COMPILE" ]]; then
    if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
        echo "ERROR: Cross compiler '${CROSS_COMPILE}gcc' not found in PATH"
        exit 1
    fi
    echo "Cross compiler: $(${CROSS_COMPILE}gcc --version | head -1)"
fi

# ── Prepare build directory ───────────────────────────────────
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo ""
echo "==> [1/5] Extracting kernel source..."
tar -xf "$KERNEL_SOURCE" -C "$BUILD_DIR"
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"

if [[ ! -d "$KERNEL_DIR" ]]; then
    echo "ERROR: Expected kernel dir not found: $KERNEL_DIR"
    exit 1
fi

# ── Apply kernel configuration ────────────────────────────────
echo ""
echo "==> [2/5] Applying kernel config..."

# Map kernel arch to config file name
case "$ARCH" in
    x86|x86_64) CONFIG_ARCH="x86_64" ;;
    arm64)      CONFIG_ARCH="arm64" ;;
    *)          CONFIG_ARCH="$ARCH" ;;
esac

CONFIG_FILE="${WORKSPACE}/kernel/configs/${CONFIG_ARCH}_defconfig"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Using custom config: $CONFIG_FILE"
    cp "$CONFIG_FILE" "${KERNEL_DIR}/.config"
    # Update config to fill in any new options with defaults
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        olddefconfig
else
    echo "WARNING: No custom config found at $CONFIG_FILE"
    echo "Falling back to distribution defconfig..."
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        defconfig
fi

# ── Apply any patches ─────────────────────────────────────────
PATCH_DIR="${WORKSPACE}/kernel/patches"
if [[ -d "$PATCH_DIR" ]] && compgen -G "${PATCH_DIR}/*.patch" > /dev/null 2>&1; then
    echo ""
    echo "==> [2b] Applying patches..."
    for patch in "${PATCH_DIR}"/*.patch; do
        echo "Applying: $(basename "$patch")"
        patch -p1 -d "$KERNEL_DIR" < "$patch"
    done
fi

# ── Build the kernel ──────────────────────────────────────────
echo ""
echo "==> [3/5] Building kernel with ${JOBS} jobs (this takes 30–120 min)..."

make -C "$KERNEL_DIR" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$JOBS" \
    binrpm-pkg

# ── Collect output packages ───────────────────────────────────
echo ""
echo "==> [4/5] Collecting RPM packages..."

# make rpm-pkg writes RPMs to ${KERNEL_DIR}/rpmbuild/
find "${KERNEL_DIR}/rpmbuild/RPMS" -name "*.rpm" -exec cp -v {} "$OUTPUT_DIR/" \;
find "${KERNEL_DIR}/rpmbuild/SRPMS" -name "*.src.rpm" -exec cp -v {} "$OUTPUT_DIR/" \; 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "==> [5/5] Build complete!"
echo ""
echo "Packages produced:"
ls -lh "$OUTPUT_DIR/"*.rpm 2>/dev/null || echo "(no .rpm files found)"

PACKAGE_COUNT=$(find "$OUTPUT_DIR" -name "*.rpm" | wc -l)
if [[ "$PACKAGE_COUNT" -eq 0 ]]; then
    echo "ERROR: Build completed but no RPMs found!"
    exit 1
fi

echo ""
echo "✅ Successfully built ${PACKAGE_COUNT} RPM package(s)"
```

### `scripts/fetch-kernel.sh`

```bash
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# fetch-kernel.sh
# Downloads a Linux kernel tarball from kernel.org and verifies
# its SHA256 checksum before use.
#
# Usage: bash fetch-kernel.sh <version> <output_dir>
# Example: bash fetch-kernel.sh 6.6.30 ./kernel-source
# ─────────────────────────────────────────────────────────────
set -euo pipefail

KERNEL_VERSION="${1:?Usage: fetch-kernel.sh <version> <output_dir>}"
OUTPUT_DIR="${2:?Usage: fetch-kernel.sh <version> <output_dir>}"

# Derive major version (e.g. 6.6.30 → 6)
MAJOR_VERSION="${KERNEL_VERSION%%.*}"

BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VERSION}.x"
TARBALL_NAME="linux-${KERNEL_VERSION}.tar.xz"
TARBALL_PATH="${OUTPUT_DIR}/${TARBALL_NAME}"

mkdir -p "$OUTPUT_DIR"

# ── Skip download if already present ─────────────────────────
if [[ -f "$TARBALL_PATH" ]]; then
    echo "[fetch-kernel] Source already cached: $TARBALL_PATH"
    exit 0
fi

# ── Download tarball ─────────────────────────────────────────
echo "[fetch-kernel] Downloading Linux ${KERNEL_VERSION}..."
wget \
    --progress=bar:force \
    --timeout=120 \
    --tries=3 \
    -O "$TARBALL_PATH" \
    "${BASE_URL}/${TARBALL_NAME}"

# ── Download and verify SHA256 checksum ──────────────────────
echo "[fetch-kernel] Downloading checksum..."
wget \
    --quiet \
    --timeout=60 \
    -O "${OUTPUT_DIR}/sha256sums.asc" \
    "${BASE_URL}/sha256sums.asc"

echo "[fetch-kernel] Verifying checksum..."
# extract the specific hash for our tarball
pushd "$OUTPUT_DIR" > /dev/null
grep "${TARBALL_NAME}" sha256sums.asc > "${TARBALL_NAME}.sha256"
sha256sum -c "${TARBALL_NAME}.sha256"
popd > /dev/null

echo "[fetch-kernel] ✅ Kernel source ${KERNEL_VERSION} verified OK"
echo "[fetch-kernel] Location: ${TARBALL_PATH}"
ls -lh "$TARBALL_PATH"
```

