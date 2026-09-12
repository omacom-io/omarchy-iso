#!/bin/bash
#
# Unit tests for omarchy-cidata-load. The script takes a path prefix, so every
# case runs against a throwaway sandbox with mount/umount/udevadm stubbed out:
# "mounting" copies the fake drive's contents into the mountpoint, and every
# stub logs its invocation so the cases can assert what was (not) called.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CIDATA_LOAD="$ROOT/configs/airootfs/usr/local/bin/omarchy-cidata-load"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

stub_dir="$work/stubs"
mkdir -p "$stub_dir"

cat >"$stub_dir/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$TEST_LOG"
# LATE_ATTACH=<label>:<n>: the drive "appears" on the n-th settle, the way a
# slow USB stick enumerates a few seconds after the ISO stick has booted.
if [[ -n ${LATE_ATTACH:-} ]]; then
  label=${LATE_ATTACH%%:*} nth=${LATE_ATTACH##*:}
  if (( $(grep -c '^udevadm settle' "$TEST_LOG") >= nth )) && [[ ! -e $LATE_ATTACH_DIR/$label ]]; then
    ln -s "$LATE_ATTACH_MEDIA" "$LATE_ATTACH_DIR/$label"
  fi
fi
STUB

# Real sleeps would make the timeout cases slow; log them instead so a case
# can assert how long the probe was prepared to wait.
cat >"$stub_dir/sleep" <<'STUB'
#!/bin/bash
printf 'sleep %s\n' "$*" >>"$TEST_LOG"
STUB

cat >"$stub_dir/mount" <<'STUB'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$TEST_LOG"
[[ ${MOUNT_FAIL:-} == 1 ]] && exit 32
device=$3 mountpoint=$4
cp -a "$(readlink -f "$device")"/. "$mountpoint"/
STUB

cat >"$stub_dir/umount" <<'STUB'
#!/bin/bash
printf 'umount %s\n' "$*" >>"$TEST_LOG"
STUB

# The boot-medium probe: findmnt names the archiso mount's device, lsblk walks
# it up to the whole disk and reports its transport. boot_from sets both.
cat >"$stub_dir/findmnt" <<'STUB'
#!/bin/bash
printf 'findmnt %s\n' "$*" >>"$TEST_LOG"
[[ -n ${BOOT_SOURCE:-} ]] && printf '%s\n' "$BOOT_SOURCE"
STUB
cat >"$stub_dir/lsblk" <<'STUB'
#!/bin/bash
printf 'lsblk %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  *PKNAME*) [[ -n ${BOOT_PARENT:-} && $3 != /dev/$BOOT_PARENT ]] && printf '%s\n' "$BOOT_PARENT" ;;
  *TRAN*)   printf '%s\n' "${BOOT_TRAN:-}" ;;
esac
exit 0
STUB

chmod +x "$stub_dir"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
  mkdir -p "$sandbox/dev/disk/by-label" "$sandbox/root" "$sandbox/media"
  export TEST_LOG="$sandbox/calls.log"
  : >"$TEST_LOG"
}

attach_drive() {
  ln -s "$sandbox/media" "$sandbox/dev/disk/by-label/$1"
}

# usb: booted from a stick (partition on a USB disk); cdrom: a VM's virtual
# CD; none: no archiso mount found at all.
boot_from() {
  case "$1" in
    usb)   export BOOT_SOURCE=/dev/sda1 BOOT_PARENT=sda BOOT_TRAN=usb ;;
    cdrom) export BOOT_SOURCE=/dev/sr0 BOOT_PARENT="" BOOT_TRAN=sata ;;
    none)  export BOOT_SOURCE="" BOOT_PARENT="" BOOT_TRAN="" ;;
  esac
}
boot_from none

run_load() {
  PATH="$stub_dir:$PATH" LATE_ATTACH_DIR="$sandbox/dev/disk/by-label" LATE_ATTACH_MEDIA="$sandbox/media" \
    "$CIDATA_LOAD" "$sandbox"
}

write_required_pair() {
  echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
  echo '{"users": []}' >"$sandbox/media/user_credentials.json"
}

