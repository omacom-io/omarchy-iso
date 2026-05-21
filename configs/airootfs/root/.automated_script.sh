#!/usr/bin/env bash
set -euo pipefail

use_omarchy_helpers() {
  # omarchy-installer + omarchy-settings are installed into the live ISO (see
  # build-iso.sh arch_packages), so /usr/share/omarchy is the real tree.
  export OMARCHY_MIRROR="$(cat /root/omarchy_mirror)"
  export OMARCHY_PATH=/usr/share/omarchy
  export OMARCHY_INSTALL=$OMARCHY_PATH/install
  export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
  source "$OMARCHY_INSTALL/helpers/all.sh"
}

run_configurator() {
  set_tokyo_night_colors
  ./configurator
  export OMARCHY_USER="$(jq -r '.users[0].username' user_credentials.json)"
}

install_arch() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Installing..."
  echo

  touch /var/log/omarchy-install.log
  start_log_output

  CURRENT_SCRIPT="install_base_system"
  install_base_system > >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/omarchy-install.log) 2>&1
  unset CURRENT_SCRIPT
  stop_log_output
}

install_omarchy() {
  # archinstall pacstrap'd omarchy + omarchy-installer (which pulls
  # omarchy-settings + omarchy-limine) and created the user. The user's
  # home is missing /etc/skel content though, because archinstall creates
  # the user BEFORE installing the additional packages list (we saw user
  # creation at "Creating user $OMARCHY_USER" then omarchy-settings
  # installing /etc/skel/.config/... much later). Seed it now.
  arch-chroot /mnt bash -c "
    cp -rT /etc/skel /home/$OMARCHY_USER/
    chown -R $OMARCHY_USER:$OMARCHY_USER /home/$OMARCHY_USER/
  "

  # Install the rest of the default Omarchy install set (everything in
  # omarchy-base.packages that isn't already a hard dep of omarchy).
  arch-chroot /mnt bash -c '
    mapfile -t pkgs < <(grep -v "^#\|^$" /usr/share/omarchy/install/omarchy-base.packages)
    pacman -S --noconfirm --needed "${pkgs[@]}"
  '

  # Run the installer's offline path. omarchy-install execs /usr/share/omarchy/
  # install.sh; OMARCHY_INSTALL_MODE=offline tells it the chroot install rules.
  chroot_run_as_user "OMARCHY_INSTALL_MODE=offline omarchy-install"

  configure_login_for_unencrypted_install

  if [[ -f /mnt/var/tmp/omarchy-install-completed ]]; then
    reboot
  fi
}

# Tokyo Night palette so the live VT matches the installed look.
set_tokyo_night_colors() {
  if [[ $(tty) == /dev/tty* ]]; then
    echo -en "\e]P01a1b26"; echo -en "\e]P1f7768e"; echo -en "\e]P29ece6a"
    echo -en "\e]P3e0af68"; echo -en "\e]P47aa2f7"; echo -en "\e]P5bb9af7"
    echo -en "\e]P67dcfff"; echo -en "\e]P7a9b1d6"; echo -en "\e]P8414868"
    echo -en "\e]P9f7768e"; echo -en "\e]PA9ece6a"; echo -en "\e]PBe0af68"
    echo -en "\e]PC7aa2f7"; echo -en "\e]PDbb9af7"; echo -en "\e]PE7dcfff"
    echo -en "\e]PFc0caf5"
    echo -en "\033[0m"
    clear
  fi
}

install_disk() {
  jq -er 'first(.disk_config.device_modifications[]? | select(.wipe == true) | .device)' user_configuration.json
}

cleanup_install_disk() {
  local disk="$1"
  [[ -n $disk && -b $disk ]] || { echo "Could not determine install disk for cleanup" >&2; return 1; }

  echo "Cleaning up existing holders on install disk: $disk"
  findmnt -R /mnt >/dev/null && umount -R /mnt || true

  while read -r dev; do
    [[ -b $dev ]] || continue
    swapoff "$dev" 2>/dev/null || true
    while read -r target; do
      [[ -n $target ]] && umount "$target" 2>/dev/null || true
    done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
  done < <(lsblk -rnpo PATH "$disk")

  while read -r dev type; do
    [[ $type == disk || $type == part || $type == crypt ]] || continue
    while read -r vg; do
      [[ -n $vg ]] && vgchange -an "$vg" 2>/dev/null || true
    done < <(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk '{$1=$1; print}' | sort -u)
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  while read -r dev type; do
    [[ $type == crypt ]] && cryptsetup close "$dev" 2>/dev/null || true
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  blockdev --flushbufs "$disk" 2>/dev/null || true
  partprobe "$disk" 2>/dev/null || true
  udevadm settle || true
}

