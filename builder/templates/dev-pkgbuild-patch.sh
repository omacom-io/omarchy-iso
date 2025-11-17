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
  
  # Replace cd "omarchy-installer" with cd "/omarchy-installer" to use mounted directory directly
  sed -i 's|cd "omarchy-installer"|cd "/omarchy-installer"|g' "$dev_pkgbuild_path"
  
  echo "✓ Dev PKGBUILD created: $dev_pkgbuild_path"
  echo "✓ Will use /omarchy-installer directly (no git clone, no symlinks)"
}
