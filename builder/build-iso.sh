#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs
cp -r /configs/* $build_cache_dir/

# Clone Omarchy itself
git clone -b $OMARCHY_INSTALLER_REF https://github.com/$OMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omarchy"

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omarchy/bin/omarchy-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omarchy-upload-log"

# Copy the Omarchy Plymouth theme to the ISO
mkdir -p "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy"
cp -r "$build_cache_dir/airootfs/root/omarchy/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy/"

# Add our additional packages to packages.x86_64
arch_packages=(linux-t2 git gum jq openssl plymouth tzupdate)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.x86_64"))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$'))

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omarchy/mirror/offline
mkdir -p /var/cache/omarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/omarchy/mirror/offline"

# Copy the pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted
cp $build_cache_dir/pacman.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"
