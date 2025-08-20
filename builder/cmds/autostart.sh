#!/usr/bin/env bash
set -euo pipefail

catch_errors() {
  echo -e "\n\e[31mOmarchy installation failed!\e[0m"
  echo "The failing command was: \`$BASH_COMMAND\` (exit code: $?)"
  echo "Get help from the community: https://discord.gg/tXFUdasqhY"

  if [[ -n $OMARCHY_USER ]]; then
    echo "You can retry by running: bash ~/.local/share/omarchy/install.sh"
    HOME=/home/$OMARCHY_USER \
      arch-chroot -u $OMARCHY_USER /mnt/ \
      env OMARCHY_USER_NAME="$(<user_full_name.txt)" \
      OMARCHY_USER_EMAIL="$(<user_email_address.txt)" \
      /bin/bash
  fi
}

trap catch_errors ERR

if [[ $(tty) == "/dev/tty1" ]]; then
  NETWORK_NEEDED=1 ./installer

  # Get username from installer config for reliable error recovery
  OMARCHY_USER="$(jq -r '.users[0].username' user_credentials.json)"

  archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent

  # No need to ask for sudo during the installation (omarchy itself responsible for removing after install)
  mkdir -p /mnt/etc/sudoers.d
  echo "root ALL=(ALL:ALL) NOPASSWD: ALL\n%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n$OMARCHY_USER ALL=(ALL:ALL) NOPASSWD: ALL" >/mnt/etc/sudoers.d/99-omarchy-installer

  HOME=/home/$OMARCHY_USER \
    arch-chroot -u $OMARCHY_USER /mnt/ \
    env OMARCHY_USER_NAME="$(<user_full_name.txt)" \
    OMARCHY_USER_EMAIL="$(<user_email_address.txt)" \
    /bin/bash -lc "wget -qO- https://omarchy.org/install-dev | bash"
fi
