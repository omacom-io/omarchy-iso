#!/bin/bash

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

# shellcheck source=../../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
T1_EFI_MOUNT_PARENT="$WORK"
failures=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

expect_success() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

expect_failure() {
  local label="$1"
  shift
  if "$@"; then fail "$label"; else pass "$label"; fi
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then pass "$label"; else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

vendor_file="$WORK/vendor"
product_file="$WORK/product"
T1_DMI_VENDOR_FILE="$vendor_file"
T1_DMI_PRODUCT_FILE="$product_file"

echo "==> exact, non-unique T1 model detection"
printf 'Apple Inc.\n' >"$vendor_file"
for model in MacBookPro13,2 MacBookPro13,3 MacBookPro14,2 MacBookPro14,3; do
  printf '%s\n' "$model" >"$product_file"
  expect_success "accepts $model" t1_supported_machine
done
printf 'MacBookPro14,1\n' >"$product_file"
expect_failure "rejects a non-T1 model" t1_supported_machine
printf 'Not Apple\n' >"$vendor_file"
printf 'MacBookPro13,3\n' >"$product_file"
expect_failure "requires the exact vendor" t1_supported_machine

# The remaining tests use command doubles so they need neither root nor a real
# disk. They intentionally expose secrets in their fake output; the helpers
# must capture those values without forwarding them to the test's stdout.
MOCK_LAYOUT=initial
MOCK_TREE=mixed-case
MOCK_MOUNT_OPTIONS=""
MOCK_MOUNT_FAILURE_PART=""
MOCK_MOUNTED_PART=""
MOCK_MOUNTED_ROOT=""
MOCK_MOUNT_CALLS_FILE="$WORK/mount-calls"
: >"$MOCK_MOUNT_CALLS_FILE"
MOCK_REMOVED_PARTITIONS=()
MOCK_HASH_ONE=$(printf '1%.0s' {1..64})
MOCK_HASH_TWO=$(printf '2%.0s' {1..64})
MOCK_HASH_CALLS_FILE="$WORK/hash-calls"
: >"$MOCK_HASH_CALLS_FILE"
MOCK_DISK_SIZE=$((100 * 1024 * 1024 * 1024))
MOCK_ESP_TWO_FILESYSTEM=vfat
MOCK_ESP_TWO_PARTTYPE="$T1_ESP_PARTTYPE"

lsblk() {
  local args="$*" target="${*: -1}"
  if [[ $args == *"-bdno SIZE"* ]]; then
    printf '%s\n' "$MOCK_DISK_SIZE"
  elif [[ $args == *"PATH,TYPE"* ]]; then
    printf '/dev/mock disk\n/dev/mock1 part\n/dev/mock2 part\n/dev/mock3 part\n'
  elif [[ $args == *"PARTTYPE"* ]]; then
    case "$target" in
      /dev/mock1) printf '%s\n' "$T1_ESP_PARTTYPE" ;;
      /dev/mock2) printf '%s\n' "$MOCK_ESP_TWO_PARTTYPE" ;;
      /dev/mock3) printf '0fc63daf-8483-4772-8e79-3d69d8477de4\n' ;;
      *) return 1 ;;
    esac
  elif [[ $args == *"FSTYPE"* ]]; then
    case "$target" in
      /dev/mock1) printf 'vfat\n' ;;
      /dev/mock2) printf '%s\n' "$MOCK_ESP_TWO_FILESYSTEM" ;;
      /dev/mock3) printf 'ext4\n' ;;
      *) return 1 ;;
    esac
  elif [[ $args == *"PARTN"* ]]; then
    printf '%s\n' "${target#/dev/mock}"
  else
    return 1
  fi
}

