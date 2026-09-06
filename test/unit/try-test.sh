#!/bin/bash
#
# Unit tests for omarchy-try. The script takes a path prefix, so every case runs
# against a throwaway sandbox with mount/pacman/systemctl/useradd/passwd/
# runuser/chown stubbed out; each stub logs its invocation so the cases can
# assert what was (not) called and in what order.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TRY="$ROOT/configs/airootfs/usr/local/bin/omarchy-try"

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  local description="$1" detail="${2:-}"
  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

stub_dir="$work/stubs"
mkdir -p "$stub_dir"
for cmd in mount pacman useradd passwd runuser chown chvt; do
  cat >"$stub_dir/$cmd" <<STUB
#!/bin/bash
printf '$cmd %s\n' "\$*" >>"\$TEST_LOG"
[[ \${${cmd^^}_FAIL:-} == 1 ]] && exit 1
exit 0
STUB
done
# systemctl: log everything; report the session unit inactive so the wait loop
# returns at once. reset-failed/stop/start all succeed.
cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
[[ $1 == is-active ]] && exit 3
exit 0
STUB
# systemd-run: log the launch; optionally fail to exercise the refuse path.
cat >"$stub_dir/systemd-run" <<'STUB'
#!/bin/bash
printf 'systemd-run %s\n' "$*" >>"$TEST_LOG"
[[ ${SYSTEMD_RUN_FAIL:-} == 1 ]] && exit 1
exit 0
STUB
chmod +x "$stub_dir"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
  mkdir -p "$sandbox/proc" "$sandbox/usr/share/omarchy-iso" "$sandbox/etc/pacman.d" \
    "$sandbox/run/archiso/cowspace" "$sandbox/home/try/.config/hypr"
  printf 'MemTotal:       %d kB\n' "${1:-16000000}" >"$sandbox/proc/meminfo"
  printf 'omarchy omarchy-4.0.2-1-any.pkg.tar.zst\nhyprland hyprland-0.56.2-1-x86_64.pkg.tar.zst\n' \
    >"$sandbox/usr/share/omarchy-iso/try-packages"
  : >"$sandbox/home/try/.config/hypr/bindings.lua"
  : >"$sandbox/home/try/.config/hypr/autostart.lua"
  export SANDBOX="$sandbox" TEST_LOG="$sandbox/calls.log"
  : >"$TEST_LOG"
}

run_try() {
  PATH="$stub_dir:$PATH" "$TRY" "$sandbox"
}

# Too little memory: refuse before touching anything.
new_sandbox 2000000
! run_try 2>"$sandbox/err" || fail "low memory exits non-zero"
grep -q '4 GiB' "$sandbox/err" || fail "low memory explains the floor" "$(<"$sandbox/err")"
! grep -q '^pacman ' "$TEST_LOG" || fail "low memory installs nothing"
pass "refuses below the memory floor without installing"

# No try list on the medium: refuse.
new_sandbox
rm "$sandbox/usr/share/omarchy-iso/try-packages"
! run_try 2>"$sandbox/err" || fail "missing list exits non-zero"
! grep -q '^pacman ' "$TEST_LOG" || fail "missing list installs nothing"
pass "refuses without a try package list"

# Happy path: the full sequence, in order.
new_sandbox
run_try >"$sandbox/out" 2>&1 || fail "happy path exits zero" "$(<"$sandbox/out")"

grep -q '^mount -o remount,size=50% .*/run/archiso/cowspace$' "$TEST_LOG" || fail "grows the overlay"
for hook in 60-mkinitcpio-remove.hook 60-limine-mkinitcpio-remove-pre.hook \
  80-limine-efi-deploy.hook 90-limine-mkinitcpio-remove-post.hook 90-mkinitcpio-install.hook; do
  [[ $(readlink "$sandbox/etc/pacman.d/hooks/$hook") == /dev/null ]] || fail "masks $hook"
done
pass "grows the overlay and masks the boot-image hooks"

