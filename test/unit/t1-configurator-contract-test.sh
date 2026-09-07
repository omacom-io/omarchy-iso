#!/bin/bash

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/omarchy" "$WORK/output"
printf 'Omarchy\n' >"$WORK/omarchy/logo.txt"
: >"$WORK/setup-form.sh"

OMARCHY_PATH="$WORK/omarchy"
SETUP_FORM="$WORK/setup-form.sh"
DISK_PARTITIONING="$LIB"
OMARCHY_CONFIGURATOR_LIBRARY_ONLY=true
# shellcheck source=/dev/null
source "$CONFIGURATOR"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then pass "$label"; else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

echo "==> missing Apple data is a plain hard stop"
clear_logo() { :; }
say() { :; }
step() { :; }
if (t1_missing_efi_stop) >/dev/null 2>&1; then
  fail "recovery screen exits instead of continuing"
else
  pass "recovery screen exits instead of continuing"
fi

echo "==> unreadable EFI data has a distinct hard stop"
say() { printf '%s\n' "$*"; }
inspection_output=$(t1_efi_inspection_stop 2>&1 || true)
if [[ $inspection_output == *"could not safely inspect every EFI partition"* &&
  $inspection_output != *"reinstall macOS"* ]]; then
  pass "inspection failure does not prescribe reinstalling macOS"
else
  fail "inspection failure does not prescribe reinstalling macOS"
fi
say() { :; }

echo "==> T1 whole-disk confirmation forces encryption"
clear_logo() { :; }
say() { :; }
gum() { return 0; }
t1_install=true
t1_target_has_candidates=true
encrypt_installation=false
disk=/dev/mock
confirm_disk_overwrite
check "T1 whole-disk confirmation forces encryption" "true" "$encrypt_installation"
gum_calls=0
gum() {
  gum_calls=$((gum_calls + 1))
  (( gum_calls == 1 )) && return 130
  return 0
}
encrypt_installation=false
confirm_disk_overwrite
check "Ctrl+C cannot disable T1 whole-disk encryption" "true" "$encrypt_installation"

echo "==> an external Apple source permits a protected target"
t1_supported_machine() { return 0; }
t1_efi_any_candidate_available() { return 0; }
t1_efi_capture_optional_snapshot() { t1_efi_clear_snapshot; }
step() { :; }
disk=/dev/external-target
t1_snapshot_disk=""
t1_target_snapshot_ready=false
t1_prepare_selected_disk
check "T1 protection remains active" "true" "$t1_install"
check "target-local preservation set may be empty" "false" "$t1_target_has_candidates"
check "selected target snapshot is cached" "true" "$t1_target_snapshot_ready"

echo "==> T1 whole-disk plan keeps a separate 2 GiB ESP"
t1_efi_find_largest_safe_region() {
  t1_efi_safe_region_start=$((1024 * 1024))
  t1_efi_safe_region_end=$((80 * 1024 * 1024 * 1024))
}
t1_efi_destructive_range_is_safe() { return 0; }
MOCK_PTTYPE=gpt
lsblk() { printf '%s\n' "$MOCK_PTTYPE"; }
encrypt_installation=true
t1_prepare_whole_disk_layout
check "Omarchy ESP is exactly 2 GiB" "$((2 * 1024 * 1024 * 1024))" "$((EFI_END_B - EFI_START_B))"
check "whole-disk handoff enables fallback boot" "true" "$protected_enable_fallback"
if (unset encrypt_installation; t1_prepare_whole_disk_layout); then
  pass "whole-disk planning works before the encryption choice"
else
  fail "whole-disk planning works before the encryption choice"
fi
if (( ROOT_START_B > EFI_END_B && ROOT_END_B < t1_efi_safe_region_end )); then
  pass "root remains strictly inside the safe range"
else
  fail "root remains strictly inside the safe range"
fi

echo "==> a candidate-free external target can be initialized as GPT"
t1_efi_clear_snapshot
t1_target_has_candidates=false
MOCK_PTTYPE=""
t1_prepare_whole_disk_layout
check "blank target requests a GPT label" "true" "$needs_mklabel"
MOCK_PTTYPE=dos
t1_prepare_whole_disk_layout
check "MBR target requests a GPT label" "true" "$needs_mklabel"
MOCK_PTTYPE=gpt
t1_prepare_whole_disk_layout
check "GPT target keeps its partition table" "false" "$needs_mklabel"

echo "==> whole-disk deletion skips every preserved partition"
deleted=()
partition_numbers() { printf '%s\n' 1 2 3 4; }
t1_efi_revalidate_snapshot() { return 0; }
t1_efi_any_candidate_available() { return 0; }
t1_efi_capture_optional_snapshot() { return 0; }
t1_efi_partition_number_is_preserved() { [[ $1 == 1 || $1 == 3 ]]; }
t1_guard_destructive_partition() { return 0; }
cleanup_calls=0
omarchy-iso-cleanup-disk() { cleanup_calls=$((cleanup_calls + 1)); }
disk_step() {
  shift
  if [[ ${1:-} == parted && ${2:-} == --script && ${4:-} == rm ]]; then
    deleted+=("${5:-}")
  fi
}
partprobe() { :; }
udevadm() { :; }
sync() { :; }
t1_delete_nonpreserved_partitions
check "whole-disk deletion releases existing holders first" "1" "$cleanup_calls"
check "only non-preserved partitions are deleted" "2 4" "${deleted[*]}"

echo "==> deferred protected install stages one temporary key"
cd "$WORK/output"
defer_provisioning=true
t1_install=true
encrypt_installation=true
full_name=""
email_address=""
password=""
write_user_files
staged_password=$(jq -r .encryption_password user_credentials.json)
check "staged key matches formatter input" "$password" "$staged_password"
if (( ${#staged_password} >= 32 )); then
  pass "staged key has adequate generated length"
else
  fail "staged key has adequate generated length"
fi
check "credentials are root-only" "600" "$(stat -c %a user_credentials.json)"

echo "==> protected handoff carries T1 mode flags"
say() { :; }
needs_mklabel=false
kernel_choice=linux
esp_mount_in_target=/boot
efi_dev=/dev/mock2
root_partition_device=/dev/mock3
root_mapper=/dev/mapper/omarchy_root
protected_enable_fallback=true
hostname=omarchy
timezone=UTC
keyboard=us
run_partition_execute dry
check "handoff uses protected mode" "protected" "$(jq -r .omarchy_install.mode user_configuration.json)"
check "handoff defers provisioning" "true" "$(jq -r .omarchy_install.defer_provisioning user_configuration.json)"
check "T1 whole disk enables fallback boot" "true" "$(jq -r .omarchy_install.boot.enable_fallback user_configuration.json)"

protected_enable_fallback=false
defer_provisioning=false
run_partition_execute dry
check "free-space handoff disables fallback boot" "false" "$(jq -r .omarchy_install.boot.enable_fallback user_configuration.json)"

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
