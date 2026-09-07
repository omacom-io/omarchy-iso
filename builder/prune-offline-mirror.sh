#!/bin/bash

set -euo pipefail

offline_mirror_dir="${1:-}"
if [[ -z $offline_mirror_dir ]]; then
  echo "Usage: prune-offline-mirror.sh <offline-mirror-dir>" >&2
  exit 1
fi
if [[ ! -d $offline_mirror_dir ]]; then
  echo "ERROR: offline mirror directory not found: $offline_mirror_dir" >&2
  exit 1
fi

# Read the exact package filenames selected by pacman on stdin. Validate the
# complete selection before deleting anything: an empty/partial resolution must
# never turn a warm-cache build into a broken mirror.
declare -A required=()
while IFS= read -r filename; do
  [[ -n $filename ]] || continue
  if [[ $filename == */* || $filename != *.pkg.tar.* || $filename == *.sig ]]; then
    echo "ERROR: invalid required package filename: $filename" >&2
    exit 1
  fi
  required["$filename"]=1
done

if (( ${#required[@]} == 0 )); then
  echo "ERROR: refusing to prune the offline mirror with an empty package selection" >&2
  exit 1
fi

missing=()
for filename in "${!required[@]}"; do
  [[ -f "$offline_mirror_dir/$filename" ]] || missing+=("$filename")
done
if (( ${#missing[@]} > 0 )); then
  echo "ERROR: refusing to prune; selected packages are missing from the mirror:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

stale=()
while IFS= read -r -d '' package_file; do
  filename="${package_file##*/}"
  [[ -n ${required[$filename]+x} ]] || stale+=("$package_file")
done < <(
  find "$offline_mirror_dir" -maxdepth 1 -type f \
    -name '*.pkg.tar.*' ! -name '*.sig' -print0
)

if (( ${#stale[@]} > 0 )); then
  echo "Pruning package archives not selected for the offline mirror:"
  for package_file in "${stale[@]}"; do
    echo "  $(basename "$package_file")"
    rm -f -- "$package_file" "$package_file.sig"
  done
fi

# A failed or interrupted download can leave a signature without its archive.
# It cannot be indexed and only wastes space in the ISO.
while IFS= read -r -d '' signature_file; do
  [[ -f ${signature_file%.sig} ]] || rm -f -- "$signature_file"
done < <(
  find "$offline_mirror_dir" -maxdepth 1 -type f \
    -name '*.pkg.tar.*.sig' -print0
)