# No cidata drive attached: fall back to the wizard without mounting anything.
new_sandbox
! run_load || fail "no drive exits non-zero"
! grep -q '^mount ' "$TEST_LOG" || fail "no drive mounts nothing"
pass "no drive falls back to the wizard"

# The probe must wait for udev to finish enumerating before concluding there
# is no drive.
grep -q '^udevadm settle' "$TEST_LOG" || fail "probe settles udev first"
pass "probe settles udev first"

# ... and on a USB boot it must keep looking for a bounded time: a stick
# that has not been enumerated yet leaves nothing in the udev queue, so one
# settle proves nothing. The default there is 3 s in 0.5 s steps.
new_sandbox; boot_from usb
! run_load || fail "usb boot, no drive exits non-zero"
(( $(grep -c '^sleep ' "$TEST_LOG") == 6 )) || fail "usb boot waits 3 s by default ($(grep -c '^sleep ' "$TEST_LOG") sleeps)"
grep -q '^findmnt -no SOURCE /run/archiso/bootmnt$' "$TEST_LOG" || fail "the boot medium is read from the archiso mount"
grep -q '^lsblk -dno TRAN /dev/sda$' "$TEST_LOG" || fail "the transport is read from the whole disk, not the partition"
pass "a USB boot without a drive gives up after 3 s"

# Anything that is not a USB boot -- a VM's virtual CD, or no archiso mount
# at all -- keeps the old behaviour: one look, no wait. The wizard on such a
# boot must not get slower.
new_sandbox; boot_from cdrom
! run_load || fail "cdrom boot, no drive exits non-zero"
! grep -q '^sleep ' "$TEST_LOG" || fail "a non-USB boot never sleeps"
(( $(grep -c '^udevadm settle' "$TEST_LOG") == 1 )) || fail "a non-USB boot settles once"
new_sandbox; boot_from none
! run_load || fail "unknown boot medium, no drive exits non-zero"
! grep -q '^sleep ' "$TEST_LOG" || fail "an unknown boot medium never sleeps"
pass "a non-USB or unknown boot medium keeps the single probe"

new_sandbox; boot_from usb
! OMARCHY_CIDATA_WAIT=0 run_load || fail "zero wait exits non-zero"
(( $(grep -c '^sleep ' "$TEST_LOG") == 0 )) || fail "OMARCHY_CIDATA_WAIT=0 never sleeps"
pass "OMARCHY_CIDATA_WAIT=0 checks exactly once even on USB"

# A drive that enumerates late (on the 4th settle) is still picked up, and
# the probe stops waiting as soon as it appears.
new_sandbox; boot_from usb
write_required_pair
LATE_ATTACH=cidata:4 run_load || fail "late drive loads"
[[ -f $sandbox/root/user_configuration.json ]] || fail "late drive copies the configuration"
(( $(grep -c '^sleep ' "$TEST_LOG") == 3 )) || fail "late drive stops the wait once found ($(grep -c '^sleep ' "$TEST_LOG") sleeps)"
pass "a drive that enumerates late is found and the wait stops early"

# Each settle is capped at what is left of the budget: the first one may use
# all of it, the last one none. Otherwise a stuck udev queue could hold the
# boot for udevadm's own default of 120 s per settle.
new_sandbox
! OMARCHY_CIDATA_WAIT=10 run_load || fail "no drive exits non-zero"
first=$(grep -m1 '^udevadm settle' "$TEST_LOG"); last=$(grep '^udevadm settle' "$TEST_LOG" | tail -n1)
[[ $first == 'udevadm settle --timeout=10' ]] || fail "first settle is capped at the whole budget (got '$first')"
[[ $last == 'udevadm settle --timeout=0' ]] || fail "last settle is capped at nothing (got '$last')"
pass "each settle is bounded by the remaining budget"

