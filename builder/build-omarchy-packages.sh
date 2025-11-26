#!/bin/bash
# Build omarchy packages locally for ISO integration
# This runs inside the Docker container during ISO build

set -e

echo "========================================="
echo "Building omarchy-settings package locally"
echo "========================================="

# Packages will be built in /tmp/omarchy-pkg-build
BUILD_DIR="/tmp/omarchy-pkg-build"
# Clean old builds to avoid checksum issues
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Create a writable build directory
WORK_DIR="/tmp/omarchy-pkg-work"
# Clean old work directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Copy package files to writable location
echo "Setting up build directory..."
cp -r /omarchy-pkgs/pkgbuilds/omarchy-settings "$WORK_DIR/"
cd "$WORK_DIR/omarchy-settings"

# Set PKGDEST to control where built packages go
export PKGDEST="$BUILD_DIR"

# Check if we should use dev build (local source)
if [ -n "$OMARCHY_DEV_BUILD" ] && [ -d "/omarchy-installer" ]; then
  echo "========================================="
  echo "DEV MODE: Using locally mounted source"
  echo "========================================="
  
  # Source the dev PKGBUILD patch
  source /builder/templates/dev-pkgbuild-patch.sh
  convert_to_dev_pkgbuild "PKGBUILD"
  
  BUILD_FILE="PKGBUILD.dev"
  BUILD_FLAGS="--noconfirm --skippgpcheck --skipchecksums -f"
  echo "✓ Will build from local source (no git clone)"
else
  echo "========================================="
  echo "PRODUCTION MODE: Using git source"
  echo "========================================="
  BUILD_FILE="PKGBUILD"
  BUILD_FLAGS="--noconfirm --skippgpcheck"
  echo "✓ Will git clone from repository"
fi

# Sync package databases (needed for dependency resolution)
echo "Syncing package databases..."
pacman -Sy --noconfirm

# Build the package
# Note: The container runs as root, but makepkg refuses to run as root
# Create a fresh build user (nobody account is expired in base image)
if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi

# Give builder ownership
chown -R builder:builder "$WORK_DIR/omarchy-settings"
chown -R builder:builder "$BUILD_DIR"

# Allow builder to run pacman without password (needed for dependency installation)
echo "builder ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/99-builder-pacman
chmod 440 /etc/sudoers.d/99-builder-pacman

# Build the package as builder user (makepkg will install dependencies via sudo)
su builder -c "cd $WORK_DIR/omarchy-settings && makepkg -p $BUILD_FILE $BUILD_FLAGS -s"

# Find the built package
BUILT_PACKAGE=$(ls -t "$BUILD_DIR"/omarchy-settings-*.pkg.tar.zst 2>/dev/null | head -n1)

if [ -z "$BUILT_PACKAGE" ]; then
    echo "ERROR: Failed to build omarchy-settings package"
    exit 1
fi

echo "✓ Successfully built: $(basename $BUILT_PACKAGE)"
echo "Package location: $BUILT_PACKAGE"

# Export the path for use by build-iso.sh
export OMARCHY_SETTINGS_PKG="$BUILT_PACKAGE"

# Export the source directory for accessing package lists before package is installed
# Check both possible locations (dev mode uses /omarchy-installer, prod uses src/)
if [ -d "/omarchy-installer" ]; then
  export OMARCHY_INSTALLER_SRC="/omarchy-installer"
  echo "✓ Package source available at: $OMARCHY_INSTALLER_SRC (mounted)"
elif [ -d "$WORK_DIR/omarchy-settings/src/omarchy-installer" ]; then
  export OMARCHY_INSTALLER_SRC="$WORK_DIR/omarchy-settings/src/omarchy-installer"
  echo "✓ Package source available at: $OMARCHY_INSTALLER_SRC (from build)"
fi

echo "✓ Package contains everything needed for ISO (configs, package lists, binaries, theme)"

# Now build the omarchy-installer package
echo ""
echo "========================================="
echo "Building omarchy-installer package"
echo "========================================="

# Copy omarchy-installer package files to writable location
cp -r /omarchy-pkgs/pkgbuilds/omarchy-installer "$WORK_DIR/"
cd "$WORK_DIR/omarchy-installer"

# Check if we should use dev build
if [ -n "$OMARCHY_DEV_BUILD" ] && [ -d "/omarchy-installer" ]; then
  echo "DEV MODE: Using locally mounted source"
  
  # Generate dev PKGBUILD
  source /builder/templates/dev-pkgbuild-patch.sh
  convert_to_dev_pkgbuild "PKGBUILD"
  
  INSTALLER_BUILD_FILE="PKGBUILD.dev"
  INSTALLER_BUILD_FLAGS="--noconfirm --skippgpcheck --skipchecksums -f"
