#!/bin/bash
#
# Unit tests for verify_try_nvidia_packages in builder/build-iso.sh: the
# build-time guard that both NVIDIA driver generations, and the headers DKMS
# builds against, are in the offline mirror. Try installs them from the stick,
# so a missing one must fail the build rather than surface as a silent fall
# back to the software preview on a machine with no network.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD="$ROOT/builder/build-iso.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stubs" "$work/cache"
# ABSENT names a package the mirror does not have; everything else resolves.
cat >"$work/stubs/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$TEST_LOG"
[[ " $* " == *" -Sy "* ]] && exit 0
for a in "$@"; do
  [[ -n ${ABSENT:-} && $a == "$ABSENT" ]] && { echo "error: target not found: $a" >&2; exit 1; }
done
exit 0
STUB
chmod +x "$work/stubs/pacman"
: >"$work/cache/pacman-offline.conf"
# The real live root carries linux-firmware* alongside the kernel, and only one
# of these is a kernel whose -headers exist.
printf 'base\nlinux-firmware\nlinux-firmware-marvell\nlinux-t2\nplymouth\n' >"$work/cache/packages.x86_64"
export TEST_LOG="$work/calls.log"

eval "$(sed -n '/^verify_try_nvidia_packages() {/,/^}/p' "$BUILD")"
build_cache_dir="$work/cache"

: >"$TEST_LOG"
PATH="$work/stubs:$PATH" verify_try_nvidia_packages || fail "a complete mirror passes"
grep -q 'nvidia-open-dkms nvidia-utils linux-t2-headers' "$TEST_LOG" || fail "checks the open branch against the live kernel's headers" "$(<"$TEST_LOG")"
grep -q 'nvidia-580xx-dkms nvidia-580xx-utils linux-t2-headers' "$TEST_LOG" || fail "checks the 580xx branch" "$(<"$TEST_LOG")"
pass "verify_try_nvidia_packages resolves both driver generations plus the kernel headers"

for absent in nvidia-open-dkms nvidia-utils nvidia-580xx-dkms nvidia-580xx-utils linux-t2-headers; do
  : >"$TEST_LOG"
  ! PATH="$work/stubs:$PATH" ABSENT="$absent" verify_try_nvidia_packages 2>/dev/null \
    || fail "a mirror missing $absent fails the build"
done
pass "verify_try_nvidia_packages fails when any part of either driver path is missing"
