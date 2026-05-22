#!/bin/bash
# Build omarchy + companion omarchy packages from mounted source
# (/omarchy-installer + /omarchy-pkgs) and drop the .pkg.tar.zst
# files into the offline-mirror directory passed as $1.
#
# Run inside the ISO build container (build-iso.sh sources this).

set -e

offline_mirror_dir="$1"
if [[ -z $offline_mirror_dir ]]; then
  echo "Usage: build-omarchy-packages.sh <offline-mirror-dir>" >&2
  exit 1
fi

if [[ ! -d /omarchy-installer ]]; then
  echo "ERROR: /omarchy-installer not mounted (pass --local-source or set OMARCHY_INSTALLER_PATH)" >&2
  exit 1
fi
if [[ ! -d /omarchy-pkgs ]]; then
  echo "ERROR: /omarchy-pkgs not mounted (set OMARCHY_PKGS_PATH or place ../omarchy-pkgs)" >&2
  exit 1
fi

work_dir=/tmp/omarchy-pkg-build
rm -rf "$work_dir"
mkdir -p "$work_dir"

# makepkg refuses to run as root; create a builder user with passwordless
# sudo for pacman dep installation during the build, and hand it ownership
# of the work dir so PKGDEST writes succeed.
if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-omarchy-pkg-builder
chmod 440 /etc/sudoers.d/99-omarchy-pkg-builder
chown builder:builder "$work_dir"

pacman -Sy --noconfirm

# Order matters: omarchy depends on omarchy-settings/-installer which depend on
# the base packages; omarchy-installer depends on the others. Build leaves
# first so dependents can pacman -S them from /tmp once needed. We don't
# actually install during the build, so the order is mostly cosmetic — but
# keeping it stable helps logs.
packages=(
  omarchy-limine
  omarchy-settings
  omarchy
  omarchy-installer
  omarchy-nvim
)

for pkg in "${packages[@]}"; do
  echo "----------------------------------------"
  echo "Building $pkg"
  echo "----------------------------------------"
  pkg_work="$work_dir/$pkg"
  cp -a "/omarchy-pkgs/pkgbuilds/$pkg" "$pkg_work"
  chown -R builder:builder "$pkg_work"

  # --nodeps: don't install deps into the build container. We just need to
  # produce the .pkg.tar.zst; pacman resolves runtime deps at install time on
  # the target system from the offline mirror.
  su builder -c "
    cd '$pkg_work' &&
    PKGDEST='$work_dir' \
    OMARCHY_SRC=/omarchy-installer \
    makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f
  "
done

mkdir -p "$offline_mirror_dir"
mv "$work_dir"/*.pkg.tar.zst "$offline_mirror_dir/"

echo
echo "Built omarchy packages, placed in $offline_mirror_dir:"
ls "$offline_mirror_dir"/omarchy*.pkg.tar.zst | sed 's|^|  |'