else
  echo "PRODUCTION MODE: Using git source"
  INSTALLER_BUILD_FILE="PKGBUILD"
  INSTALLER_BUILD_FLAGS="--noconfirm --skippgpcheck"
fi

# Give builder ownership
chown -R builder:builder "$WORK_DIR/omarchy-installer"

# Build the omarchy-installer package
su builder -c "cd $WORK_DIR/omarchy-installer && makepkg -p $INSTALLER_BUILD_FILE $INSTALLER_BUILD_FLAGS -d"

# Find the built package
OMARCHY_INSTALLER_PKG=$(ls -t "$BUILD_DIR"/omarchy-installer-*.pkg.tar.zst 2>/dev/null | head -n1)

if [ -z "$OMARCHY_INSTALLER_PKG" ]; then
    echo "ERROR: Failed to build omarchy-installer package"
    exit 1
fi

echo "✓ Successfully built: $(basename $OMARCHY_INSTALLER_PKG)"
echo "Package location: $OMARCHY_INSTALLER_PKG"

# Now build the full omarchy package for offline mirror
echo ""
echo "========================================="
echo "Building omarchy meta-package"
echo "========================================="

# Copy omarchy package files to writable location
cp -r /omarchy-pkgs/pkgbuilds/omarchy "$WORK_DIR/"
cd "$WORK_DIR/omarchy"

# Check if we should use dev build
if [ -n "$OMARCHY_DEV_BUILD" ] && [ -d "/omarchy-installer" ]; then
  echo "DEV MODE: Using locally mounted source"
  
  # Generate dev PKGBUILD
  source /builder/templates/dev-pkgbuild-patch.sh
  convert_to_dev_pkgbuild "PKGBUILD"
  
  OMARCHY_BUILD_FILE="PKGBUILD.dev"
  OMARCHY_BUILD_FLAGS="--noconfirm --skippgpcheck --skipchecksums -f"
else
  echo "PRODUCTION MODE: Using git source"
  OMARCHY_BUILD_FILE="PKGBUILD"
  OMARCHY_BUILD_FLAGS="--noconfirm --skippgpcheck"
fi

# Give builder ownership
chown -R builder:builder "$WORK_DIR/omarchy"

# Build the omarchy package
# Note: Skip dependency checks (-d) since we're just packaging files, not running them
# The dependencies will be resolved when the package is installed in the actual system
su builder -c "cd $WORK_DIR/omarchy && makepkg -p $OMARCHY_BUILD_FILE $OMARCHY_BUILD_FLAGS -d"

# Find the built package
OMARCHY_PKG=$(ls -t "$BUILD_DIR"/omarchy-*.pkg.tar.zst 2>/dev/null | head -n1)

if [ -z "$OMARCHY_PKG" ]; then
    echo "ERROR: Failed to build omarchy package"
    exit 1
fi

echo "✓ Successfully built: $(basename $OMARCHY_PKG)"
echo "Package location: $OMARCHY_PKG"

# Now build the omarchy-limine package
echo ""
echo "========================================="
echo "Building omarchy-limine package"
echo "========================================="

# Copy omarchy-limine package files to writable location
cp -r /omarchy-pkgs/pkgbuilds/omarchy-limine "$WORK_DIR/"
cd "$WORK_DIR/omarchy-limine"

# Give builder ownership
chown -R builder:builder "$WORK_DIR/omarchy-limine"

# Build the omarchy-limine package (no source needed, just config files)
su builder -c "cd $WORK_DIR/omarchy-limine && makepkg --noconfirm --skippgpcheck -d"

# Find the built package
OMARCHY_LIMINE_PKG=$(ls -t "$BUILD_DIR"/omarchy-limine-*.pkg.tar.zst 2>/dev/null | head -n1)

if [ -z "$OMARCHY_LIMINE_PKG" ]; then
    echo "ERROR: Failed to build omarchy-limine package"
    exit 1
fi

echo "✓ Successfully built: $(basename $OMARCHY_LIMINE_PKG)"
echo "Package location: $OMARCHY_LIMINE_PKG"

# Export for use by build-iso.sh
export OMARCHY_PKG="$OMARCHY_PKG"
export OMARCHY_INSTALLER_PKG="$OMARCHY_INSTALLER_PKG"
export OMARCHY_LIMINE_PKG="$OMARCHY_LIMINE_PKG"