mount() {
  MOCK_MOUNT_OPTIONS="$2"
  local part="$4" target="$5"
  printf x >>"$MOCK_MOUNT_CALLS_FILE"
  [[ $part != "$MOCK_MOUNT_FAILURE_PART" ]] || return 1
  [[ $part == /dev/mock1 || $part == /dev/mock2 ]] || return 1
  if [[ $part == /dev/mock1 ]]; then
    if [[ $MOCK_TREE == mixed-case ]]; then
      mkdir -p "$target/eFi/aPpLe/EMBEDDEDOS"
    else
      mkdir -p "$target/EFI/OTHER"
    fi
  else
    mkdir -p "$target/EFI/APPLE"
  fi
}

findmnt() {
  local previous="" argument source=""
  for argument in "$@"; do
    [[ $previous == "-S" ]] && source=$argument
    previous=$argument
  done
  if [[ -n $MOCK_MOUNTED_PART && $source == "$MOCK_MOUNTED_PART" ]]; then
    printf '%s\n' "$MOCK_MOUNTED_ROOT"
    return 0
  fi
  return 1
}

umount() {
  find "$2" -mindepth 1 -delete
}

parted() {
  if [[ $* == *" rm "* ]]; then
    MOCK_REMOVED_PARTITIONS+=("${*: -1}")
    return 0
  fi
  if [[ $MOCK_LAYOUT == initial ]]; then
    printf 'BYT;\n/dev/mock:100000B:scsi:512:512:gpt:Mock:;\n'
    printf '1:1000B:1999B:1000B:fat32:Apple:boot, esp;\n'
    printf '2:4000B:5999B:2000B:fat32:Apple copy:boot, esp;\n'
    printf '3:7000B:8999B:2000B:ext4:Other:;\n'
  elif [[ $MOCK_LAYOUT == moved ]]; then
    printf 'BYT;\n/dev/mock:100000B:scsi:512:512:gpt:Mock:;\n'
    printf '1:1001B:2000B:1000B:fat32:Apple:boot, esp;\n'
    printf '2:4000B:5999B:2000B:fat32:Apple copy:boot, esp;\n'
  else
    return 1
  fi
}

blkid() {
  local target="${*: -1}"
  case "$target" in
    /dev/mock1) printf 'APPLE-PART-ONE\n' ;;
    /dev/mock2) printf 'APPLE-PART-TWO\n' ;;
    /dev/mock3) printf 'OTHER-PART\n' ;;
    *) return 1 ;;
  esac
}

sha256sum() {
  local target="${*: -1}"
  printf x >>"$MOCK_HASH_CALLS_FILE"
  case "$target" in
    /dev/mock1) printf '%s  %s\n' "$MOCK_HASH_ONE" "$target" ;;
    /dev/mock2) printf '%s  %s\n' "$MOCK_HASH_TWO" "$target" ;;
    *) return 1 ;;
  esac
}

echo "==> read-only, case-insensitive discovery"
expect_success "candidate scan succeeds" t1_efi_discover_candidates /dev/mock
check "finds both Apple ESPs" "/dev/mock1 /dev/mock2" "${t1_efi_candidate_devices[*]}"
check "records their partition numbers" "1 2" "${t1_efi_candidate_numbers[*]}"
check "mount is read-only and hardened" "ro,nosuid,nodev,noexec" "$MOCK_MOUNT_OPTIONS"
: >"$MOCK_MOUNT_CALLS_FILE"
MOCK_MOUNTED_PART=/dev/mock2
MOCK_MOUNTED_ROOT="$WORK/mounted-esp"
mkdir -p "$MOCK_MOUNTED_ROOT/EFI/limine"
expect_success "an already-mounted new Omarchy ESP does not abort discovery" \
  t1_efi_discover_candidates /dev/mock
check "the mounted non-Apple ESP is not a source" "/dev/mock1" "${t1_efi_candidate_devices[*]}"
check "the mounted ESP is not mounted a second time" "1" "$(wc -c <"$MOCK_MOUNT_CALLS_FILE")"
MOCK_MOUNTED_ROOT="$WORK/mounted[esp]"
mkdir -p "$MOCK_MOUNTED_ROOT/eFi/aPpLe"
expect_success "an existing mount with pattern characters finds its Apple tree" \
  _t1_efi_contains_apple_tree /dev/mock2
