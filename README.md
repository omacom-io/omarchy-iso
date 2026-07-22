# Omarchy ISO

The Omarchy ISO is the only supported way to install Omarchy. It ships the Omarchy Configurator, installs Arch Linux, installs the Omarchy packages from the bundled mirror, runs target system setup in the chroot, creates the user, and runs `omarchy-setup-user` for that user.

## Downloading the latest ISO

See the ISO link on [omarchy.org](https://omarchy.org).

## Creating the ISO

Run `./bin/omarchy-iso-make`; output goes into `./release`. By default the ISO uses the Omarchy packages and tracks the `quattro` branch, from the stable mirror. Pass `--edge` to use `omarchy-dev` and `omarchy-settings-dev` from the edge mirror.

For local development, build the ISO from sibling checkouts:

```bash
./bin/omarchy-iso-make --local-source ../omarchy-installer ../omarchy-pkgs
```

Despite the local folder name, the first argument is the Omarchy source checkout (runtime commands, configs, setup scripts, themes, shell, migrations). The installer itself lives in this ISO repo.

Use `--dev` or `--rc` to build against those package channels. Both `--dev` and `--edge` select the dev packages from the edge mirror.

## Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

To exercise installation alongside existing Windows-style partitions, run
`./bin/omarchy-iso-test-windows-disk [release/omarchy.iso]`. It creates a
synthetic disk in `/tmp` with an existing ESP and data partition plus ample
unallocated space, then offers to start an interactive installation on it. The
fixture exercises Windows partition preservation but does not contain Windows.

## Acceptance testing the ISO

Run `./bin/omarchy-iso-test [release/omarchy.iso]` to install the ISO into a headless VM by driving the real interactive install flow — the harness reads each screen via QMP screendumps + OCR and answers with virtual keystrokes, so the configurator wizard, install dashboard, reboot prompt, and SDDM login are all exercised exactly as a user would. It then boots the installed system, sends real VM keyboard shortcuts for the primary shell and window-management actions, and runs the in-guest acceptance suite (`test/acceptance` in the omarchy repo). The suite checks session and service health, the complete core-package manifest, user defaults, representative applications, menus, panels, live weather, launchers, visual selectors, notifications, clipboard, and other interactive shell behavior.

Visual checkpoints are saved as `success-<step>.png` or `failure-<step>.png` alongside the serial and install logs in `test-runs/<iso>/runs/<timestamp>/`. Independent test files and applications continue after a failure so one broken surface does not hide the rest of the report. The harness then stops the VM and opens the ordered screenshots in `imv` for quick visual review.

The harness syncs the acceptance suite from `$OMARCHY_PATH` when it is available. The install phase produces a reusable base image, so iterating against another checkout is fast:

```bash
./bin/omarchy-iso-test release/omarchy.iso --install-only        # once per ISO
./bin/omarchy-iso-test release/omarchy.iso --reuse-base \
  --sync-omarchy ../omarchy                                      # fast loop against local tests
```

Pass `--encrypt` to drive the encrypted install flow (including typing the LUKS passphrase at boot) instead of the unencrypted one. Pass `--no-preview` to collect the same visual artifacts without opening them in `imv` when the run finishes.

## Signing the ISO

Run `./bin/omarchy-iso-sign [release/omarchy.iso]`. The signing key is retrieved from the shared Omarchy vault with the 1Password CLI.

## Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires rclone configuration (`rclone config`).

## Full release of the ISO

Run `./bin/omarchy-iso-release VERSION` to create, test, sign, and upload the ISO in one flow. Add `--rc` to release an RC build instead.
