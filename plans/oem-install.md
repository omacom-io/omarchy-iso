# OEM Install + First-Boot Setup Plan

## Goal

Create a second ISO flavor for OEM preloading that is installed to internal storage at factory time, then boots into customer setup on first power-on (no external media required), and ends in a fully encrypted Omarchy install.

## Product Requirements

- Factory can preload one image to internal disk.
- Customer first boot launches setup flow automatically (already works: `.automated_script.sh` runs configurator on tty1).
- Customer chooses credentials/settings.
- Final installed OS uses full-disk encryption (LUKS) with customer password (already works: configurator collects password and passes it to archinstall as `encryption_password`).
- Existing consumer ISO behavior remains unchanged.

---

## Chosen Architecture

### Bootstrapping model
- OEM devices ship with an OEM bootstrap ISO image written to internal disk.
- On first boot, `copytoram=y` kernel arg loads the live environment into RAM, freeing the internal disk.
- Bootstrap environment launches existing configurator + installer.
- Installer performs a fresh install to internal disk with LUKS encryption enabled.
- Bootstrap environment is overwritten during install.

### Recovery model: zero-recovery
- No permanent recovery partition.
- Simplest and strongest security story.
- Recovery requires external reinstall media.

---

## Non-Goals

- No on-device recovery workflow.
- No changes to normal installer UX outside explicit OEM mode checks and warnings.
- No factory credential provisioning.

---

## Repo Implementation Plan

## 1) Add OEM build mode

### Files
- `bin/omarchy-iso-make`
- `builder/build-iso.sh`

### Changes
- Add CLI flag `--oem` to `bin/omarchy-iso-make`.
- Pass `OMARCHY_MODE=oem` into Docker build env (default `normal`).
- In `builder/build-iso.sh`, write mode marker `/root/omarchy_mode` containing `oem` or `normal` (same pattern as `omarchy_mirror`).
- Keep OEM on current boot stack (`uefi.grub` + `bios.syslinux`); do not add or depend on systemd-boot paths.
- When `OMARCHY_MODE=oem`, inject `copytoram=y` into all shipped OEM boot entry points before `mkarchiso` runs:
  - `grub/grub.cfg`: append to `linux` cmdline entries.
  - `grub/loopback.cfg`: append to `linux` cmdline entries.
  - `syslinux/archiso_sys-linux.cfg`: append to `APPEND` lines.
- When `OMARCHY_MODE=oem`, remove accessibility/speakup boot entries:
  - `grub/grub.cfg`: remove `archlinux-accessibility` menuentry.
  - `grub/loopback.cfg`: remove `archlinux-accessibility` menuentry.
  - `syslinux/archiso_sys-linux.cfg`: remove `arch64speech` label block.
- When `OMARCHY_MODE=oem`, override `iso_application` in `profiledef.sh` to `"Omarchy OEM Installer"`.
- Rename output ISO with `-oem` suffix (in addition to existing `-$OMARCHY_INSTALLER_REF` suffix).

### Hardening
- Add post-injection build assertion that fails build if any expected boot config does not contain `copytoram=y`.
- Add post-injection build assertion that fails build if any OEM boot config still contains accessibility/speakup entries.
- Make injection idempotent (do not duplicate `copytoram=y` if already present).

### Acceptance criteria
- `./bin/omarchy-iso-make --oem` builds successfully.
- OEM ISO boot entries contain `copytoram=y` in all supported boot paths.
- OEM ISO does not expose accessibility/speakup boot entries.
- Normal build output and behavior remain unchanged.

### Suggested verification commands
- `bsdtar -xOf out/<iso>.iso boot/grub/grub.cfg | rg copytoram=y`
- `bsdtar -xOf out/<iso>.iso boot/grub/loopback.cfg | rg copytoram=y`
- `bsdtar -xOf out/<iso>.iso boot/syslinux/archiso_sys-linux.cfg | rg copytoram=y`
- `bsdtar -xOf out/<iso>.iso boot/grub/grub.cfg | rg 'accessibility|speakup'` (should return no matches)
- `bsdtar -xOf out/<iso>.iso boot/syslinux/archiso_sys-linux.cfg | rg 'speech|accessibility'` (should return no matches)

---

## 2) Add OEM safety guardrails

### Why
OEM image boots from internal disk and later wipes that same disk. Live environment must be fully in RAM before install begins.

### File
- `configs/airootfs/root/.automated_script.sh`

### Changes
- Before `run_configurator`, if `/root/omarchy_mode` is `oem`:
  - Verify `/proc/cmdline` contains `copytoram=y`; abort with clear actionable error if missing.
  - Verify factory hardware minimum using `MemTotal`:
    - Require `MemTotal >= 8 GiB`.
    - Abort with clear error if below minimum.
  - Verify runtime memory safety using `MemAvailable`:
    - Minimum threshold: `1.5 x ISO size + 1 GiB`.
    - Abort with clear error if below threshold.
  - Verify runtime state indicates live root is in RAM (for example, expected archiso runtime mounts present and boot media not actively mounted as install target path).

