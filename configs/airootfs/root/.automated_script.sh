#!/usr/bin/env bash
#
# Live ISO entry point on tty1: set up the live VT, run the configurator
# wizard, then hand off to the Python install orchestrator. Mirrors the
# stream/env contract from the previously-working installer:
#   - stdout teed to /var/log/omarchy-install.log (CSI-stripped) AND to tty
#   - stderr direct to /dev/tty so gum (which draws its TUI on stderr)
#     renders correctly
#   - CLICOLOR_FORCE/FORCE_COLOR so gum emits ANSI even with stdout piped
#   - COLUMNS/LINES so gum picks up real terminal size
set -euo pipefail

[[ $(tty) == /dev/tty1 ]] || exit 0

export OMARCHY_MIRROR="$(cat /root/omarchy_mirror)"
export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL=$OMARCHY_PATH/install
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
source "$OMARCHY_INSTALL/helpers/all.sh"

# Tokyo Night palette so the live VT matches the installed look.
set_tokyo_night_colors() {
  echo -en "\e]P01a1b26"; echo -en "\e]P1f7768e"; echo -en "\e]P29ece6a"
  echo -en "\e]P3e0af68"; echo -en "\e]P47aa2f7"; echo -en "\e]P5bb9af7"
  echo -en "\e]P67dcfff"; echo -en "\e]P7a9b1d6"; echo -en "\e]P8414868"
  echo -en "\e]P9f7768e"; echo -en "\e]PA9ece6a"; echo -en "\e]PBe0af68"
  echo -en "\e]PC7aa2f7"; echo -en "\e]PDbb9af7"; echo -en "\e]PE7dcfff"
  echo -en "\e]PFc0caf5"
  echo -en "\033[0m"
  clear
}
set_tokyo_night_colors

mkdir -p /var/log
touch "$OMARCHY_INSTALL_LOG_FILE"

export COLUMNS=$(tput cols)
export LINES=$(tput lines)
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>"$OMARCHY_INSTALL_LOG_FILE") 2>/dev/null) 2>/dev/tty
export CLICOLOR_FORCE=1
export FORCE_COLOR=1

cd /root
./configurator

# Keep the actual install screen calm: the dashboard owns /dev/tty while the
# noisy installer stream is captured to the support log.
/usr/local/bin/omarchy-install-dashboard "$OMARCHY_INSTALL_LOG_FILE" /run/omarchy-install/state.json /mnt/var/log/omarchy-install.log >/dev/tty 2>&1 &
dashboard_pid=$!
export OMARCHY_INSTALL_DASHBOARD_PID="$dashboard_pid"

stop_install_dashboard() {
  if [[ -n ${dashboard_pid:-} ]]; then
    kill "$dashboard_pid" 2>/dev/null || true
    wait "$dashboard_pid" 2>/dev/null || true
    unset dashboard_pid
  fi
  printf "\033[?25h" >/dev/tty
}
trap stop_install_dashboard EXIT INT TERM

# Absolute paths because omarchy-iso-install cd's into /usr/share/omarchy-iso
# before exec'ing python; relative paths would resolve against the wrong dir.
set +e
/usr/local/bin/omarchy-iso-install \
  --config /root/user_configuration.json \
  --creds /root/user_credentials.json \
  --full-name-file /root/user_full_name.txt \
  --email-file /root/user_email_address.txt \
  --encrypt-file /root/user_encrypt_installation.txt \
  > >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>"$OMARCHY_INSTALL_LOG_FILE") 2>&1
install_status=$?
set -e

stop_install_dashboard
exit "$install_status"
