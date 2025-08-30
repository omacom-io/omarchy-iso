#!/bin/bash

set -e

# Note that these are packages installed to the Arch container
# used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git python-pip sudo base-devel jq

# Use the date from the host if provided (to avoid timezone mismatches), otherwise use container date
if [ -n "$ISO_BUILD_DATE" ]; then
  cache_dir=$(realpath --canonicalize-missing ~/.cache/omarchy/iso_${ISO_BUILD_DATE})
else
  cache_dir=$(realpath --canonicalize-missing ~/.cache/omarchy/iso_$(date +%Y-%m-%d))
fi
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
  jq
  openssl
  tzupdate # This is technically an AUR package
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
    echo "Downloading all packages (including AUR) to offline mirror: ${all_packages[@]}"
    pacman --config $cache_dir/pacman.conf \
      --noconfirm -Syw "${all_packages[@]}" \
      --cachedir $offline_mirror_dir/ \
      --dbpath /tmp/offlinedb

    repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

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

  # Disable reflector
  rm "$cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
  rm -rf "$cache_dir/airootfs/etc/systemd/system/reflector.service.d"
  rm -rf "$cache_dir/airootfs/etc/xdg/reflector"
}

mkdir -p $cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r archiso/configs/releng/* $cache_dir/

# Apply all the general patches early (same as online.sh)
# Need to do this from the cache_dir
cd $cache_dir
for patch in /builder/patches/*.patch; do
  # Skip profiledef.patch as it conflicts with offline/permissions.patch
  if [[ "$(basename "$patch")" != "profiledef.patch" ]]; then
    git apply "$patch"
  fi
done
cd -

prepare_offline_mirror
make_archiso_offline

# Insert the configurator in the root users home folder (default user in the official releng ISO profile).
mkdir -p "$cache_dir/airootfs/root"
curl -fsSL -o "$cache_dir/airootfs/root/configurator" \
  "https://raw.githubusercontent.com/$OMARCHY_CONFIGURATOR_REPO/$OMARCHY_CONFIGURATOR_REF/configurator"

# Clone Omarchy itself
git clone -b $OMARCHY_INSTALLER_REF --single-branch https://github.com/$OMARCHY_INSTALLER_REPO.git "$cache_dir/airootfs/root/omarchy"

# Copy the autostart script (we'll need to create an offline version)
cp /builder/cmds/autostart-offline.sh $cache_dir/airootfs/root/.automated_script.sh

# Apply offline-specific patches
(cd $cache_dir/ && git apply /builder/patches/offline/permissions.patch)

# Remove the default motd
rm "$cache_dir/airootfs/etc/motd"

# Ensure pacman cache directory exists with proper permissions
mkdir -p "$cache_dir/airootfs/var/cache/pacman/pkg"
chmod 755 "$cache_dir/airootfs/var/cache/pacman/pkg"

# Install Python packages for the installer into the ISO
# file system.
pip install "${python_packages[@]}"

# Add our needed packages to packages.x86_64
printf '%s\n' "${arch_packages[@]}" >>"$cache_dir/packages.x86_64"

# We have to do this, because `mkarchiso` copies in the pacman.conf
# in use during the build process - so it needs to be made offline.
(cd "$cache_dir" && git apply /builder/patches/offline/offline-mirror.patch)
cp $cache_dir/pacman.conf "$cache_dir/airootfs/etc/pacman.conf"

# And we also need to duplicate the offline mirror.
# Because inside the ISO it will look for packages in /var/cache/omarchy/mirror/offline
# but that means the build of the ISO itself will also look at this location
# but in the container.
mkdir -p /var/cache/omarchy/mirror
cp -r "$offline_mirror_dir" "/var/cache/omarchy/mirror/"

# Because this weird glitch with archiso, we also need to sync down
# all the packages we need to build the ISO, but we'll do that in the
# "host" mirror location, as we don't want them inside the ISO taking up space.
# We'll also remove tzupdate as it won't be found in upstream mirrors.
iso_packages=($(cat "$cache_dir/packages.x86_64"))

mkdir -p /tmp/cleandb

echo "Populating host offline mirror with ISO packages: ${iso_packages[@]}"
# We need to exclude AUR packages like tzupdate since they're not in upstream repos
# They should already be downloaded to the offline mirror from the earlier step
pacman --config /etc/pacman.conf \
  --noconfirm -Syw $(echo "${iso_packages[@]}" | sed 's/tzupdate//g') \
  --cachedir "/var/cache/omarchy/mirror/offline/" \
  --dbpath /tmp/cleandb

repo-add --new "/var/cache/omarchy/mirror/offline/offline.db.tar.gz" "/var/cache/omarchy/mirror/offline/"*.pkg.tar.zst

# Finally, we assemble the entire ISO
mkarchiso -v -w "$cache_dir/work/" -o "/out/" "$cache_dir/"
