#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Install omarchy-keyring for package verification during build
# The [omarchy] repo is defined in /configs/pacman-online.conf with SigLevel = Optional TrustAll
pacman --config /configs/pacman-online.conf --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

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

# Build omarchy-settings package locally
# This package provides EVERYTHING needed for the ISO:
# - User configs (/etc/skel/)
# - System configs (/etc/)
# - Plymouth theme
# - Essential binaries (debug, upload-log)
# - Install scripts (/usr/share/omarchy/install/)
if [ -d "/omarchy-pkgs" ]; then
  echo "========================================="
  echo "Building omarchy-settings package locally"
  echo "========================================="
  source /builder/build-omarchy-packages.sh
  
  # Add omarchy packages to ISO
  # omarchy-settings provides configs and will be installed in ISO
  # omarchy-installer provides install scripts and will be installed in ISO
  echo "omarchy-settings" >> "$build_cache_dir/packages.x86_64"
  echo "omarchy-installer" >> "$build_cache_dir/packages.x86_64"
  
  # Copy built packages to offline mirror (for installation on target system)
  cp "$OMARCHY_SETTINGS_PKG" "$offline_mirror_dir/"
  cp "$OMARCHY_INSTALLER_PKG" "$offline_mirror_dir/"
  cp "$OMARCHY_PKG" "$offline_mirror_dir/"
  
  echo "✓ omarchy-settings will be installed in ISO (configs, binaries)"
  echo "✓ omarchy-installer will be installed in ISO (install scripts, helpers)"
  echo "✓ All omarchy packages available in offline mirror for installation"
  echo "✓ No git clone needed - everything comes from packages!"
else
  echo "ERROR: /omarchy-pkgs not mounted!"
  echo "The ISO build now requires omarchy-settings package."
  echo "Please set OMARCHY_PKGS_PATH or ensure ../omarchy-pkgs exists."
  exit 1
fi

# Download and verify Node.js binary for offline installation
NODE_DIST_URL="https://nodejs.org/dist/latest"

# Get checksums and parse filename and SHA
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')

# Download the tarball
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"

# Verify SHA256 checksum
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c - || {
    echo "ERROR: Node.js checksum verification failed!"
    exit 1
}

# Copy to ISO
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Add our additional packages to packages.x86_64
arch_packages=(linux-t2 git gum jq openssl plymouth tzupdate omarchy-keyring python-terminaltexteffects)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build list of all the packages needed for the offline mirror
# Start with packages.x86_64 but exclude locally-built packages
all_packages=($(cat "$build_cache_dir/packages.x86_64" | grep -vE '^(omarchy|omarchy-settings|omarchy-installer)$'))

# Add omarchy package lists from source, excluding locally-built packages
if [ -n "$OMARCHY_INSTALLER_SRC" ] && [ -d "$OMARCHY_INSTALLER_SRC" ]; then
  # Filter out locally-built packages and known problematic packages
  all_packages+=($(grep -v '^#' "$OMARCHY_INSTALLER_SRC/install/omarchy-base.packages" | grep -v '^$' | grep -vE '^(omarchy|omarchy-settings|omarchy-installer)$'))
  all_packages+=($(grep -v '^#' "$OMARCHY_INSTALLER_SRC/install/omarchy-other.packages" | grep -v '^$' | grep -vE '^qt5-remoteobjects$'))
else
  echo "WARNING: Could not find omarchy package lists, offline mirror may be incomplete"
fi

all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$' | grep -vE '^(omarchy|omarchy-settings|omarchy-installer)$'))

# Remove duplicates
all_packages=($(printf '%s\n' "${all_packages[@]}" | sort -u))

# Download all the packages to the offline mirror inside the ISO
# Use --needed to skip packages that are already in cache
# Use --noconfirm to avoid interactive prompts
mkdir -p /tmp/offlinedb
echo "Downloading ${#all_packages[@]} packages to offline mirror..."
pacman --config /configs/pacman-online.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb --needed

# Build repository database for the offline mirror
# First, create the database from all downloaded packages
echo "Building offline repository database..."
repo-add "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Note: Our locally built packages (omarchy, omarchy-settings) were copied earlier
# and are now included in the repository database

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omarchy/mirror/offline
mkdir -p /var/cache/omarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/omarchy/mirror/offline"

# Copy the pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted
cp $build_cache_dir/pacman.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Create missing device-mapper udev rules file to silence mkinitcpio warning
# This file was removed in recent device-mapper versions but mkinitcpio still references it
mkdir -p /usr/lib/initcpio/udev
touch /usr/lib/initcpio/udev/11-dm-initramfs.rules

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