# The budget is wall-clock, udev time included. With a settle that takes
# 0.6 s of real time and a 1 s budget the probe must give up in about a
# second, not after every scheduled step has run its slow settle.
new_sandbox
cat >"$stub_dir/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$TEST_LOG"
/bin/sleep 0.6
STUB
start=$SECONDS
! OMARCHY_CIDATA_WAIT=1 run_load || fail "slow settle exits non-zero"
elapsed=$((SECONDS - start))
((elapsed <= 2)) || fail "1 s budget with 0.6 s settles took ${elapsed}s"
pass "the budget includes udev time"
# restore the fast stub for the remaining cases
cat >"$stub_dir/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$TEST_LOG"
if [[ -n ${LATE_ATTACH:-} ]]; then
  label=${LATE_ATTACH%%:*} nth=${LATE_ATTACH##*:}
  if (( $(grep -c '^udevadm settle' "$TEST_LOG") >= nth )) && [[ ! -e $LATE_ATTACH_DIR/$label ]]; then
    ln -s "$LATE_ATTACH_MEDIA" "$LATE_ATTACH_DIR/$label"
  fi
fi
STUB

# The override is whole seconds only. A fraction or garbage falls back to the
# default with a note, and a leading zero is decimal, not octal -- neither may
# turn into an endless loop that never reaches the wizard.
new_sandbox; boot_from usb
! OMARCHY_CIDATA_WAIT=1.5 run_load 2>"$sandbox/stderr" || fail "fractional override exits non-zero"
(( $(grep -c '^sleep ' "$TEST_LOG") == 6 )) || fail "fractional override falls back to the medium's default"
grep -q 'not a whole number' "$sandbox/stderr" || fail "fractional override is reported"
new_sandbox
! OMARCHY_CIDATA_WAIT=08 run_load 2>/dev/null || fail "leading-zero override exits non-zero"
(( $(grep -c '^sleep ' "$TEST_LOG") == 16 )) || fail "08 means 8 s, not octal ($(grep -c '^sleep ' "$TEST_LOG") sleeps)"
pass "the override is validated and read as decimal"

# A drive that is there from the start costs no wait at all, USB boot or not.
new_sandbox; boot_from usb
attach_drive cidata
write_required_pair
run_load || fail "present drive loads"
! grep -q '^sleep ' "$TEST_LOG" || fail "present drive never sleeps"
pass "a drive present at the first probe costs no wait"

# A drive with the full file set: everything lands in /root and the drive is
# unmounted afterwards.
new_sandbox
attach_drive cidata
write_required_pair
echo "Jeff" >"$sandbox/media/user_full_name.txt"
echo "jeff@example.com" >"$sandbox/media/user_email_address.txt"
echo "false" >"$sandbox/media/user_encrypt_installation.txt"
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
echo 'tskey-auth-kFAKEKEY' >"$sandbox/media/tailscale_authkey"
run_load || fail "full file set loads"
for file in user_configuration.json user_credentials.json user_full_name.txt user_email_address.txt user_encrypt_installation.txt authorized_keys tailscale_authkey; do
  [[ -f $sandbox/root/$file ]] || fail "full file set copies $file"
done
grep -q '^umount ' "$TEST_LOG" || fail "full file set unmounts the drive"
pass "full file set loads, copies everything, and unmounts"

# The uppercase label variant some tools produce works too.
new_sandbox
attach_drive CIDATA
write_required_pair
run_load || fail "uppercase CIDATA label loads"
pass "uppercase CIDATA label loads"

# The required pair alone is a valid autoinstall drive; the optional files
# stay optional.
new_sandbox
attach_drive cidata
write_required_pair
run_load || fail "required pair alone loads"
[[ ! -e $sandbox/root/authorized_keys ]] || fail "required pair alone copies no optional files"
pass "required pair alone loads without optional files"

# Optional files are copied individually when present.
new_sandbox
attach_drive cidata
write_required_pair
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
run_load || fail "required pair plus authorized_keys loads"
[[ -f $sandbox/root/authorized_keys ]] || fail "authorized_keys is copied when present"
[[ ! -e $sandbox/root/user_full_name.txt ]] || fail "absent optional files are not copied"
[[ ! -e $sandbox/root/tailscale_authkey ]] || fail "absent tailscale_authkey is not copied"
pass "present optional files are copied, absent ones skipped"

# A defer-provisioning marker replaces user_credentials.json: deferred-provisioning installs
# creation to first boot, so imaging rigs ship no credentials at all.
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
: >"$sandbox/media/defer-provisioning"
run_load || fail "config plus defer-provisioning marker loads"
[[ -f $sandbox/root/defer-provisioning ]] || fail "defer-provisioning marker is copied"
[[ ! -e $sandbox/root/user_credentials.json ]] || fail "defer-provisioning drive copies no credentials"
pass "defer-provisioning marker stands in for credentials"

# The defer-provisioning marker and credentials can coexist (rig supplies its own LUKS
# passphrase in the credentials file); both are copied.
new_sandbox
attach_drive cidata
write_required_pair
: >"$sandbox/media/defer-provisioning"
run_load || fail "defer-provisioning marker plus credentials loads"
[[ -f $sandbox/root/defer-provisioning && -f $sandbox/root/user_credentials.json ]] || fail "both defer-provisioning marker and credentials are copied"
pass "defer-provisioning marker plus credentials copies both"

# An defer-provisioning marker without the configuration is still not an autoinstall drive.
new_sandbox
attach_drive cidata
: >"$sandbox/media/defer-provisioning"
! run_load || fail "defer-provisioning marker alone is not an autoinstall drive"
[[ ! -e $sandbox/root/defer-provisioning ]] || fail "defer-provisioning marker alone copies nothing"
pass "defer-provisioning marker alone falls back to the wizard"

# Stale deferred-provisioning inputs from a previous load in the same session are cleared before
# the current drive is copied: a normal drive must not inherit an old defer-provisioning
# marker or credentials.
new_sandbox
attach_drive cidata
write_required_pair
: >"$sandbox/root/defer-provisioning"                       # leftover from a prior deferred-provisioning load
echo 'old-keys' >"$sandbox/root/authorized_keys"
run_load || fail "normal drive after a stale defer-provisioning load loads"
[[ ! -e $sandbox/root/defer-provisioning ]] || fail "stale defer-provisioning marker is cleared"
[[ ! -e $sandbox/root/authorized_keys ]] || fail "stale optional inputs are cleared"
pass "stale deferred-provisioning inputs are cleared before loading a normal drive"

# A drive that isn't an autoinstall drive at all still clears stale inputs so
# the wizard that follows doesn't inherit them.
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json" # half a pair
: >"$sandbox/root/defer-provisioning"
! run_load || fail "half-pair drive still falls back"
[[ ! -e $sandbox/root/defer-provisioning ]] || fail "stale defer-provisioning marker cleared even on fallback"
pass "stale inputs are cleared even when falling back to the wizard"

# Half the required pair is not an autoinstall drive: unmount and fall back.
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
! run_load || fail "half the required pair exits non-zero"
[[ ! -e $sandbox/root/user_configuration.json ]] || fail "half the required pair copies nothing"
grep -q '^umount ' "$TEST_LOG" || fail "half the required pair still unmounts"
pass "half the required pair falls back and unmounts"

# An empty drive labeled cidata is not an autoinstall drive either.
new_sandbox
attach_drive cidata
! run_load || fail "empty drive exits non-zero"
grep -q '^umount ' "$TEST_LOG" || fail "empty drive still unmounts"
pass "empty drive falls back and unmounts"

# A drive that will not mount falls back rather than failing the boot.
new_sandbox
attach_drive cidata
write_required_pair
! MOUNT_FAIL=1 run_load || fail "mount failure exits non-zero"
! grep -q '^umount ' "$TEST_LOG" || fail "mount failure has nothing to unmount"
pass "mount failure falls back to the wizard"

# A copy failure must not report a loaded drive: the install would start with
# missing inputs. Fall back and let the wizard produce them instead.
new_sandbox
attach_drive cidata
write_required_pair
chmod 555 "$sandbox/root"
! run_load 2>/dev/null || fail "copy failure exits non-zero"
grep -q '^umount ' "$TEST_LOG" || fail "copy failure still unmounts"
pass "copy failure falls back and unmounts"

# A partial copy must clean up after itself: the wizard removes only what it
# writes, so anything the loader left behind would leak into the interactive
# install that follows.
new_sandbox
attach_drive cidata
write_required_pair
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
mkdir "$sandbox/root/user_credentials.json"
! run_load 2>/dev/null || fail "partial copy exits non-zero"
[[ ! -e $sandbox/root/user_configuration.json ]] || fail "partial copy removes what it copied"
[[ ! -e $sandbox/root/authorized_keys ]] || fail "partial copy leaves no authorized_keys behind"
pass "partial copy cleans up what it copied"
