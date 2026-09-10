#!/bin/bash

# Transform both the shipped package lists and the offline dependency set.
filter_arch_packages() {
  if [[ $ISO_ARCH != aarch64 ]]; then
    cat
    return
  fi

  local package excluded index
  while IFS= read -r package || [[ -n $package ]]; do
    for excluded in "${OMARCHY_ARCH_DROP[@]}"; do
      [[ $package == "$excluded" ]] && continue 2
    done
    for index in "${!OMARCHY_ARCH_SUBST_FROM[@]}"; do
      if [[ $package == "${OMARCHY_ARCH_SUBST_FROM[$index]}" ]]; then
        package=${OMARCHY_ARCH_SUBST_TO[$index]}
        break
      fi
    done
    printf '%s\n' "$package"
  done
}
