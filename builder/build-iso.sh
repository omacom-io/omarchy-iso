#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub curl tar

# Import and locally sign third-party repository keys required during build
# (Chaotic AUR)
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
pacman-key --lsign-key 3056513887B78AEB

# Install chaotic-keyring and chaotic-mirrorlist so the chaotic-aur repository can be used non-interactively.
pacman -U --noconfirm \
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

# Install CachyOS repository for optimized packages
curl https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz && cd cachyos-repo
yes | ./cachyos-repo.sh
cd ..
rm -rf cachyos-repo cachyos-repo.tar.xz

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

# Ensure chaotic-mirrorlist is available inside the airootfs so pacman configuration
# in the live environment has the file present (some hooks expect it).
if [ -f /etc/pacman.d/chaotic-mirrorlist ]; then
  mkdir -p "$build_cache_dir/airootfs/etc/pacman.d"
  cp /etc/pacman.d/chaotic-mirrorlist "$build_cache_dir/airootfs/etc/pacman.d/chaotic-mirrorlist"
fi

# Some initcpio udev rule files may be provided by packages that are not present
# in the build airootfs. mkinitcpio will error if '/usr/lib/initcpio/udev/11-dm-initramfs.rules'
# is missing. Create a minimal placeholder inside the airootfs to avoid the error.
udev_rule_path="$build_cache_dir/airootfs/usr/lib/initcpio/udev/11-dm-initramfs.rules"
if [ ! -f "$udev_rule_path" ]; then
  mkdir -p "$(dirname "$udev_rule_path")"
  cat > "$udev_rule_path" <<'EOF'
# Placeholder 11-dm-initramfs.rules for ISO build environment.
# The real file is provided by appropriate packages on a normal system.
# This placeholder prevents mkinitcpio from failing when building the initramfs
# inside a minimal airootfs during ISO assembly.
KERNEL=="dm-*", ACTION=="add", RUN+="/bin/true"
EOF
fi

# Normalize kernel references in copied configs to generic 'linux' names so builds won't fail
# if 'linux-t2' is not available in the build repositories.
# This replaces occurrences like vmlinuz-linux-t2 -> vmlinuz-linux and initramfs-linux-t2.img -> initramfs-linux.img
find "$build_cache_dir" -type f -exec sed -i 's/linux-t2/linux/g' {} + || true

# Clone Omarchy itself
git clone -b $OMARCHY_INSTALLER_REF https://github.com/$OMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omarchy"

# After cloning, filter omarchy package lists to remove packages that are not available
# in the configured online repos. This prevents pacman from aborting the build when a
# package (e.g., AUR-only or repo-specific) cannot be found.
OMARCHY_DIR="$build_cache_dir/airootfs/root/omarchy"
MISSING_OMARCHY_PKGS="$build_cache_dir/missing_omarchy_packages.txt"
: > "$MISSING_OMARCHY_PKGS"

for LIST_REL in "install/omarchy-base.packages" "install/omarchy-other.packages"; do
  SRC="$OMARCHY_DIR/$LIST_REL"
  if [ -f "$SRC" ]; then
    TMP="$SRC.filtered"
    : > "$TMP"
    while IFS= read -r line || [ -n "$line" ]; do
      # Preserve comments and empty lines
      # Trim whitespace from the line (preserve comments/empty lines). Use correct quoting so
      # the value of $line is passed to printf rather than the literal \"$line\".
      trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      case "$trimmed" in
        ""|\#*)
          echo "$line" >> "$TMP"
          ;;
        *)
          pkg="$trimmed"
          # Check availability in the configured repos used during build
          if pacman --config /configs/pacman-online.conf -Si "$pkg" >/dev/null 2>&1; then
            echo "$pkg" >> "$TMP"
          else
            echo "# SKIPPED: $pkg (not in configured repos)" >> "$TMP"
            echo "$pkg" >> "$MISSING_OMARCHY_PKGS"
          fi
          ;;
      esac
    done < "$SRC"
    # Replace original list with filtered version
    mv "$TMP" "$SRC"
  fi
done

if [ -s "$MISSING_OMARCHY_PKGS" ]; then
  echo "WARNING: The following omarchy packages were not found in configured repos and were skipped:" >&2
  sed 's/^/- /' "$MISSING_OMARCHY_PKGS" >&2
  echo "See $MISSING_OMARCHY_PKGS for details." >&2
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omarchy/bin/omarchy-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omarchy-upload-log"

# Copy the Omarchy Plymouth theme to the ISO
mkdir -p "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy"
cp -r "$build_cache_dir/airootfs/root/omarchy/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy/"

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
# Include explicit provider packages to avoid interactive provider selection prompts
# - cargo is provided by `rust`
# - libreoffice provider: prefer `libreoffice-fresh`
# - man provider: prefer `man-db`
# Force using the generic 'linux' kernel package to avoid failures when 'linux-t2'
# is not available in configured repositories.
kernel_pkg="linux"
arch_packages=("$kernel_pkg" git gum jq openssl plymouth tzupdate omarchy-keyring rust libreoffice-fresh man-db)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.x86_64"))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$'))

# Prefetch explicit provider packages so pacman won't prompt during the full download.
# - cargo provider: prefer `rust`
# - libreoffice provider: prefer `libreoffice-fresh`
# - man provider: prefer `man-db`
mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online.conf --noconfirm -Syw rust libreoffice-fresh man-db --cachedir $offline_mirror_dir --dbpath /tmp/offlinedb

# Download all the packages to the offline mirror inside the ISO
# Attempt each package individually so missing packages won't abort the whole download.
# Missing packages will be recorded in $build_cache_dir/missing.packages and skipped.
missing_file="$build_cache_dir/missing.packages"
: > "$missing_file"

for pkg in "${all_packages[@]}"; do
  printf 'Checking availability of %s...\n' "$pkg"
  # Check if the package exists in the configured repos
  if pacman --config /configs/pacman-online.conf -Si "$pkg" >/dev/null 2>&1; then
    printf 'Downloading %s...\n' "$pkg"
    if ! pacman --config /configs/pacman-online.conf --noconfirm -Sw "$pkg" --cachedir "$offline_mirror_dir" --dbpath /tmp/offlinedb; then
      printf 'Failed to download %s — recording and continuing.\n' "$pkg"
      echo "$pkg" >> "$missing_file"
    fi
  else
    printf 'MISSING: %s — not in configured repos, skipping.\n' "$pkg"
    echo "$pkg" >> "$missing_file"
  fi
done

if [ -s "$missing_file" ]; then
  printf 'Warning: some packages were not found and were skipped. See %s\n' "$missing_file"
fi

# Rebuild the offline repo from whatever packages were successfully downloaded
# Only run repo-add if we actually downloaded package files. If the glob doesn't match any
# files, the pattern would be left unexpanded which can cause repo-add to fail.
pkg_files=( "$offline_mirror_dir/"*.pkg.tar.zst )
if [ -e "${pkg_files[0]}" ]; then
  repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "${pkg_files[@]}"
else
  echo "No packages downloaded to $offline_mirror_dir — skipping repo-add"
fi

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

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