check "the pattern-named existing mount is not mounted again" "1" "$(wc -c <"$MOCK_MOUNT_CALLS_FILE")"
MOCK_MOUNTED_PART=""
MOCK_MOUNTED_ROOT=""
MOCK_ESP_TWO_PARTTYPE=""
expect_failure "missing partition type aborts discovery even when FAT is readable" t1_efi_discover_candidates /dev/mock
MOCK_ESP_TWO_PARTTYPE="$T1_ESP_PARTTYPE"
MOCK_ESP_TWO_FILESYSTEM=ext4
expect_failure "rejects a non-FAT partition with the ESP type" _t1_efi_is_esp /dev/mock2
expect_failure "a non-FAT ESP aborts the complete scan" t1_efi_discover_candidates /dev/mock
MOCK_ESP_TWO_FILESYSTEM=vfat
MOCK_MOUNT_FAILURE_PART=/dev/mock2
expect_failure "a probe error aborts the complete scan" t1_efi_discover_candidates /dev/mock
MOCK_MOUNT_FAILURE_PART=""

echo "==> ephemeral preservation snapshot"
snapshot_log="$WORK/snapshot-output"
expect_success "lightweight planning snapshot succeeds" t1_efi_capture_snapshot /dev/mock false
check "planning snapshot performs no full hash" "0" "$(wc -c <"$MOCK_HASH_CALLS_FILE")"
if t1_efi_capture_snapshot /dev/mock >"$snapshot_log" 2>&1; then
  pass "snapshot succeeds"
else
  fail "snapshot succeeds"
fi
snapshot_output=$(<"$snapshot_log")
if [[ $snapshot_output =~ ^Apple\ EFI\ digest\ snapshot\ completed\ in\ [0-9]+\ ms\.$ ]] &&
  [[ $snapshot_output != *APPLE-PART* && $snapshot_output != *"$MOCK_HASH_ONE"* ]]; then
  pass "snapshot logs only elapsed digest time"
else
  fail "snapshot logs only elapsed digest time"
fi
check "captures multiple sources" "2" "${#t1_efi_preserved_devices[@]}"
check "captures byte starts" "1000 4000" "${t1_efi_preserved_starts[*]}"
check "captures byte sizes" "1000 2000" "${t1_efi_preserved_sizes[*]}"
check "captures PARTUUIDs in memory" "APPLE-PART-ONE APPLE-PART-TWO" "${t1_efi_preserved_partuuids[*]}"
check "captures full raw hashes in memory" "$MOCK_HASH_ONE $MOCK_HASH_TWO" "${t1_efi_preserved_hashes[*]}"
check "full snapshot hashes each preserved source once" "2" "$(wc -c <"$MOCK_HASH_CALLS_FILE")"

echo "==> destructive range guard"
expect_failure "rejects an equal preserved range" t1_efi_destructive_range_is_safe 1000 2000
expect_failure "rejects a partial overlap" t1_efi_destructive_range_is_safe 500 1500
expect_failure "rejects a containing range" t1_efi_destructive_range_is_safe 0 10000
expect_success "accepts a range ending at the boundary" t1_efi_destructive_range_is_safe 0 1000
expect_success "accepts a range starting at the boundary" t1_efi_destructive_range_is_safe 2000 4000
expect_failure "rejects deleting a preserved partition" t1_efi_destructive_partition_is_safe /dev/mock 1
expect_success "allows deleting a separate partition" t1_efi_destructive_partition_is_safe /dev/mock 3

