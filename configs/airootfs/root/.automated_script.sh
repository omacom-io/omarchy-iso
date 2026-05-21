#!/usr/bin/env bash
#
# Live ISO entry point on tty1: set up the live VT, run the configurator
# wizard, then hand off to the Python install orchestrator. All install-phase
# logic lives in orchestrator/ (omarchy-iso package) and the omarchy-iso-*
# bash helpers; this shim only dispatches.
set -euo pipefail

[[ $(tty) == /dev/tty1 ]] || exit 0

# Live ISO helpers (gum styling, padding constants, etc.) used by the
# configurator. Sourced here so the configurator inherits the environment.
export OMARCHY_MIRROR="$(cat /root/omarchy_mirror)"
export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL=$OMARCHY_PATH/install
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
source "$OMARCHY_INSTALL/helpers/all.sh"

# Tokyo Night palette so the live VT matches the installed look. Must run
# before we redirect stdout so the OSC palette escapes reach the tty.
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

set_tokyo_night_colors

# Capture all subsequent output (configurator + orchestrator) to the install
# log with CSI escape sequences stripped. omarchy-iso-install also tees its
# Python orchestrator output to the same log file (raw), so the orchestrator
# portion appears twice in the log — once raw, once stripped. Acceptable.
mkdir -p /var/log
touch /var/log/omarchy-install.log
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/omarchy-install.log) 2>/dev/null) 2>&1

cd /root
./configurator

# Absolute paths because omarchy-iso-install cd's into /usr/share/omarchy-iso
# before exec'ing python; relative paths would resolve against the wrong dir.
exec /usr/local/bin/omarchy-iso-install \
  --config /root/user_configuration.json \
  --creds /root/user_credentials.json \
  --full-name-file /root/user_full_name.txt \
  --email-file /root/user_email_address.txt \
  --encrypt-file /root/user_encrypt_installation.txt
