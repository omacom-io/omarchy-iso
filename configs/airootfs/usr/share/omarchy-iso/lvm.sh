# LVM discovery helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never offer a volume that something is already using. LVM
# hands out device-mapper paths that look identical whether the volume is a
# spare the owner carved out for us or the root of the system they booted to
# run this installer. Nothing about /dev/pool/root says "do not format me", so
# every candidate is checked against the live mount table before it reaches
# the picker.
#
# Sourced, not executed. The four lvm_*_report functions are the only place
# these helpers touch the system, so tests override those and exercise
# everything above them without root, LVM, or a disk.

# Physical volumes and the group they belong to, one "pv_name|vg_name" per
# line. A PV not yet in a group reports an empty vg_name and is skipped.
lvm_pv_report() {
  pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null
}

# Logical volumes in a group, one "lv_path|lv_name|size_in_bytes" per line.
lvm_lv_report() {
  lvs --noheadings --separator '|' --units b --nosuffix \
    -o lv_path,lv_name,lv_size --select "vg_name=$1" 2>/dev/null
}

# Filesystem type and label on a device, as "fstype|label". Empty when the
# device holds no recognized filesystem, which is the normal state for the
# spare volume this mode expects to be pointed at.
lvm_fs_report() {
  lsblk -nro FSTYPE,LABEL "$1" 2>/dev/null | head -1 | tr ' ' '|'
}

# Every device the live system currently has mounted, one per line, plus
# anything it is using as swap. findmnt covers mounts; /proc/swaps covers the
# swap volume, which is in use just as surely but appears in no mount table.
lvm_busy_devices() {
  findmnt -rno SOURCE 2>/dev/null
  awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null
}

# Trim the leading and trailing whitespace lvs and pvs pad their columns with.
_lvm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Does this partition belong to the disk we are installing to? Prefix matching
# is what detect_windows_esp already uses for the same question; kept the same
# here so both answer alike.
_lvm_on_disk() {
  local part="$1" disk="$2"
  [[ $part == "$disk" || $part == "$disk"[0-9]* || $part == "${disk}p"[0-9]* ]]
}

# Volume groups with at least one physical volume on this disk, deduplicated
# and sorted. A group spanning several disks is reported for each of them.
volume_groups_on_disk() {
  local disk="$1" pv vg
  while IFS='|' read -r pv vg; do
    pv=$(_lvm_trim "$pv")
    vg=$(_lvm_trim "$vg")
    [[ -n $pv && -n $vg ]] || continue
    _lvm_on_disk "$pv" "$disk" || continue
    printf '%s\n' "$vg"
  done < <(lvm_pv_report) | sort -u
}

disk_has_lvm() {
  [[ -n $(volume_groups_on_disk "$1") ]]
}

# Is this volume backing the running system? A true answer disqualifies the
# volume from every role: formatting the live root destroys the installer
# mid-run, and mounting a volume twice corrupts the filesystem on it.
lv_is_busy() {
  local lv="$1" resolved busy
  resolved=$(readlink -f "$lv" 2>/dev/null || printf '%s' "$lv")
  while IFS= read -r busy; do
    [[ -n $busy ]] || continue
    busy=$(readlink -f "$busy" 2>/dev/null || printf '%s' "$busy")
    [[ $busy == "$resolved" ]] && return 0
  done < <(lvm_busy_devices)
  return 1
}

# Logical volumes in a group, one record per line:
#
#   lv_path|lv_name|size_bytes|fstype|label|busy
#
# busy is "busy" or empty. Callers filter on it rather than re-deriving it,
# so the picker and the validation that follows agree on one answer.
logical_volumes() {
  local vg="$1" path name size fstype label busy
  while IFS='|' read -r path name size; do
    path=$(_lvm_trim "$path")
    name=$(_lvm_trim "$name")
    size=$(_lvm_trim "$size")
    [[ -n $path ]] || continue

    IFS='|' read -r fstype label < <(lvm_fs_report "$path")
    busy=""
    lv_is_busy "$path" && busy="busy"

    printf '%s|%s|%s|%s|%s|%s\n' "$path" "$name" "$size" "$fstype" "$label" "$busy"
  done < <(lvm_lv_report "$vg")
}

# One line of a logical_volumes record, formatted for the gum picker. The path
# leads so the caller can recover it with awk '{print $1}', the way disk_form
# already recovers a disk from its display string.
describe_lv() {
  local record="$1" path name size fstype label busy display
  IFS='|' read -r path name size fstype label busy <<<"$record"

  display="$path"
  [[ -n $size ]] && display+=" ($(awk -v b="$size" 'BEGIN { printf "%.1fGB", b / 1024 / 1024 / 1024 }'))"
  if [[ -n $fstype ]]; then
    display+=" - $fstype"
    [[ -n $label ]] && display+=" \"$label\""
  else
    display+=" - empty"
  fi
  [[ -n $busy ]] && display+=" [in use — cannot select]"

  printf '%s\n' "$display"
}
