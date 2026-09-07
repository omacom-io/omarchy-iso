#!/bin/bash
# Runs only inside test/t1-efi-vm's disposable, disk-isolated guest.
set -eEu
trap 'printf "not ok - line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

[[ ${OMARCHY_T1_VM_TEST:-} == 1 && $$ != 1 ]]
[[ $(cat /sys/class/dmi/id/product_name) == MacBookPro13,3 ]]
[[ $(cat /sys/class/block/vda/serial) == T1_TEST_DISK_A ]]
[[ $(cat /sys/class/block/vdb/serial) == T1_TEST_DISK_B ]]

export OMARCHY_PATH=/fixture SETUP_FORM=/fixture/setup-form.sh
export DISK_PARTITIONING=/fixture/disk-partitioning.sh
export OMARCHY_CONFIGURATOR_LIBRARY_ONLY=true
# The UI is not driven here; load the production partitioning functions.
set +e
source /fixture/configurator
set -euo pipefail

pass() { printf 'ok - %s\n' "$1"; }
reject() {
  if "$@"; then
    printf 'not ok - unsafe operation accepted: %s\n' "$1" >&2
    exit 1
  fi
}

seed_apple_esp() {
  local partition=$1
  mkfs.fat -F32 "$partition" >/dev/null
  mount "$partition" /probe
  mkdir -p /probe/eFi/aPpLe/EMBEDDEDOS/FDRData
  printf 'SYNTHETIC TEST DATA ONLY\n' >/probe/eFi/aPpLe/EMBEDDEDOS/FDRData/fixture
  umount /probe
  udevadm trigger --action=change "$partition"
  udevadm settle
}

disk=/dev/vda
t1_install=true
parted -s "$disk" mklabel gpt \
  mkpart primary fat32 1MiB 65MiB set 1 esp on \
  mkpart primary fat32 66MiB 130MiB set 2 esp on \
  mkpart primary ext4 131MiB 100%
partprobe "$disk"
wait_for_device /dev/vda3
seed_apple_esp /dev/vda1
seed_apple_esp /dev/vda2
t1_supported_machine
t1_efi_capture_snapshot "$disk"
[[ ${#t1_efi_preserved_devices[@]} == 2 ]]
pass 'real FAT/GPT discovery finds both mixed-case Apple trees'

# Retain an independent receipt, outside the snapshot the production deletion
# routine refreshes. UUID, byte extent and raw content must all stay identical.
before_geometry=$(parted -ms "$disk" unit B print | sed -n '3,4p')
before_uuids=$(blkid -s PARTUUID -o value /dev/vda1 /dev/vda2)
before_hashes=$(sha256sum /dev/vda1 /dev/vda2)
reject t1_efi_destructive_partition_is_safe "$disk" 1
reject create_partition "$disk" 1048576 2097152 fat32 unsafe

t1_delete_nonpreserved_partitions
[[ $(partition_numbers "$disk") == $'1\n2' ]]
create_partition "$disk" "$EFI_START_B" "$EFI_END_B" fat32 OMARCHY
efi_part_num=$created_partition_number
efi_dev=$(partition_path "$disk" "$efi_part_num")
wait_for_device "$efi_dev"
t1_guard_destructive_partition "$efi_part_num" format
parted -s "$disk" set "$efi_part_num" esp on
mkfs.fat -F32 "$efi_dev" >/dev/null
create_partition "$disk" "$ROOT_START_B" "$ROOT_END_B" btrfs ROOT
root_part_num=$created_partition_number
root_dev=$(partition_path "$disk" "$root_part_num")
wait_for_device "$root_dev"
t1_guard_destructive_partition "$root_part_num" format
# A cheap test-only KDF keeps this small guest fast. The assertion concerns
# partition writes and preservation, not production password/KDF policy.
printf 'synthetic-vm-key\n' >/run/luks-key
cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --iter-time 10 \
  --key-file /run/luks-key "$root_dev"
cryptsetup open --key-file /run/luks-key "$root_dev" t1-test-root
mkfs.btrfs -f /dev/mapper/t1-test-root >/dev/null
cryptsetup close t1-test-root
cryptsetup isLuks --type luks2 "$root_dev"
sync
t1_efi_revalidate_snapshot "$disk"
[[ $(parted -ms "$disk" unit B print | sed -n '3,4p') == "$before_geometry" ]]
[[ $(blkid -s PARTUUID -o value /dev/vda1 /dev/vda2) == "$before_uuids" ]]
[[ $(sha256sum /dev/vda1 /dev/vda2) == "$before_hashes" ]]
pass 'delete/create/format preserves both Apple ESPs byte-for-byte and keeps their GPT identity'

mount "$efi_dev" /probe
t1_efi_discover_candidates "$disk"
[[ ${#t1_efi_candidate_devices[@]} == 2 ]]
umount /probe
pass 'a mounted separate Omarchy ESP does not break subsequent discovery'
python3 /fixture/t1-efi-guard.py layouts "$efi_dev"
[[ $(sha256sum /dev/vda1 /dev/vda2) == "$before_hashes" ]]

rollback_created_parts "$disk"
[[ $(partition_numbers "$disk") == $'1\n2' ]]
t1_efi_revalidate_snapshot "$disk"
pass 'rollback deletes only the newly created partitions'

# Real external-disk installation: the Apple data remains on vda, while vdb
# can use the normal protected layout without a local Apple source.
disk=/dev/vdb
t1_efi_any_candidate_available
t1_efi_capture_optional_snapshot "$disk"
[[ ${#t1_efi_preserved_devices[@]} == 0 ]]
t1_prepare_whole_disk_layout
[[ $needs_mklabel == true ]]
parted -s "$disk" mklabel gpt
create_partition "$disk" "$EFI_START_B" "$EFI_END_B" fat32 OMARCHY
mkfs.fat -F32 "$(partition_path "$disk" "$created_partition_number")" >/dev/null
[[ $(sha256sum /dev/vda1 /dev/vda2) == "$before_hashes" ]]
pass 'an external install target leaves the original Apple disk unchanged'

# Prove unreadable target ESPs fail inspection before an install is attempted.
disk=/dev/vda
wipefs -a /dev/vda2 >/dev/null
udevadm trigger --action=change /dev/vda2
udevadm settle
reject t1_efi_capture_optional_snapshot "$disk"
python3 /fixture/t1-efi-guard.py damaged
pass 'an ESP with a damaged filesystem stops preservation planning'

# Remove synthetic Apple directories to exercise the missing-data hard stop.
seed_apple_esp /dev/vda2
for partition in /dev/vda1 /dev/vda2; do
  mount "$partition" /probe
  rm -r /probe/eFi
  umount /probe
done
reject t1_efi_any_candidate_available
python3 /fixture/t1-efi-guard.py missing
pass 'readable ESPs without Apple data cannot pass the availability gate'
printf 'T1_EFI_VM_PASS\n'