pacman_line=$(grep '^pacman ' "$TEST_LOG")
[[ $pacman_line == *"-Sy --needed --noconfirm"* ]] || fail "pacman syncs the offline db, then installs non-interactively" "$pacman_line"
for pkg in limine limine-mkinitcpio-hook limine-snapper-sync snapper; do
  [[ $pacman_line == *"--assume-installed $pkg"* ]] || fail "assumes $pkg installed" "$pacman_line"
done
[[ $pacman_line == *" omarchy hyprland"* ]] || fail "installs the names from the list" "$pacman_line"
pass "installs the try set with bootloader deps assumed"

grep -q '^systemctl stop iwd.service systemd-networkd.service systemd-networkd.socket$' "$TEST_LOG" || fail "stops iwd/networkd"
grep -q '^systemctl start NetworkManager.service$' "$TEST_LOG" || fail "starts NetworkManager"
grep -q '^useradd -m -G wheel,video,input,audio -s /bin/bash try$' "$TEST_LOG" || fail "creates the try user"
grep -q '^passwd -d try$' "$TEST_LOG" || fail "clears the try password"
[[ $(<"$sandbox/etc/sudoers.d/try") == 'try ALL=(ALL) NOPASSWD: ALL' ]] || fail "writes sudoers"
grep -q 'omarchy-theme-set Tokyo Night' "$TEST_LOG" || fail "sets the theme for the try user"
grep -q 'omarchy-default-terminal foot' "$TEST_LOG" || fail "sets foot as the try user default terminal"
grep -q 'o.bind("SUPER + SHIFT + I", "Install Omarchy", "omarchy-try-install")' \
  "$sandbox/home/try/.config/hypr/bindings.lua" || fail "adds the install binding"
grep -q 'o.launch_on_start("omarchy-try-welcome")' \
  "$sandbox/home/try/.config/hypr/autostart.lua" || fail "adds the welcome autostart"
[[ $(readlink "$sandbox/home/try/.config/systemd/user/omarchy-fcitx5.service") == /dev/null ]] \
  || fail "masks the fcitx5 service that would otherwise crash-loop"
session_line=$(grep '^systemd-run ' "$TEST_LOG")
[[ $session_line == *"--unit=omarchy-try-session"* ]] || fail "names the session unit" "$session_line"
[[ $session_line == *"--uid=try"* ]] || fail "runs the session as the try user" "$session_line"
[[ $session_line == *"PAMName=login"* ]] || fail "gives the session a login seat" "$session_line"
[[ $session_line == *"uwsm start"*"Hyprland"* ]] || fail "launches the Hyprland session" "$session_line"
grep -q '^chvt 7$' "$TEST_LOG" || fail "switches to the session VT"
awk '/^chvt 7$/{c=NR} /^systemd-run /{s=NR} END{exit !(c && s && c<s)}' "$TEST_LOG" \
  || fail "activates the session VT before starting the session (else libinput gets no devices)" "$(<"$TEST_LOG")"
pass "prepares the user and starts the session"

# Order: network switched and sddm started only after pacman succeeded; network
# restored after sddm is gone.
awk '/^pacman /{p=NR} /start NetworkManager/{n=NR} /^systemd-run /{s=NR} /^systemctl start systemd-networkd.socket/{r=NR}
     END{exit !(p<n && n<s && s<r)}' "$TEST_LOG" || fail "sequence is pacman -> NetworkManager -> session -> restore" "$(<"$TEST_LOG")"
grep -q '^systemctl stop omarchy-try-session.service$' "$TEST_LOG" || fail "stops the session unit on the way out"
pass "restores the installer's network after the session"

# pacman failure: no user, no sddm, network untouched.
new_sandbox
! PACMAN_FAIL=1 run_try >"$sandbox/out" 2>&1 || fail "pacman failure exits non-zero"
! grep -q 'NetworkManager' "$TEST_LOG" || fail "pacman failure leaves the network alone"
! grep -q '^useradd' "$TEST_LOG" || fail "pacman failure creates no user"
pass "a failed install leaves the live environment as it was"

