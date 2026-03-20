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
