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
