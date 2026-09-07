# Disk partitioning helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never predict a partition number. parted fills the lowest
# free GPT slot, not "highest existing + 1", so any disk whose numbering has a
# hole — exactly what deleting a partition to free space leaves behind, which
# is what our own partition tool tells the user to do — hands back a number we
# did not choose. Everything below reads back what was actually created.
#
# Sourced, not executed. The configurator defines abort() and
# disk_abort_hook(); tests get the plain fallbacks.

# Partitions this run created, in creation order. rollback_created_parts()
# undoes exactly these and nothing else.
created_parts=()

# Set by create_partition() instead of being printed: a command substitution
# would run it in a subshell and lose the created_parts bookkeeping.
created_partition_number=""

# A T1 Mac cannot recover its Touch Bar and biometric calibration from a
# generic install image. Keep every Apple EFI source found on the selected
# disk intact until the installed system can match the data to its hardware.
# These arrays exist only for the lifetime of the installer process. Nothing
# below prints their partition UUIDs or hashes.
t1_efi_candidate_devices=()
t1_efi_candidate_numbers=()
t1_efi_preserved_devices=()
t1_efi_preserved_numbers=()
t1_efi_preserved_starts=()
t1_efi_preserved_sizes=()
t1_efi_preserved_partuuids=()
t1_efi_preserved_hashes=()

T1_ESP_PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

t1_supported_machine() {
  local vendor_file="${T1_DMI_VENDOR_FILE:-/sys/class/dmi/id/sys_vendor}"
  local product_file="${T1_DMI_PRODUCT_FILE:-/sys/class/dmi/id/product_name}"
  local vendor product

  [[ -r $vendor_file && -r $product_file ]] || return 1
  vendor=$(<"$vendor_file")
  product=$(<"$product_file")
  [[ $vendor == "Apple Inc." ]] || return 1

  case "$product" in
    MacBookPro13,2 | MacBookPro13,3 | MacBookPro14,2 | MacBookPro14,3) return 0 ;;
    *) return 1 ;;
  esac
}

t1_efi_clear_snapshot() {
  t1_efi_candidate_devices=()
  t1_efi_candidate_numbers=()
  t1_efi_preserved_devices=()
  t1_efi_preserved_numbers=()
  t1_efi_preserved_starts=()
  t1_efi_preserved_sizes=()
  t1_efi_preserved_partuuids=()
  t1_efi_preserved_hashes=()
}

_t1_efi_partition_devices() {
  local disk="$1" listing
  listing=$(lsblk -lnpo PATH,TYPE "$disk" 2>/dev/null) || return 1
  awk '$2 == "part" { print $1 }' <<<"$listing"
}

_t1_efi_whole_disks() {
  local listing
  listing=$(lsblk -dnpo PATH,TYPE 2>/dev/null) || return 1
  awk '$2 == "disk" { print $1 }' <<<"$listing"
}

_t1_efi_is_esp() {
  local parttype filesystem
  # Separate fields so an empty type cannot be mistaken for the filesystem.
  parttype=$(lsblk -dnro PARTTYPE "$1" 2>/dev/null) || return 2
  [[ -n $parttype ]] || return 2
  [[ ${parttype,,} == "$T1_ESP_PARTTYPE" ]] || return 1
  filesystem=$(lsblk -dnro FSTYPE "$1" 2>/dev/null) || return 2
  case ${filesystem,,} in
    fat | fat12 | fat16 | fat32 | msdos | vfat) return 0 ;;
    *) return 2 ;;
  esac
}

# Inspect an already-mounted ESP in place; this covers the installer-created
# Omarchy ESP without trying to mount the same FAT filesystem a second time.
# Otherwise mount the ESP separately and read-only. Only the yes/no result
# leaves this function.
_t1_efi_find_apple_tree() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -iname efi \
    -exec find '{}' -mindepth 1 -maxdepth 1 -type d -iname apple -print -quit \;
}

