#!/bin/bash

set -e

build_zfs_git_packages() {
    local output_dir="$1"
    local build_dir="/tmp/omarchy-zfs-git"
    local build_user="omarchy-zfs-build"
    local zfs_ref="${OMARCHY_ZFS_GIT_REF:-0a59f7845c2863b5370bfa38e4d397ba3d73b62a}"
    local pkg

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    if ! id -u "$build_user" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$build_user"
    fi
    chown -R "$build_user:$build_user" "$build_dir"
    cat >"/etc/sudoers.d/$build_user" <<EOF
$build_user ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    chmod 440 "/etc/sudoers.d/$build_user"

    for pkg in zfs-utils-git zfs-dkms-git; do
        sudo -u "$build_user" git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$build_dir/$pkg"
        sed -i "s|git+https://github.com/openzfs/zfs.git|git+https://github.com/openzfs/zfs.git#commit=$zfs_ref|" "$build_dir/$pkg/PKGBUILD"
        chown -R "$build_user:$build_user" "$build_dir/$pkg"
    done

    sudo -u "$build_user" bash -lc "cd '$build_dir/zfs-utils-git' && MAKEFLAGS='-j$(nproc)' makepkg --noconfirm --syncdeps --needed"
    pacman -U --noconfirm "$build_dir"/zfs-utils-git/zfs-utils-git-[0-9]*.pkg.tar.zst
    sudo -u "$build_user" bash -lc "cd '$build_dir/zfs-dkms-git' && MAKEFLAGS='-j$(nproc)' makepkg --noconfirm --syncdeps --needed"

    rm -f "$output_dir"/zfs-*.pkg.tar*
    cp "$build_dir"/zfs-utils-git/zfs-utils-git-[0-9]*.pkg.tar.zst "$output_dir/"
    cp "$build_dir"/zfs-dkms-git/zfs-dkms-git-[0-9]*.pkg.tar.zst "$output_dir/"
}

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Pre-import the omarchy signing key so pacman can verify packages without a keyserver lookup
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# Install omarchy-keyring for package verification during build
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Sy omarchy-keyring
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
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs
cp -r /configs/* $build_cache_dir/

# Persist OMARCHY_MIRROR so it's available at install time
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"

# Setup Omarchy itself
if [[ -d /omarchy ]]; then
  cp -rp /omarchy "$build_cache_dir/airootfs/root/omarchy"
else
  git clone -b $OMARCHY_INSTALLER_REF https://github.com/$OMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omarchy"
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
zfs_git_packages=(zfs-utils-git zfs-dkms-git)
arch_packages=(linux-headers linux-t2 linux-t2-headers git gum jq openssl plymouth tzupdate omarchy-keyring lvm2 cryptsetup parted "${zfs_git_packages[@]}")
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build list of all the packages needed for the offline mirror
all_packages=($(grep -vxF -e zfs-utils-git -e zfs-dkms-git "$build_cache_dir/packages.x86_64"))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$'))
all_packages=($(printf '%s\n' "${all_packages[@]}" | grep -vxF -e zfs-utils-git -e zfs-dkms-git))

# OpenZFS 2.4.1 from ArchZFS currently supports kernels only through 6.19,
# while Omarchy tracks newer Arch kernels. Build pinned git packages instead
# of changing the ISO or installed kernel.
build_zfs_git_packages "$offline_mirror_dir"

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
repo-add "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omarchy/mirror/offline
mkdir -p /var/cache/omarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/omarchy/mirror/offline"

# Copy the offline pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted. 
cp $build_cache_dir/pacman-offline.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