install_base_system() {
  pacman-key --init
  pacman-key --populate archlinux
  pacman-key --populate omarchy
  pacman -Sy --noconfirm

  cleanup_install_disk "$(install_disk)"

  # archinstall 4.2 / Python 3.14 workarounds (matches upstream-main install
  # behavior; carry forward until upstream lands the fixes).
  sed -i \
    -e 's|logfile_target = self\.target / absolute_logfile$|logfile_target = self.target / absolute_logfile.relative_to("/")|' \
    -e 's|(limine_path / file)\.copy(efi_dir_path)|(limine_path / file).copy(efi_dir_path / file)|' \
    -e "s|(limine_path / 'limine-bios.sys')\.copy(boot_limine_path)|(limine_path / 'limine-bios.sys').copy(boot_limine_path / 'limine-bios.sys')|" \
    /usr/lib/python3.14/site-packages/archinstall/lib/installer.py

  archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent \
    --skip-ntp \
    --skip-wkd \
    --skip-wifi-check

  # Use the offline pacman.conf for the target so it pulls from the bundled
  # mirror, not from the network.
  cp /etc/pacman.conf /mnt/etc/pacman.conf

  # Bind-mount the offline mirror + the /opt/packages tarballs into the target
  # so chroot pacman / installer scripts can see them.
  mkdir -p /mnt/var/cache/omarchy/mirror/offline /mnt/opt/packages
  mount --bind /var/cache/omarchy/mirror/offline /mnt/var/cache/omarchy/mirror/offline
  mount --bind /opt/packages /mnt/opt/packages

  # Temporary passwordless sudo for the install user (cleaned up by
  # omarchy's first-run flow).
  mkdir -p /mnt/etc/sudoers.d
  cat >/mnt/etc/sudoers.d/99-omarchy-installer <<EOF
root ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$OMARCHY_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /mnt/etc/sudoers.d/99-omarchy-installer
}

configure_login_for_unencrypted_install() {
  if [[ $(<user_encrypt_installation.txt) != "false" ]]; then
    return
  fi

  mkdir -p /mnt/etc/sddm.conf.d
  rm -f /mnt/etc/sddm.conf.d/autologin.conf
  cat >/mnt/etc/sddm.conf.d/99-omarchy-login.conf <<EOF
[Theme]
Current=omarchy

[Users]
RememberLastUser=true
RememberLastSession=true
EOF

  mkdir -p /mnt/var/lib/sddm
  cat >/mnt/var/lib/sddm/state.conf <<EOF
[Last]
Session=omarchy.desktop
User=$OMARCHY_USER
EOF

  rm -f /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
  arch-chroot /mnt chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf >/dev/null 2>&1 || true
  arch-chroot /mnt systemctl enable sddm.service >/dev/null 2>&1 || true
}

# Run a bash command inside the chroot as the install user, with the env the
# offline installer expects.
chroot_run_as_user() {
  # --unset XDG_RUNTIME_DIR because the live ISO inherits /run/user/0 (root's
  # runtime dir) and arch-chroot -u doesn't reset it. Without this, dconf,
  # flock targets under XDG_RUNTIME_DIR, etc. would fail with Permission
  # denied trying to write to root's runtime dir as ryan.
  HOME=/home/$OMARCHY_USER \
    arch-chroot -u "$OMARCHY_USER" /mnt/ \
    env --unset=XDG_RUNTIME_DIR \
    OMARCHY_INSTALL_MODE=offline \
    OMARCHY_USER_NAME="$(<user_full_name.txt)" \
    OMARCHY_USER_EMAIL="$(<user_email_address.txt)" \
    OMARCHY_MIRROR="$OMARCHY_MIRROR" \
    USER="$OMARCHY_USER" \
    HOME="/home/$OMARCHY_USER" \
    /bin/bash -lc "$1"
}

if [[ $(tty) == /dev/tty1 ]]; then
  use_omarchy_helpers
  run_configurator
  install_arch
  install_omarchy
fi