# session launch fails after the network switch: restore it.
new_sandbox
! SYSTEMD_RUN_FAIL=1 run_try >"$sandbox/out" 2>&1 || fail "session launch failure exits non-zero"
grep -q '^systemctl start systemd-networkd.socket systemd-networkd.service iwd.service$' "$TEST_LOG" \
  || fail "session launch failure restores the network"
pass "a failed session start restores the network"


# --- select_display_gpu: source the function and exercise it against sysfs fixtures ---
# The script exits early without a sandbox arg, so pull just the functions out.
eval "$(sed -n '/^is_firmware_fb() {/,/^}/p' "$TRY")"
eval "$(sed -n '/^select_display_gpu() {/,/^}/p' "$TRY")"

mk_card() { # <root> <card> <driver> <connector> <status>
  local root=$1 card=$2 drv=$3 conn=$4 st=$5
  mkdir -p "$root/$card/device"
  [[ -n $drv ]] && { mkdir -p "$root/.drv/$drv"; ln -sfn "$root/.drv/$drv" "$root/$card/device/driver"; }
  mkdir -p "$root/$card-$conn"; echo "$st" >"$root/$card-$conn/status"
}

# Hardware path: an AMD panel is chosen with no software forcing.
g=$(mktemp -d "$work/gpu.XXXXXX"); mk_card "$g" card0 amdgpu DP-1 connected
TRY_DRM_DEVICE=; TRY_SOFTWARE=
select_display_gpu "$g" /dev/dri || fail "hardware: returns a device"
[[ $TRY_DRM_DEVICE == /dev/dri/card0 && $TRY_SOFTWARE == 0 ]] \
  || fail "hardware: picks the amdgpu panel without software rendering" "$TRY_DRM_DEVICE/$TRY_SOFTWARE"
pass "select_display_gpu picks a hardware panel"

# A real KMS driver that isn't AMD/Intel (e.g. virtio_gpu in a VM) must be
# treated as hardware, not forced to software by a missing allowlist entry.
g=$(mktemp -d "$work/gpu.XXXXXX"); mk_card "$g" card0 virtio_gpu Virtual-1 connected
TRY_DRM_DEVICE=; TRY_SOFTWARE=
select_display_gpu "$g" /dev/dri || fail "virtio: returns a device"
[[ $TRY_DRM_DEVICE == /dev/dri/card0 && $TRY_SOFTWARE == 0 ]] \
  || fail "virtio: a real driver is hardware, not forced to software" "$TRY_DRM_DEVICE/$TRY_SOFTWARE"
pass "select_display_gpu treats any real KMS driver as hardware"

# Hybrid path (this reporter's own machine): AMD iGPU with no display + the panel
# on a firmware framebuffer (NVIDIA card, nouveau blacklisted). Must choose the
# firmware node and force software rendering, NOT the display-less amdgpu.
g=$(mktemp -d "$work/gpu.XXXXXX")
mk_card "$g" card0 amdgpu DP-4 disconnected
mk_card "$g" card1 simple-framebuffer Virtual-1 connected
TRY_DRM_DEVICE=; TRY_SOFTWARE=
select_display_gpu "$g" /dev/dri || fail "hybrid: returns a device"
[[ $TRY_DRM_DEVICE == /dev/dri/card1 && $TRY_SOFTWARE == 1 ]] \
  || fail "hybrid: picks the firmware framebuffer with software rendering" "$TRY_DRM_DEVICE/$TRY_SOFTWARE"
pass "select_display_gpu falls back to software on the firmware framebuffer"

# No display at all: return non-zero so the caller leaves AQ_DRM_DEVICES unset.
g=$(mktemp -d "$work/gpu.XXXXXX"); mk_card "$g" card0 amdgpu DP-1 disconnected
TRY_DRM_DEVICE=; TRY_SOFTWARE=
! select_display_gpu "$g" /dev/dri || fail "no display: returns non-zero"
pass "select_display_gpu reports no usable display node"
