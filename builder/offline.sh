#!/bin/bash

set -e

# Note that these are packages installed to the Arch container
# used to build the ISO.
pacman-key --init
pacman --noconfirm -Syu archlinux-keyring
pacman --noconfirm -Syu archiso git python-pip sudo base-devel jq

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
  tzupdate # This is technically an AUR package
)

prepare_offline_mirror() {
  # Certain packages in omarchy.packages are AUR packages.
  # These needs to be pre-built and placed in https://omarchy.blyg.se/aur/os/x86_64/
  echo "Reading and combining packages from all package files..."

  # Combine all packages from both files into one array
  all_packages=()
  for package_file in omarchy.packages archinstall.packages; do
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
    (cd $cache_dir/ && git apply /aur-mirror.patch)

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
  #
  # We'll leave some things online, like NTP as that won't
  # interfere with anything, on the flip side it will help if we do
  # have internet connectivity.

  rm "$cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
  rm -rf "$cache_dir/airootfs/etc/systemd/system/reflector.service.d"
  rm -rf "$cache_dir/airootfs/etc/xdg/reflector"
}

mkdir -p $cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r archiso/configs/releng/* $cache_dir/

prepare_offline_mirror
make_archiso_offline

# Insert the configurator in the root users home folder (default user in the official releng ISO profile).
curl -fsSL -o "airootfs/root/configurator" \
  "https://raw.githubusercontent.com/$OMARCHY_CONFIGURATOR_REPO/$OMARCHY_CONFIGURATOR_REF/configurator"

# Clone Omarchy itself
git clone -b dev --single-branch https://github.com/basecamp/omarchy.git "$cache_dir/airootfs/root/omarchy"

# We add in our auto-start applications
# First we'll check for an active internet connection
# Then we'll start the omarchy installer
cat <<-_EOF_ | tee $cache_dir/airootfs/root/.automated_script.sh
	#!/usr/bin/env bash

	if [[ \$(tty) == "/dev/tty1" ]]; then
	    sh ./check_connectivity.sh && \
	    sh ./installer && \
	    archinstall \
	    	--config user_configuration.json \
	    	--creds user_credentials.json \
	    	--silent && \
	    export OMARCHY_USER=\`ls /mnt/home/\` && \

	    mkdir -p /mnt/home/\$OMARCHY_USER/.local/share/ && \
	    cp -r /root/omarchy "/mnt/home/\$OMARCHY_USER/.local/share/" && \
	    chown -R 1000:1000 "/mnt/home/\$OMARCHY_USER/.local/" && \
	    chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install.sh && \
	    chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/apps/mimetypes.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/apps/webapps.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/apps/xtras.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/detect-keyboard-layout.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/fix-fkeys.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/network.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/nvidia.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/power.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/timezones.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/config.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/identification.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/increase-sudo-tries.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/config/login.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/asdcontrol.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/bluetooth.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/fonts.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/hyprlandia.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/printer.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/theme.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/desktop/desktop.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/development/development.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/development/nvim.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/development/ruby.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/development/docker.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/development/firewall.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/development/terminal.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/migrations.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/aur.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/guard.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/gum.sh && \
		chmod +x /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/tte.sh && \
		echo '' > /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/tte.sh && \
		echo '' > /mnt/home/\$OMARCHY_USER/.local/share/omarchy/install/preflight/gum.sh && \
	    
	    # Copy sudoers config to target system for passwordless sudo in chroot
	    mkdir -p /mnt/etc/sudoers.d && \
	    cp /etc/sudoers.d/99-omarchy-installer /mnt/etc/sudoers.d/ && \
	    echo "\$OMARCHY_USER ALL=(ALL:ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers.d/99-omarchy-installer && \
	    
	    HOME=/home/\$OMARCHY_USER arch-chroot -u \$OMARCHY_USER /mnt/ /bin/bash -c "source /home/\$OMARCHY_USER/.local/share/omarchy/install.sh"
	fi
_EOF_

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

# We have to do this, because `mkarchiso` copies in the pacman.conf
# in use during the build process - so it needs to be made offline.
(cd "$cache_dir" && git apply /offline-mirror.patch)
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
# And we have to use the hosts pacman.conf since all other pacman.conf
# files are prepped for offline use by this point.
pacman --config /etc/pacman.conf \
  --noconfirm -Syw $(echo "${iso_packages[@]}" | sed 's/tzupdate//g') \
  --cachedir "/var/cache/omarchy/mirror/offline/" \
  --dbpath /tmp/cleandb

repo-add --new "/var/cache/omarchy/mirror/offline/offline.db.tar.gz" "/var/cache/omarchy/mirror/offline/"*.pkg.tar.zst

# Finally, we assemble the entire ISO
mkarchiso -v -w "$cache_dir/work/" -o "/out/" "$cache_dir/"
