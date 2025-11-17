#!/usr/bin/env bash
set -euo pipefail

use_omarchy_helpers() {
  # Use omarchy-settings package location (installed in ISO)
  export OMARCHY_PATH="/usr/share/omarchy"
  export OMARCHY_INSTALL="/usr/share/omarchy/install"
  export OMARCHY_INSTALL_LOG_FILE="/var/log/archinstall/install.log"
  
  # Load presentation helpers (clear_logo, etc.) and logging helpers (start_log_output, etc.)
  source /usr/share/omarchy/install/helpers/all.sh
}

run_configurator() {
  set_tokyo_night_colors
  ./configurator
  export OMARCHY_USER="$(jq -r '.username' user_info.json)"
  export OMARCHY_USER_PASSWORD_HASH="$(jq -r '.password_hash' user_info.json)"
  export OMARCHY_USER_NAME="$(cat user_full_name.txt)"
  export OMARCHY_USER_EMAIL="$(cat user_email_address.txt)"
}

install_omarchy() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Installing..."
  echo

  # Copy user info to /tmp on the ISO side
  # omarchy-install will copy these into the chroot at the right time
  cp user_full_name.txt /tmp/omarchy-user-name.txt 2>/dev/null || true
  cp user_email_address.txt /tmp/omarchy-user-email.txt 2>/dev/null || true

  # Check if advanced disk mode (partition TUI)
  EDIT_PARTITIONS_FLAG=""
  if [[ -f edit_partitions_flag.txt ]]; then
    EDIT_PARTITIONS_FLAG=$(cat edit_partitions_flag.txt | tr -d '\n' | xargs)
  fi

  # ADVANCED MODE: Run disk configuration TUI before installation
  if [[ -n "$EDIT_PARTITIONS_FLAG" ]]; then
    clear_logo
    gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Configuring disk layout..."
    echo
    
    # Run omarchy-disk-config to show partition TUI and validate
    # This updates user_configuration.json in place
    /usr/share/omarchy/bin/omarchy-disk-config \
      --config user_configuration.json \
      --creds user_credentials.json
    
    disk_config_exit_code=$?
    
    if [[ $disk_config_exit_code -ne 0 ]]; then
      echo "ERROR: Disk configuration failed or was cancelled"
      exit $disk_config_exit_code
    fi
    
    clear_logo
    gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Disk configuration complete!"
    echo
    sleep 1
  fi

  # Run installation with the configuration (possibly updated by disk-config)
  
  # Create backup log file for raw output (with ANSI codes stripped)
  touch /var/log/omarchy-install.log
  
  # Ensure archinstall log directory exists
  sudo mkdir -p /var/log/archinstall
  
  # Prepare chroot log location (will be created by chroot script when it runs)
  sudo mkdir -p /mnt/var/log
  CHROOT_LOG="/mnt/var/log/omarchy-install-chroot.log"
  
  # Start tailing BOTH logs with tail -F (follows multiple files, waits for files to appear)
  # This will automatically pick up the chroot log when it's created
  start_log_output "/var/log/omarchy-install.log" "$CHROOT_LOG"
  
  # Run omarchy-install and capture output
  # archinstall writes to /var/log/archinstall/install.log internally
  # We also capture stdout/stderr to our backup log (stripping ANSI codes for clean viewing)
  /usr/share/omarchy/bin/omarchy-install \
    --config user_configuration.json \
    --creds user_credentials.json \
    2>&1 | sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tee -a /var/log/omarchy-install.log >/dev/null
  
  install_exit_code=$?
  
  # Check if omarchy-install failed
  if [[ $install_exit_code -ne 0 ]]; then
    stop_log_output
    echo
    echo "ERROR: Installation failed (exit code $install_exit_code)"
    echo "Check /var/log/omarchy-install.log and /mnt/var/log/omarchy-install-chroot.log for details"
    exit $install_exit_code
  fi

  # Installation succeeded - stop log output BEFORE doing anything else
  stop_log_output
  
  # Copy and merge logs to installed system for user access (silent)
  {
    sudo cp /var/log/omarchy-install.log /mnt/var/log/omarchy-install.log 2>/dev/null || true
    sudo cp /var/log/archinstall/install.log /mnt/var/log/archinstall-install.log 2>/dev/null || true
    
    # Create a merged log with all phases
    {
      echo "========================================"
      echo "Omarchy Installation - Complete Log"
      echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "========================================"
      echo
      echo "=== Phase 1: Main Installation (ISO) ==="
      cat /var/log/omarchy-install.log 2>/dev/null || echo "(No main install log found)"
      echo
      echo "=== Phase 2: Chroot Configuration ==="
      cat "$CHROOT_LOG" 2>/dev/null || echo "(No chroot log found)"
      echo
      echo "========================================"
      echo "Installation Complete"
      echo "========================================"
    } | sudo tee /mnt/var/log/omarchy-install-full.log >/dev/null
  } >/dev/null 2>&1
  
  # Show completion screen
  clear
  echo
  tte -i /usr/share/omarchy/logo.txt --canvas-width 0 --anchor-text c --frame-rate 920 laseretch
  echo
  
  # Display installation time if available
  if [[ -f /mnt/tmp/omarchy-install-time.txt ]]; then
    TOTAL_TIME=$(cat /mnt/tmp/omarchy-install-time.txt)
    echo "Installed in $TOTAL_TIME" | tte --canvas-width 0 --anchor-text c --frame-rate 640 print
  else
    echo "Finished installing" | tte --canvas-width 0 --anchor-text c --frame-rate 640 print
  fi
  echo
  
  # Prompt for reboot (centered)
  BUTTON_WIDTH=12  # "Reboot Now" + padding
  BUTTON_PADDING=$(( (TERM_WIDTH - BUTTON_WIDTH) / 2 ))
  if gum confirm --padding "0 0 0 $BUTTON_PADDING" --show-help=false --default --affirmative "Reboot Now" --negative "" ""; then
    clear
    reboot
  fi
}

# Set Tokyo Night color scheme for the terminal
set_tokyo_night_colors() {
  if [[ $(tty) == "/dev/tty"* ]]; then
    # Tokyo Night color palette
    echo -en "\e]P01a1b26" # black (background)
    echo -en "\e]P1f7768e" # red
    echo -en "\e]P29ece6a" # green
    echo -en "\e]P3e0af68" # yellow
    echo -en "\e]P47aa2f7" # blue
    echo -en "\e]P5bb9af7" # magenta
    echo -en "\e]P67dcfff" # cyan
    echo -en "\e]P7a9b1d6" # white
    echo -en "\e]P8414868" # bright black
    echo -en "\e]P9f7768e" # bright red
    echo -en "\e]PA9ece6a" # bright green
    echo -en "\e]PBe0af68" # bright yellow
    echo -en "\e]PC7aa2f7" # bright blue
    echo -en "\e]PDbb9af7" # bright magenta
    echo -en "\e]PE7dcfff" # bright cyan
    echo -en "\e]PFc0caf5" # bright white (foreground)

    # Set default foreground and background
    echo -en "\033[0m"
    clear
  fi
}

if [[ $(tty) == "/dev/tty1" ]]; then
  use_omarchy_helpers
  run_configurator
  install_omarchy
fi