### Acceptance criteria
- OEM mode aborts safely if `copytoram=y` missing from cmdline.
- OEM mode aborts safely if `MemTotal < 8 GiB`.
- OEM mode aborts safely if `MemAvailable` below threshold.
- OEM mode aborts safely if runtime state does not confirm RAM-backed live environment.

### Error message requirements
- State exactly what failed.
- State why install is blocked.
- Provide next step (reboot using proper OEM media or use external recovery media).

---

## 3) OEM disk warning

### Why
With `copytoram=y`, archiso copies squashfs to RAM and releases boot device. Existing configurator call `findmnt -no SOURCE /run/archiso/bootmnt` may return empty, so exclusion filter is skipped and all physical disks are shown, including former boot disk. No disk selection logic change is required.

OEM mode still needs an unmistakable warning before destructive install proceeds.

### File
- `configs/airootfs/root/configurator`

### Changes
- Read mode from `/root/omarchy_mode`.
- If mode is `oem`, add OEM-specific warning text before existing destructive confirmation.
- Upgrade confirmation in OEM mode to explicit typed confirmation (for example: `YES, WIPE DISK`) while preserving existing normal-mode flow.

### Acceptance criteria
- Normal ISO behavior is unchanged.
- OEM ISO shows OEM-specific warning before disk wipe confirmation.
- OEM typed confirmation is required before destructive action.
- In VM with `copytoram=y`, former boot disk appears in disk list without exclusion-logic changes.

---

## 4) Documentation

### File
- `README.md`

### Changes
- Document `--oem` build flag and resulting artifact naming.
- Document factory workflow: writing OEM ISO to internal disk and expected first-boot UX.
- Document failure and recovery behavior:
  - Missing `copytoram=y`, `MemTotal < 8 GiB`, or low `MemAvailable` causes safe abort.
  - Interrupted/failed install requires external reinstall media.
- Add short operator checklist for manufacturing line validation.

---

## 5) Validation

### VM test matrix
1. Build OEM ISO.
2. Write OEM ISO to virtual disk (not external media emulation).
3. Boot from virtual disk and verify:
   - `/proc/cmdline` contains `copytoram=y`.
   - Guardrail checks pass in healthy case.
   - OEM boot menu does not include accessibility/speech entries.
4. Complete setup flow on first boot.
5. Install to same disk.
6. Reboot into installed OS.
7. Verify encryption:
   - `lsblk` shows crypt mapping.
   - `cryptsetup status` reports active LUKS device.
   - Boot requires unlock passphrase.
8. Validate OEM warning + typed confirmation appears and gates destructive action.

### Boot path coverage
- UEFI + GRUB path.
- BIOS/syslinux path (if still shipped).

### Hardware test matrix
- UEFI test on at least two hardware families (Intel + AMD).
- Confirm no external media required.
- Confirm first boot starts setup automatically.

### Negative tests
- OEM boot without `copytoram=y` -> safe abort with clear error.
- `MemTotal < 8 GiB` -> safe abort with clear error.
- Low `MemAvailable` -> safe abort with clear error.
- Runtime state not RAM-backed -> safe abort with clear error.
- Power interruption before installer starts -> deterministic reboot behavior.
- Power interruption during install -> recovery requires external media (documented).

---

## 6) Security hardening checklist

- No factory credentials exist; customer sets all passwords at first boot.
- Clear shell history and transient setup artifacts at end of install.
- Verify no secrets in logs shipped to customer.
- Regenerate host identity on first installed boot as needed:
  - `machine-id`
  - SSH host keys (if installed/enabled)
- Keep package signature verification and keyring handling intact.

---

## Rollout Plan

1. Implement OEM build flag, mode marker, boot config injection, and build assertions.
2. Implement copytoram, memory, and runtime-state guardrails in `.automated_script.sh`.
3. Add OEM warning text and typed destructive confirmation in configurator.
4. Add docs and operator checklist.
5. Run VM matrix, including negative tests.
6. Run hardware matrix.
7. Cut first OEM preproduction release for manufacturing pilot.

---

## Definition of Done

- `--oem` build exists and is documented.
- Device preloaded with OEM image boots directly to setup.
- Setup installs to internal disk without external media.
- Final installed system is LUKS-encrypted with customer-owned passphrase.
- OEM safety guardrails fail closed with actionable errors.
- Existing non-OEM ISO behavior remains unchanged.
- VM and hardware QA matrix pass.
