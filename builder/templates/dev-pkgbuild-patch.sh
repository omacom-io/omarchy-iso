#!/bin/bash
# Patch to convert production PKGBUILD to dev PKGBUILD
# This script modifies PKGBUILD to use local source instead of git clone

convert_to_dev_pkgbuild() {
  local pkgbuild_path="$1"
  local dev_pkgbuild_path="${pkgbuild_path}.dev"
  
  echo "Creating dev PKGBUILD from production version..."
  
  # Copy production PKGBUILD
  cp "$pkgbuild_path" "$dev_pkgbuild_path"
  
  # Remove git source (replace with empty source array)
  sed -i '/^source=/c\source=()' "$dev_pkgbuild_path"
  sed -i '/^sha256sums=/c\sha256sums=()' "$dev_pkgbuild_path"
  
  # Add prepare() function to symlink local source
  # Insert after the source line
  cat >> "$dev_pkgbuild_path" << 'EOF'

# Dev build: use locally mounted source
prepare() {
  # Symlink local omarchy-installer source
  if [ -d "/omarchy-installer" ]; then
    ln -sf /omarchy-installer "$srcdir/omarchy-installer"
    echo "Using locally mounted omarchy-installer from /omarchy-installer"
  elif [ -f "/omarchy-pkgs/pkgbuilds/omarchy-settings/src/omarchy-installer" ]; then
    # Fallback: use source from previous build
    echo "Using omarchy-installer from previous package build"
  else
    error "No local omarchy-installer source found!"
    return 1
  fi
}
EOF
  
  echo "✓ Dev PKGBUILD created: $dev_pkgbuild_path"
}
