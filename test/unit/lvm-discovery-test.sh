#!/bin/bash
#
# LVM discovery must never offer a volume the live system is using. The hazard
# this pins: LVM device paths carry no hint of their role, so the volume group
# holding the spare the owner wants Omarchy in also holds the root they booted
# to run the installer and the /home they asked us not to touch. Offering
# either one as a format target loses data with no warning and no undo.
#
# The helpers reach the system only through lvm_pv_report, lvm_lv_report,
# lvm_fs_report and lvm_busy_devices, so overriding those exercises the whole
# module without root, LVM, or a disk.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/lvm.sh"

# shellcheck source=../../configs/airootfs/usr/share/omarchy-iso/lvm.sh
source "$LIB"

failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s:\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# A workstation whose single NVMe disk is one PV: the distribution it booted,
# a large shared /home, swap, and the spare volume Omarchy is meant to land in.
# The padding is what pvs and lvs actually emit — leading whitespace on every
# column — and is the reason the helpers trim.
lvm_pv_report() {
  cat <<'EOF'
  /dev/nvme0n1p2|pool
  /dev/sdb1|
EOF
}

lvm_lv_report() {
  [[ $1 == pool ]] || return 0
  cat <<'EOF'
  /dev/pool/data|data|1825361100800
  /dev/pool/kde|kde|85899345920
  /dev/pool/omarchy|omarchy|85899345920
  /dev/pool/swap|swap|34359738368
EOF
}

lvm_fs_report() {
  case "$1" in
    /dev/pool/data) echo "ext4|DATA" ;;
    /dev/pool/kde) echo "ext4|" ;;
    /dev/pool/omarchy) echo "|" ;;
    /dev/pool/swap) echo "swap|" ;;
    *) echo "|" ;;
  esac
}

# findmnt names the mapper alias, lvs names the vg/lv alias. On a real machine
# both resolve through /dev/dm-N; here they are distinct strings, which is the
# stricter test of the two.
lvm_busy_devices() {
  cat <<'EOF'
/dev/pool/kde
/dev/pool/data
/dev/pool/swap
EOF
}

printf '==> volume group discovery\n'

check "finds the group on the install disk" "pool" "$(volume_groups_on_disk /dev/nvme0n1)"
check "ignores groups on other disks" "" "$(volume_groups_on_disk /dev/nvme1n1)"

if disk_has_lvm /dev/nvme0n1; then
  printf '  ok   disk_has_lvm is true for an LVM disk\n'
else
  printf '  FAIL disk_has_lvm is true for an LVM disk\n'
  failures=$((failures + 1))
fi

if disk_has_lvm /dev/nvme1n1; then
  printf '  FAIL disk_has_lvm is false for a disk with no PV\n'
  failures=$((failures + 1))
else
  printf '  ok   disk_has_lvm is false for a disk with no PV\n'
fi

# A PV with no group is not a group. Reporting one would put an empty string
# into the picker and select a volume group named "".
check "skips a physical volume with no group" "" "$(volume_groups_on_disk /dev/sdb)"

printf '==> substring safety\n'

# /dev/sda1 belongs to /dev/sda; it must not be read as belonging to /dev/sd.
lvm_pv_report() { echo "  /dev/sdaa1|other"; }
check "does not match a longer disk name by prefix" "" "$(volume_groups_on_disk /dev/sda)"

# The one the sdaa case does not catch: /dev/nvme0n10p1 starts with
# /dev/nvme0n1 followed by a digit, so prefix matching claims another disk's
# volume group and offers to install into it.
lvm_pv_report() { echo "  /dev/nvme0n10p1|other"; }
check "does not claim a higher-numbered nvme namespace" "" "$(volume_groups_on_disk /dev/nvme0n1)"

# And the whole disk /dev/nvme0n10 is not a partition of /dev/nvme0n1 either.
lvm_pv_report() { echo "  /dev/nvme0n10|other"; }
check "does not claim a higher-numbered nvme disk" "" "$(volume_groups_on_disk /dev/nvme0n1)"

# Still finds its own partitions once anchoring is enforced.
lvm_pv_report() { echo "  /dev/nvme0n1p2|pool"; }
check "still finds a partition on the selected nvme disk" "pool" "$(volume_groups_on_disk /dev/nvme0n1)"
lvm_pv_report() {
  cat <<'EOF'
  /dev/nvme0n1p2|pool
  /dev/sdb1|
EOF
}

printf '==> in-use detection\n'

for busy_lv in /dev/pool/kde /dev/pool/data /dev/pool/swap; do
  if device_is_busy "$busy_lv"; then
    printf '  ok   %s is reported busy\n' "$busy_lv"
  else
    printf '  FAIL %s is reported busy\n' "$busy_lv"
    failures=$((failures + 1))
  fi
done

if device_is_busy /dev/pool/omarchy; then
  printf '  FAIL the spare volume is not reported busy\n'
  failures=$((failures + 1))
else
  printf '  ok   the spare volume is not reported busy\n'
fi

printf '==> volume records\n'

records=$(logical_volumes pool)

check "the spare volume is the only free one" \
  "/dev/pool/omarchy" \
  "$(awk -F'|' '$6 == "" { print $1 }' <<<"$records")"

check "carries the existing filesystem and label forward" \
  "ext4|DATA" \
  "$(awk -F'|' '$1 == "/dev/pool/data" { print $4 "|" $5 }' <<<"$records")"

check "reports an empty volume as having no filesystem" \
  "" \
  "$(awk -F'|' '$1 == "/dev/pool/omarchy" { print $4 }' <<<"$records")"

check "every volume in the group is reported" "4" "$(wc -l <<<"$records")"

printf '==> picker display\n'

check "an empty volume reads as available" \
  '/dev/pool/omarchy (80.0GB) - empty' \
  "$(describe_lv "$(awk -F'|' '$1 == "/dev/pool/omarchy"' <<<"$records")")"

check "a busy volume says so" \
  '/dev/pool/data (1700.0GB) - ext4 "DATA" [in use — cannot select]' \
  "$(describe_lv "$(awk -F'|' '$1 == "/dev/pool/data"' <<<"$records")")"

# disk_form recovers a device from its display string with awk '{print $1}'.
# The LVM picker reuses that, so the path must stay the first field.
check "the path stays recoverable from the display string" \
  "/dev/pool/omarchy" \
  "$(describe_lv "$(awk -F'|' '$1 == "/dev/pool/omarchy"' <<<"$records")" | awk '{print $1}')"

if ((failures > 0)); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi

printf '\nall checks passed\n'
