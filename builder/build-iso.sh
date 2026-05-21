#!/bin/bash

set -e

# Packages installed into the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Pre-import the omarchy signing key (so pacman trusts our [omarchy] repo
# during the build without keyserver lookups).
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# omarchy-keyring is needed inside the offline mirror too.
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Build locations
build_cache_dir=/var/cache
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p "$build_cache_dir" "$offline_mirror_dir"

# Seed from the official Arch releng profile.
cp -r /archiso/configs/releng/* "$build_cache_dir/"
rm "$build_cache_dir/airootfs/etc/motd"

# We rely on the global CDN; drop reflector.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our archiso profile additions.
cp -r /configs/* "$build_cache_dir/"
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"

# Build omarchy* packages from the mounted source trees and drop them in the
# offline mirror. The .automated_script.sh later pacstraps omarchy-installer
# (which deps-in omarchy + omarchy-settings + omarchy-limine) from there.
bash /builder/build-omarchy-packages.sh "$offline_mirror_dir"

# Node.js binary for offline mise install.
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c -
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Packages installed into the live ISO environment itself (NOT the target system).
arch_packages=(linux-t2 git gum jq openssl plymouth tzupdate omarchy-keyring lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >> "$build_cache_dir/packages.x86_64"

# Build the offline mirror: everything pacstrap might want during the target
# install. The omarchy* packages we just built are already in the mirror;
# this pacman -Syw downloads the rest from the live network mirror.
declare -a all_packages
mapfile -t all_packages < <(
  {
    cat "$build_cache_dir/packages.x86_64"
    grep -hv '^#\|^$' /omarchy-installer/install/omarchy-base.packages /omarchy-installer/install/omarchy-other.packages
    grep -hv '^#\|^$' /builder/archinstall.packages
  } |
  # Filter out our locally-built packages (they're already in the mirror).
  grep -vE '^(omarchy|omarchy-settings|omarchy-installer|omarchy-limine)$' |
  sort -u
)

mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Syw \
  "${all_packages[@]}" --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb --needed

repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# mkarchiso expects the mirror at /var/cache/omarchy/mirror/offline inside the
# container (the airootfs path); symlink rather than duplicate.
mkdir -p /var/cache/omarchy/mirror
ln -sf "$offline_mirror_dir" /var/cache/omarchy/mirror/offline

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO.
mkarchiso -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
