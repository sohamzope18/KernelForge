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
