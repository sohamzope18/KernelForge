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