_t1_efi_contains_apple_tree() {
  local part="$1" existing_mount="" mountpoint match="" result=1 status

  if existing_mount=$(findmnt -rn -S "$part" -o TARGET 2>/dev/null); then
    [[ -n $existing_mount && $existing_mount != *$'\n'* && $existing_mount == /* ]] || return 2
    if match=$(_t1_efi_find_apple_tree "$existing_mount" 2>/dev/null); then
      [[ -n $match ]] && return 0
      return 1
    fi
    return 2
  else
    status=$?
    (( status == 1 )) || return 2
  fi

  mountpoint=$(mktemp -d "${T1_EFI_MOUNT_PARENT:-/run}/t1-efi.XXXXXX") || return 2

  if mount -o ro,nosuid,nodev,noexec -- "$part" "$mountpoint" >/dev/null 2>&1; then
    if match=$(_t1_efi_find_apple_tree "$mountpoint" 2>/dev/null); then
      [[ -n $match ]] && result=0
    else
      result=2
    fi
    umount -- "$mountpoint" >/dev/null 2>&1 || result=2
  else
    result=2
  fi
  rmdir -- "$mountpoint" >/dev/null 2>&1 || result=2

  return "$result"
}

# Populate the candidate arrays with every readable ESP on disk containing an
# EFI/APPLE directory. A completed scan with no candidates is still success;
# callers use the array length to distinguish that from a scan failure.
t1_efi_discover_candidates() {
  local disk="$1" parts part number probe_status
  t1_efi_candidate_devices=()
  t1_efi_candidate_numbers=()

  parts=$(_t1_efi_partition_devices "$disk") || return 2
  while IFS= read -r part; do
    [[ -n $part ]] || continue
    if _t1_efi_is_esp "$part"; then
      :
    else
      probe_status=$?
      (( probe_status == 1 )) && continue
      return 2
    fi
    if _t1_efi_contains_apple_tree "$part"; then
      :
    else
      probe_status=$?
      (( probe_status == 1 )) && continue
      return 2
    fi
    number=$(lsblk -dnro PARTN "$part" 2>/dev/null) || return 2
    [[ $number =~ ^[0-9]+$ ]] || return 2
    t1_efi_candidate_devices+=("$part")
    t1_efi_candidate_numbers+=("$number")
  done <<<"$parts"
}

# A supported T1 Mac may keep its Apple data on a disk other than the install
# target. Check every attached whole disk, but retain no cross-disk geometry:
# only candidates on the selected target may constrain its partition layout.
t1_efi_any_candidate_available() {
  local disks disk found=false inspection_failed=false status
  disks=$(_t1_efi_whole_disks) || return 2

  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    if t1_efi_discover_candidates "$disk"; then
      (( ${#t1_efi_candidate_devices[@]} > 0 )) && found=true
    else
      status=$?
      (( status == 2 )) && inspection_failed=true
    fi
  done <<<"$disks"

  $found && return 0
  $inspection_failed && return 2
  return 1
}

# Set t1_efi_geometry_start and t1_efi_geometry_size from the on-disk GPT.
# Both are bytes; the occupied interval is [start, start + size).
_t1_efi_read_geometry() {
  local disk="$1" number="$2" row
  t1_efi_geometry_start=""
  t1_efi_geometry_size=""
  row=$(parted -ms "$disk" unit B print 2>/dev/null |
    awk -F: -v n="$number" '$1 == n { print $2 ":" $4; exit }') || return 1
  [[ $row == *:* ]] || return 1
  IFS=: read -r t1_efi_geometry_start t1_efi_geometry_size <<<"$row"
  t1_efi_geometry_start=${t1_efi_geometry_start%B}
  t1_efi_geometry_size=${t1_efi_geometry_size%B}
  [[ $t1_efi_geometry_start =~ ^[0-9]+$ && $t1_efi_geometry_size =~ ^[1-9][0-9]*$ ]]
}

_t1_efi_read_partuuid() {
  local value
  value=$(blkid -s PARTUUID -o value -- "$1" 2>/dev/null) || return 1
  [[ -n $value ]] || return 1
  t1_efi_partuuid="$value"
}

_t1_efi_hash_partition() {
  local output digest
  output=$(sha256sum -- "$1" 2>/dev/null) || return 1
  digest=${output%%[[:space:]]*}
  [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  t1_efi_partition_hash=${digest,,}
}

# Capture the immutable facts needed to plan preservation. The default full
# snapshot hashes each raw partition; a false second argument defers that
# expensive proof until immediately before mutation.
t1_efi_capture_optional_snapshot() {
  local disk="$1" include_hash="${2:-true}" i part number status
  local hash_started_us="" hash_finished_us hash_elapsed_ms
  [[ $include_hash == true || $include_hash == false ]] || return 1
  t1_efi_clear_snapshot
  if t1_efi_discover_candidates "$disk"; then
    :
  else
    status=$?
    return "$status"
  fi
  [[ $include_hash == true ]] && hash_started_us=${EPOCHREALTIME/./}

  for i in "${!t1_efi_candidate_devices[@]}"; do
    part=${t1_efi_candidate_devices[$i]}
    number=${t1_efi_candidate_numbers[$i]}
    _t1_efi_read_geometry "$disk" "$number" || { t1_efi_clear_snapshot; return 1; }
    _t1_efi_read_partuuid "$part" || { t1_efi_clear_snapshot; return 1; }
    if [[ $include_hash == true ]]; then
      _t1_efi_hash_partition "$part" || { t1_efi_clear_snapshot; return 1; }
    else
      t1_efi_partition_hash=""
    fi

    t1_efi_preserved_devices+=("$part")
    t1_efi_preserved_numbers+=("$number")
    t1_efi_preserved_starts+=("$t1_efi_geometry_start")
    t1_efi_preserved_sizes+=("$t1_efi_geometry_size")
    t1_efi_preserved_partuuids+=("$t1_efi_partuuid")
    t1_efi_preserved_hashes+=("$t1_efi_partition_hash")
  done

  if [[ $include_hash == true ]] && (( ${#t1_efi_preserved_devices[@]} > 0 )); then
    hash_finished_us=${EPOCHREALTIME/./}
    hash_elapsed_ms=$(((10#$hash_finished_us - 10#$hash_started_us) / 1000))
    printf 'Apple EFI digest snapshot completed in %d ms.\n' "$hash_elapsed_ms"
  fi
}

t1_efi_capture_snapshot() {
  t1_efi_capture_optional_snapshot "$@" || return 1
  (( ${#t1_efi_preserved_devices[@]} > 0 ))
}

# Return success only when [start, end) avoids every preserved byte range.
t1_efi_destructive_range_is_safe() {
  local start="$1" end="$2" i preserved_start preserved_end
  [[ $start =~ ^[0-9]+$ && $end =~ ^[0-9]+$ ]] || return 1
  (( end > start )) || return 1

  for i in "${!t1_efi_preserved_starts[@]}"; do
    preserved_start=${t1_efi_preserved_starts[$i]}
    preserved_end=$((preserved_start + t1_efi_preserved_sizes[$i]))
    (( start < preserved_end && end > preserved_start )) && return 1
  done
  return 0
}

t1_efi_destructive_partition_is_safe() {
  local disk="$1" number="$2"
  _t1_efi_read_geometry "$disk" "$number" || return 1
  t1_efi_destructive_range_is_safe \
    "$t1_efi_geometry_start" "$((t1_efi_geometry_start + t1_efi_geometry_size))"
}

t1_efi_partition_number_is_preserved() {
  local number="$1" preserved
  for preserved in "${t1_efi_preserved_numbers[@]}"; do
    [[ $number == "$preserved" ]] && return 0
  done
  return 1
}

# Find the largest byte range that remains after every preserved Apple ESP is
# treated as immovable. Non-preserved partitions do not constrain this plan:
# the T1 whole-disk flow deletes those before creating Omarchy's partitions.
# The first and last MiB stay reserved for GPT metadata and alignment.
t1_efi_find_largest_safe_region() {
  local disk="$1" disk_size mib lower upper cursor start size end
  local best_start="" best_end="" best_size=0

  t1_efi_safe_region_start=""
  t1_efi_safe_region_end=""
  t1_efi_safe_region_size=""
  disk_size=$(lsblk -bdno SIZE "$disk" 2>/dev/null) || return 1
  [[ $disk_size =~ ^[1-9][0-9]*$ ]] || return 1
  mib=$((1024 * 1024))
  lower=$mib
  upper=$((disk_size / mib * mib - mib))
  (( upper > lower )) || return 1
  cursor=$lower

  while read -r start size; do
    [[ $start =~ ^[0-9]+$ && $size =~ ^[1-9][0-9]*$ ]] || return 1
    end=$((start + size))
    (( end <= lower )) && continue
    (( start >= upper )) && break
    (( start < lower )) && start=$lower
    (( end > upper )) && end=$upper

    if (( start > cursor && start - cursor > best_size )); then
      best_start=$cursor
      best_end=$start
      best_size=$((start - cursor))
    fi
    (( end > cursor )) && cursor=$end
  done < <(
    for i in "${!t1_efi_preserved_starts[@]}"; do
      printf '%s %s\n' "${t1_efi_preserved_starts[$i]}" "${t1_efi_preserved_sizes[$i]}"
    done | sort -n -k1,1
  )

  if (( upper > cursor && upper - cursor > best_size )); then
    best_start=$cursor
    best_end=$upper
    best_size=$((upper - cursor))
  fi

  (( best_size > 0 )) || return 1
  t1_efi_destructive_range_is_safe "$best_start" "$best_end" || return 1
  t1_efi_safe_region_start=$best_start
  t1_efi_safe_region_end=$best_end
  t1_efi_safe_region_size=$best_size
}

# Re-read GPT geometry and the raw partition after partitioning. Locate each
# source by its PARTUUID rather than assuming its partition number stayed the
# same. Call this both immediately before destructive work and after the new
# layout has been created.
t1_efi_revalidate_snapshot() {
  local disk="$1" parts i expected_uuid expected_start expected_size
  local expected_hash part current_uuid number matches
  local hash_started_us=${EPOCHREALTIME/./} hash_finished_us hash_elapsed_ms
  (( ${#t1_efi_preserved_devices[@]} > 0 )) || return 1
  parts=$(_t1_efi_partition_devices "$disk") || return 1

  for i in "${!t1_efi_preserved_devices[@]}"; do
    expected_uuid=${t1_efi_preserved_partuuids[$i]}
    expected_start=${t1_efi_preserved_starts[$i]}
    expected_size=${t1_efi_preserved_sizes[$i]}
    expected_hash=${t1_efi_preserved_hashes[$i]}
    matches=0

    while IFS= read -r part; do
      [[ -n $part ]] || continue
      _t1_efi_read_partuuid "$part" || continue
      current_uuid=$t1_efi_partuuid
      [[ $current_uuid == "$expected_uuid" ]] || continue
      matches=$((matches + 1))
      (( matches == 1 )) || return 1
      _t1_efi_is_esp "$part" || return 1
      number=$(lsblk -dnro PARTN "$part" 2>/dev/null) || return 1
      [[ $number =~ ^[0-9]+$ ]] || return 1
      _t1_efi_read_geometry "$disk" "$number" || return 1
      [[ $t1_efi_geometry_start == "$expected_start" ]] || return 1
      [[ $t1_efi_geometry_size == "$expected_size" ]] || return 1
      _t1_efi_hash_partition "$part" || return 1
      [[ $t1_efi_partition_hash == "$expected_hash" ]] || return 1
    done <<<"$parts"

    (( matches == 1 )) || return 1
  done

  hash_finished_us=${EPOCHREALTIME/./}
  hash_elapsed_ms=$(((10#$hash_finished_us - 10#$hash_started_us) / 1000))
  printf 'Apple EFI digest revalidation completed in %d ms.\n' "$hash_elapsed_ms"
}

# Compute partition device path, handling NVMe/mmcblk's pN naming.
partition_path() {
  local _disk="$1" _num="$2"
  if [[ "$_disk" == *nvme* || "$_disk" == *mmcblk* ]]; then
    echo "${_disk}p${_num}"
  else
    echo "${_disk}${_num}"
  fi
}

# Partition numbers as the on-disk GPT reports them. parted rather than lsblk
# on purpose: this is the table parted itself is about to modify, so discovery
# never depends on the kernel having re-read the partition table yet — and the
# same code works against an image file in tests, where lsblk sees nothing.
partition_numbers() {
  parted -ms "$1" unit B print 2>/dev/null | tail -n +3 | cut -d: -f1
}

partition_size_bytes() {
  parted -ms "$1" unit B print 2>/dev/null |
    awk -F: -v n="$2" '$1 == n { gsub(/B/, "", $4); print $4; exit }'
}

# Fail loudly. The former version looped over sleep and returned its status,
# so a device that never appeared was indistinguishable from one that did.
wait_for_device() {
  local i
  for i in $(seq 1 10); do
    [[ -b "$1" ]] && return 0
    udevadm settle 2>/dev/null || true
    sleep 1
  done
  return 1
}

_disk_abort() {
  if declare -F disk_abort_hook >/dev/null; then
    disk_abort_hook "$1"
  elif declare -F abort >/dev/null; then
    abort "$1"
  fi
  echo "Error: $1" >&2
  exit 1
}

# Run a disk-writing command, fold its stderr into stdout, and abort on a
# non-zero exit. The fold matters: .automated_script.sh tees stdout into
# /var/log/omarchy-install.log but sends stderr straight to the tty (gum draws
# its TUI there), so an unwrapped failure leaves no trace in the log the user
# uploads — and the configurator's next screen clears it off the display too.
disk_step() {
  local desc="$1"
  shift
  local output status=0
  output=$("$@" 2>&1) || status=$?
  [[ -n $output ]] && printf '%s\n' "$output"
  (( status == 0 )) && return 0
  _disk_abort "$desc failed (exit $status)"
}

# Create one partition and report the number parted actually assigned.
# Returns non-zero without touching created_parts if anything looks wrong;
# the caller decides how loudly to fail.
create_partition() {
  local disk="$1" start="$2" end="$3" fstype="$4" name="$5"
  local before after num actual want tolerance

  created_partition_number=""

  if (( ${#t1_efi_preserved_starts[@]} > 0 )); then
    t1_efi_destructive_range_is_safe "$start" "$end" || return 1
  fi

  # Lexicographic sort on both sides: comm needs its inputs ordered the same
  # way it compares them, and `sort -n` (1, 2, 10) is not that order.
  before=$(partition_numbers "$disk" | sort)

  parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B" || return 1
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk" | sort)
  num=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [[ -n $num ]] || return 1

  # The number must be genuinely new. This is the safety property that keeps a
  # numbering mistake from ever formatting a partition somebody else is using;
  # it is cheaper and more reliable than sniffing the target for signatures,
  # which would false-positive on remnants left in freed space.
  grep -qx "$num" <<<"$before" && return 1

  actual=$(partition_size_bytes "$disk" "$num")
  [[ -n $actual ]] || return 1
  want=$((end - start))
  tolerance=$((1024 * 1024))
  (( actual >= want - tolerance && actual <= want + tolerance )) || return 1

  if (( ${#t1_efi_preserved_starts[@]} > 0 )); then
    t1_efi_destructive_partition_is_safe "$disk" "$num" || return 1
  fi
  parted --script "$disk" name "$num" "$name" || true

  created_parts+=("$num")
  created_partition_number="$num"
}

# Undo the partitions this run created, highest number first. Scoped strictly
# to created_parts: without this, a failed install leaves the user's freed
# space occupied by orphans, and the retry reports "not enough free space"
# with no way to connect that to what just happened.
rollback_created_parts() {
  local disk="$1" n status=0
  local retained=()
  (( ${#created_parts[@]} > 0 )) || return 0
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    if (( ${#t1_efi_preserved_starts[@]} > 0 )) &&
      ! t1_efi_destructive_partition_is_safe "$disk" "$n"; then
      retained+=("$n")
      status=1
      continue
    fi
    if ! parted --script "$disk" rm "$n" >/dev/null 2>&1; then
      retained+=("$n")
      status=1
    fi
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=("${retained[@]}")
  return "$status"
}