echo "==> rollback guards every removal"
created_parts=(1 3)
expect_failure "rollback reports a partition that is no longer safe" rollback_created_parts /dev/mock
check "rollback removes only the still-safe created partition" "3" "${MOCK_REMOVED_PARTITIONS[*]}"
check "rollback retains the refused partition for diagnosis" "1" "${created_parts[*]}"
created_parts=()

echo "==> whole-disk safe-region planning"
mib=$((1024 * 1024))
gib=$((1024 * mib))
t1_efi_preserved_starts=("$mib" "$((50 * gib))")
t1_efi_preserved_sizes=("$((200 * mib))" "$((100 * mib))")
expect_success "finds a region around multiple preserved ESPs" t1_efi_find_largest_safe_region /dev/mock
check "chooses the largest contiguous safe start" "$((50 * gib + 100 * mib))" "$t1_efi_safe_region_start"
check "reserves the final MiB for GPT" "$((100 * gib - mib))" "$t1_efi_safe_region_end"
expect_success "planned region is outside preserved data" \
  t1_efi_destructive_range_is_safe "$t1_efi_safe_region_start" "$t1_efi_safe_region_end"

# Restore the captured mock geometry for the snapshot validation checks below.
t1_efi_preserved_starts=(1000 4000)
t1_efi_preserved_sizes=(1000 2000)

echo "==> pre/post snapshot validation"
expect_success "unchanged sources revalidate" t1_efi_revalidate_snapshot /dev/mock
MOCK_LAYOUT=moved
expect_failure "changed geometry fails validation" t1_efi_revalidate_snapshot /dev/mock
MOCK_LAYOUT=initial
MOCK_HASH_ONE=$(printf 'a%.0s' {1..64})
expect_failure "changed raw content fails validation" t1_efi_revalidate_snapshot /dev/mock

echo "==> missing Apple tree"
MOCK_TREE=missing
# Hide the second ESP so neither readable ESP has EFI/APPLE.
_t1_efi_partition_devices() { printf '/dev/mock1\n/dev/mock3\n'; }
expect_success "empty candidate scan itself succeeds" t1_efi_discover_candidates /dev/mock
check "no candidates when the tree is absent" "0" "${#t1_efi_candidate_devices[@]}"
expect_failure "snapshot refuses an empty source set" t1_efi_capture_snapshot /dev/mock

echo "==> candidates on a different attached disk"
GLOBAL_SCANS=()
GLOBAL_SOURCE_PRESENT=true
_t1_efi_whole_disks() { printf '/dev/target\n/dev/internal\n/dev/backup\n'; }
t1_efi_discover_candidates() {
  GLOBAL_SCANS+=("$1")
  t1_efi_candidate_devices=()
  t1_efi_candidate_numbers=()
  if $GLOBAL_SOURCE_PRESENT && [[ $1 == /dev/internal ]]; then
    t1_efi_candidate_devices=(/dev/internal1)
    t1_efi_candidate_numbers=(1)
  fi
}
expect_success "finds Apple data away from the install target" t1_efi_any_candidate_available
check "checks every attached whole disk" "/dev/target /dev/internal /dev/backup" "${GLOBAL_SCANS[*]}"
GLOBAL_SOURCE_PRESENT=false
expect_failure "reports missing only when no attached disk has a candidate" t1_efi_any_candidate_available

t1_efi_clear_snapshot
expect_success "a target with no local candidate has a valid empty snapshot" \
  t1_efi_capture_optional_snapshot /dev/target false
expect_failure "the strict snapshot still requires a target-local candidate" \
  t1_efi_capture_snapshot /dev/target false
t1_efi_preserved_starts=()
t1_efi_preserved_sizes=()
expect_success "an external source does not constrain target layout" \
  t1_efi_find_largest_safe_region /dev/mock
check "unconstrained target starts after primary GPT" "$mib" "$t1_efi_safe_region_start"
check "unconstrained target reserves backup GPT space" "$((100 * gib - mib))" "$t1_efi_safe_region_end"

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
