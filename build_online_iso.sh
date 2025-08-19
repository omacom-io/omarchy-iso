#!/bin/bash

set -e

# Note that these are packages installed to the Arch container
# used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git python-pip sudo base-devel jq wget

cache_dir=$(realpath --canonicalize-missing ~/.cache/omarchy/iso_$(date +%Y-%m-%d))
offline_mirror_dir="$cache_dir/airootfs/var/cache/omarchy/mirror/offline"

# We need to fiddle with pip settings
# in order to install to the correct place
# as well as ignore some errors to make this less verbose
export PIP_ROOT="$cache_dir/airootfs/"
export PIP_ROOT_USER_ACTION="ignore"
export PIP_NO_WARN_SCRIPT_LOCATION=1
export PIP_BREAK_SYSTEM_PACKAGES=1

# These packages will be installed **into** the ISO, and
# won't be available to either archinstall or omarchy installer.
python_packages=(
  terminaltexteffects
)
arch_packages=(
  git
  gum
  openssl
  wget
)

mkdir -p $cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r archiso/configs/releng/* $cache_dir/

# We clone the installer, and move it to the root users home folder
# since this is the default user in the official releng ISO profile.
git clone https://github.com/omacom-io/omarchy-installer "$cache_dir/airootfs/root/omarchy-installer"
mv "$cache_dir/airootfs/root/omarchy-installer/installer" "$cache_dir/airootfs/root/installer"
mv "$cache_dir/airootfs/root/omarchy-installer/logo.txt" "$cache_dir/airootfs/root/logo.txt"
rm -rf "$cache_dir/airootfs/root/omarchy-installer"

# Copy in the connectivity check script
cp /check_connectivity.sh "$cache_dir/airootfs/root/check_connectivity.sh"

# Configure sudoers for passwordless installation
# This allows the installer to run without password prompts
mkdir -p $cache_dir/airootfs/etc/sudoers.d/
echo "# Omarchy ISO - Allow passwordless sudo during installation" >>"$cache_dir/airootfs/etc/sudoers.d/99-omarchy-installer"
echo "root ALL=(ALL:ALL) NOPASSWD: ALL" >>"$cache_dir/airootfs/etc/sudoers.d/99-omarchy-installer"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >>"$cache_dir/airootfs/etc/sudoers.d/99-omarchy-installer"

# We add in our auto-start applications
# First we'll check for an active internet connection
# Then we'll start the omarchy installer
cat <<-'_EOF_' | tee "$cache_dir/airootfs/root/.automated_script.sh"
	#!/usr/bin/env bash
  set -euo pipefail

	if [[ $(tty) == "/dev/tty1" ]]; then
	    sh ./check_connectivity.sh
	    sh ./installer

	    archinstall \
	    	--config user_configuration.json \
	    	--creds user_credentials.json \
	    	--silent

      OMARCHY_USER="$(ls -1 /mnt/home | head -n1)"

      # Copy sudoers config to target system for passwordless sudo in chroot
	    mkdir -p /mnt/etc/sudoers.d
	    cp /etc/sudoers.d/99-omarchy-installer /mnt/etc/sudoers.d/

	    HOME=/home/$OMARCHY_USER \
      arch-chroot -u $OMARCHY_USER /mnt/ \
        env OMARCHY_USER_NAME="$(<user_full_name.txt)" \
            OMARCHY_USER_EMAIL="$(<user_email_address.txt)" \
        /bin/bash -lc "wget -qO- https://omarchy.org/install-dev | bash"
	fi
_EOF_

# We patch permissions, grub and efi loaders to our liking:
(cd $cache_dir/ && git apply /permissions.patch)
(cd $cache_dir/ && git apply /grub-autoboot.patch)
(cd $cache_dir/ && git apply /efi-autoboot.patch)
# We could also use:
# patch -p1 < aur-mirror.patch
# patch -p1 < permissions.patch
# patch -p1 < grub-autoboot.patch
# patch -p1 < efi-autoboot.patch

# Remove the default motd
rm "$cache_dir/airootfs/etc/motd"

# Install Python packages for the installer into the ISO
# file system.
pip install "${python_packages[@]}"

# Add our needed packages to packages.x86_64
printf '%s\n' "${arch_packages[@]}" >>"$cache_dir/packages.x86_64"

# Because this weird glitch with archiso, we also need to sync down
# all the packages we need to build the ISO, but we'll do that in the
# "host" mirror location, as we don't want them inside the ISO taking up space.
# We'll also remove tzupdate as it won't be found in upstream mirrors.
iso_packages=($(cat "$cache_dir/packages.x86_64"))

mkdir -p /tmp/cleandb

# Finally, we assemble the entire ISO
mkarchiso -v -w "$cache_dir/work/" -o "/out/" "$cache_dir/"
