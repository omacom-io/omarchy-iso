#!/usr/bin/env bash
#
# Live ISO entry point on tty1: set up the live VT, run the configurator
# wizard with full TTY access, then start broad logging and hand off to the
# Python install orchestrator.
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

# Tell gum and friends the actual terminal size. stty size on /dev/tty is
# more reliable than tput when stdout could end up redirected.
if size=$(stty size </dev/tty 2>/dev/null); then
  export LINES="${size%% *}"
  export COLUMNS="${size##* }"
fi

# Configurator phase: real TTY on both streams. No tee/pipe.
mkdir -p /var/log
touch "$OMARCHY_INSTALL_LOG_FILE"

# Drain any stale terminal input (e.g., cursor-position-report responses left
# in the kernel tty input buffer by archiso's boot init). If we don't, the
# first gum invocation can echo them as visible "^[[13;1R" artifacts.
while IFS= read -r -t 0 -n 1024 _drain </dev/tty 2>/dev/null; do :; done

cd /root
./configurator >/dev/tty 2>/dev/tty

# Install phase: now safe to capture output to the install log. Strip CSI
# escapes so the log file is readable. Keep stderr going to the log too so
# install-time errors are captured.
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>"$OMARCHY_INSTALL_LOG_FILE") >/dev/tty) 2>&1

# Absolute paths because omarchy-iso-install cd's into /usr/share/omarchy-iso
# before exec'ing python; relative paths would resolve against the wrong dir.
exec /usr/local/bin/omarchy-iso-install \
  --config /root/user_configuration.json \
  --creds /root/user_credentials.json \
  --full-name-file /root/user_full_name.txt \
  --email-file /root/user_email_address.txt \
  --encrypt-file /root/user_encrypt_installation.txt
