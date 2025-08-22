#!/bin/bash
set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring archiso sudo base-devel wget git

# Packages needed for the Omarchy configurator (installer will fetch its own)
arch_packages=(git wget gum openssl iw jq)

# We build our iso here
cache_dir=$(realpath --canonicalize-missing ~/.cache/omarchy/iso_$(date +%Y-%m-%d))
mkdir -p $cache_dir
cd $cache_dir

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* .

# Add our needed packages to packages.x86_64
printf '%s\n' "${arch_packages[@]}" >>"packages.x86_64"

# Retrieve the latest configurator for setting up user and selecting install disk.
wget -qO "airootfs/root/configurator" \
  https://raw.githubusercontent.com/$OMARCHY_CONFIGURATOR_REPO/$OMARCHY_CONFIGURATOR_REF/configurator

echo "$OMARCHY_INSTALLER_REPO" >airootfs/root/omarchy_installer_repo.txt
echo "$OMARCHY_INSTALLER_REF" >airootfs/root/omarchy_installer_ref.txt
echo "$OMARCHY_BARE" >airootfs/root/omarchy_bare.txt

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm "airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "airootfs/etc/systemd/system/reflector.service.d"
rm -rf "airootfs/etc/xdg/reflector"

# Ensure the Omarchy installer launches automatically on boot
cp /builder/cmds/autostart.sh airootfs/root/.automated_script.sh

# Patch the default archiso install files
for patch in /builder/patches/*.patch; do
  git apply "$patch"
done

# Remove the default motd
rm airootfs/etc/motd

# Finally, we assemble the entire ISO
mkarchiso -v -w "$cache_dir/work/" -o "/out/" "$cache_dir/"
