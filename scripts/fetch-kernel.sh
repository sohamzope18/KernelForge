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
    -O "${TARBALL_PATH}.sha256" \
    "${BASE_URL}/${TARBALL_NAME}.sha256"

echo "[fetch-kernel] Verifying checksum..."
# sha256 file has format: <hash>  <filename>
# We strip the path so sha256sum -c works from the output dir
pushd "$OUTPUT_DIR" > /dev/null
sha256sum -c "${TARBALL_NAME}.sha256"
popd > /dev/null

echo "[fetch-kernel] ✅ Kernel source ${KERNEL_VERSION} verified OK"
echo "[fetch-kernel] Location: ${TARBALL_PATH}"
ls -lh "$TARBALL_PATH"
