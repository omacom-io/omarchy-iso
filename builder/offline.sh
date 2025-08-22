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
  impala
  gum
  openssl
  wget
  jq
  # tzupdate # Removed - this is an AUR package not available in standard repos
)

prepare_offline_mirror() {
  # Certain packages in omarchy.packages are AUR packages.
  # These needs to be pre-built and placed in https://omarchy.blyg.se/aur/os/x86_64/
  echo "Reading and combining packages from all package files..."

  # Combine all packages from both files into one array
  all_packages=()
  for package_file in /builder/packages/omarchy.packages /builder/packages/archinstall.packages; do
    if [ -f "$package_file" ]; then
      echo "Reading $package_file..."
      while IFS= read -r package; do
        # Skip empty lines and comments
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        all_packages+=("$package")
      done <"$package_file"
    fi
  done

  if [ ${#all_packages[@]} -gt 0 ]; then
    # This assume we've manually built all the AUR packages
    # and made them accessible "online" during the build process:
    (cd $cache_dir/ && git apply /builder/patches/offline/aur-mirror.patch)

    mkdir -p /tmp/offlinedb

    # Change DownloadUser from alpm to root to fix permission issues when downloading to cache dir
    # TODO: We should move the build root from /root/.cache/omarchy/ into /var/cache instead.
    #       That way alpm:alpm will have access, which is the default pacman download user now days.
    sed -i 's/^#*DownloadUser = alpm/DownloadUser = root/' /etc/pacman.conf

    # Download all the packages to the offline mirror inside the ISO
    pacman --config $cache_dir/pacman.conf \
      --noconfirm -Syw "${all_packages[@]}" \
      --cachedir $offline_mirror_dir/ \
      --dbpath /tmp/offlinedb

    # Create database in batches to avoid issues
    cd "$offline_mirror_dir"
    for pkg in *.pkg.tar.zst; do
      repo-add -q offline.db.tar.gz "$pkg"
    done

    rm "$cache_dir/airootfs/etc/pacman.d/hooks/uncomment-mirrors.hook"

    # Revert the "online" AUR patch, as we'll replace it with the proper
    # offline patched mirror for the ISO later.
    (cd $cache_dir && git apply -R /builder/patches/offline/aur-mirror.patch)
  fi
}

make_archiso_offline() {
  # This function will simply disable any online activity we have.
  # for instance the reflector.service which tries to optimize
  # mirror order by fetching the latest mirror list by default.
  #
  # We'll leave some things online, like NTP as that won't
  # interfere with anything, on the flip side it will help if we do
  # have internet connectivity.

  rm -f "$cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
  rm -rf "$cache_dir/airootfs/etc/systemd/system/reflector.service.d"
  rm -rf "$cache_dir/airootfs/etc/xdg/reflector"
}

mkdir -p $cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r archiso/configs/releng/* $cache_dir/

# Skip offline mirror for minimal build - focus on git repos only
# prepare_offline_mirror
make_archiso_offline

# Skip installer download for now (404 error on GitHub)
# TODO: Fix installer URL once repository is available
touch "$cache_dir/airootfs/root/installer"
chmod +x "$cache_dir/airootfs/root/installer"

# Clone Omarchy itself
git clone -b dev --single-branch https://github.com/basecamp/omarchy.git "$cache_dir/airootfs/root/omarchy"

# Apply offline yay patch to Omarchy installation
echo "Applying offline yay patch to Omarchy..."
(cd "$cache_dir/airootfs/root/omarchy" && git apply /builder/patches/offline/aur-offline.patch)

# Clone repositories for offline availability
echo "Cloning repositories for offline installation..."
mkdir -p "$cache_dir/airootfs/var/cache/omarchy/repos"

# Clone asdcontrol for Apple Display brightness control
git clone --depth=1 https://github.com/nikosdion/asdcontrol.git \
  "$cache_dir/airootfs/var/cache/omarchy/repos/asdcontrol"

# Clone LazyVim starter for Neovim configuration
git clone --depth=1 https://github.com/LazyVim/starter.git \
  "$cache_dir/airootfs/var/cache/omarchy/repos/lazyvim-starter"

# Add offline yay binary for installation without network
echo "Adding offline yay binary for network-free installation..."
mkdir -p "$cache_dir/airootfs/var/cache/omarchy/packages"
cp /builder/offline-assets/yay_12.4.2_x86_64/yay \
  "$cache_dir/airootfs/var/cache/omarchy/packages/yay"
chmod +x "$cache_dir/airootfs/var/cache/omarchy/packages/yay"

# Use the autostart-offline.sh script which includes git wrapper logic
cp /builder/cmds/autostart-offline.sh $cache_dir/airootfs/root/.automated_script.sh

# We patch permissions, grub and efi loaders to our liking:
(cd $cache_dir/ && git apply /builder/patches/offline/permissions.patch)
(cd $cache_dir/ && git apply /builder/patches/grub-autoboot.patch)
(cd $cache_dir/ && git apply /builder/patches/efi-autoboot.patch)
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

# Skip offline mirror configuration for minimal build
# (cd "$cache_dir" && git apply /builder/patches/offline/offline-mirror.patch)
# cp $cache_dir/pacman.conf "$cache_dir/airootfs/etc/pacman.conf"

# Skip offline mirror duplication
# mkdir -p /var/cache/omarchy/mirror
# cp -r "$offline_mirror_dir" "/var/cache/omarchy/mirror/"

# Because this weird glitch with archiso, we also need to sync down
# all the packages we need to build the ISO, but we'll do that in the
# "host" mirror location, as we don't want them inside the ISO taking up space.
# We'll also remove tzupdate as it won't be found in upstream mirrors.
iso_packages=($(cat "$cache_dir/packages.x86_64"))

mkdir -p /tmp/cleandb

# Skip package download and database creation for minimal build
# pacman --config /etc/pacman.conf \
#   --noconfirm -Syw $(echo "${iso_packages[@]}" | sed 's/tzupdate//g') \
#   --cachedir "/var/cache/omarchy/mirror/offline/" \
#   --dbpath /tmp/cleandb

# repo-add --new "/var/cache/omarchy/mirror/offline/offline.db.tar.gz" "/var/cache/omarchy/mirror/offline/"*.pkg.tar.zst

# Finally, we assemble the entire ISO
mkarchiso -v -w "$cache_dir/work/" -o "/out/" "$cache_dir/"
