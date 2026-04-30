# Protected Partition Install Plan: Dual-Boot + Restore

## Goal

Implement one shared non-destructive install path that supports both:

- Dual-boot installs alongside an existing OS.
- OEM/restore installs from a permanent internal restore partition set.

Beyond install: every standalone Omarchy machine — whether OEM-provisioned or installed from the consumer ISO onto an empty disk — exposes a "factory reset" command that durably stages the next boot into the on-disk restore partition set. The installed-OS command leaves the machine as though it had just been prepared to boot from restore; the restore environment owns the destructive wipe/reinstall flow. Dual-boot installs do not get factory reset (no room for a restore partition set).

The current full-disk install path remains unchanged until the protected-partition path is proven. The protected path does its own partitioning, encryption, filesystems, mounts, and boot configuration, then hands a prepared mount tree to archinstall with `pre_mounted_config`.

## Core Architecture

Use a single installer engine with multiple partition policies.

```text
full_disk        existing archinstall default_layout + wipe:true path
dual_boot        protect existing OS partitions, reuse existing ESP, add Omarchy LUKS root
restore_install  protect restore partition set, create/recreate installed ESP + Omarchy LUKS root
```

The key rule: protected modes must never pass the whole disk to archinstall with `wipe: true`.

## Why This Combines Both Features

Dual-boot and restore installs are the same technical problem:

1. Detect disk layout.
2. Identify protected partitions.
3. Create or format only explicitly writable Omarchy partitions.
4. Set up encrypted root manually.
5. Mount a complete install tree manually.
6. Run archinstall only as a package/base-system installer.
7. Configure encryption, fstab, initramfs, and bootloader after archinstall.

Only the partition policy differs.

## Scope Constraints

- UEFI/GPT only for `dual_boot` and `restore_install` v1.
- Existing BIOS/syslinux ISO behavior stays available for normal full-disk installs.
- No automatic shrinking of existing partitions.
- Dual-boot requires pre-existing free space.
- Restore install requires a detected Omarchy restore partition set.
- Installed Omarchy root is encrypted with LUKS.
- Restore partitions are not encrypted unless a later product requirement demands it.
- Restore payload partitions are normally left unmounted in the installed OS and mounted read-only by the restore environment. A separate restore state partition is the only restore-owned partition mounted read-write for reset triggers and recovery logs.
- Swap matches the current full-disk install: zram for memory pressure, plus a Btrfs swapfile in a dedicated `NODATACOW` `/swap` subvolume sized to RAM for hibernation. The subvolume, swapfile, `resume` mkinitcpio hook, and `resume=<dev> resume_offset=<offset>` Limine cmdline drop-in are created post-install by Omarchy's existing `omarchy-hibernation-setup`. Protected modes must not break this: the `encrypt`/`sd-encrypt` hook must precede `resume` in mkinitcpio so the swapfile is reachable after LUKS unlock, and Limine must honor `/etc/limine-entry-tool.d/*.conf` drop-ins so the post-install hook can append resume parameters. No swap partition.

## Partition Policies

### Full Disk

Current behavior:

```text
p1  installed ESP   FAT32  2G
p2  installed root  LUKS   rest of disk
```

Implementation stays on archinstall `default_layout` with `wipe: true` for now.

Phase 7 replaces this with a layout that mirrors `restore_install`:

```text
p1  restore ESP        FAT32   protected after install
p2  restore payload    ext4    protected after install, read-only payload
p3  restore state      ext4    protected after install, writable trigger/log state
p4  installed ESP      FAT32   writable
p5  installed root     LUKS    writable
```

Rationale: factory reset requires an on-disk restore partition set. Making this the default for standalone installs gives every consumer machine the same self-recovery capability OEM-provisioned machines get. The legacy two-partition layout becomes opt-in (e.g. `--no-restore`) for users who explicitly want the disk space back.

### Dual Boot

Example target disk before install:

```text
p1  existing ESP       FAT32   protected, reused as /efi
p2  Windows MSR        MSR     protected
p3  Windows            NTFS    protected
    free space                 writable region
```

After install:

```text
p1  existing ESP       FAT32   protected, mounted as /efi during install
p2  Windows MSR        MSR     protected
p3  Windows            NTFS    protected
p4  Omarchy root       LUKS    new encrypted Btrfs root
```

Policy:

- Protect all existing partitions.
- Reuse the existing ESP only for Omarchy boot files under `EFI/Omarchy`. Do not write top-level `vmlinuz-*`, `initramfs-*`, or vendor-looking paths on a shared ESP.
- Mount the shared ESP at `/efi`, keep `/boot` on the encrypted root, and install an Omarchy-owned kernel/initramfs sync hook that copies boot artifacts into `/efi/EFI/Omarchy` after kernel or initramfs updates.
- Refuse to install if the existing ESP is below 200 MB total or has less than 150 MB free. Warn below 300 MB total or below 200 MB free. These thresholds size for one Omarchy kernel + initramfs + Limine alongside a typical vendor loader; revisit if the Omarchy initramfs grows materially. Free space must be measured from the mounted ESP, not inferred from partition size.
- Create one new LUKS partition in the largest single contiguous free region of at least 40 GB. Refuse otherwise. Do not stitch across multiple non-contiguous regions.
- Preserve current firmware boot order unless the user explicitly opts to make Omarchy first.
- Abort with a clear error if any Windows partition is detected as BitLocker/FVE, including suspended BitLocker. Do not proceed past detection. Adding a new partition to a disk with a BitLocker-protected volume changes the firmware/boot environment enough that Windows can demand the recovery key on next boot — and many users do not have it. The error message must instruct the user to turn off BitLocker from inside Windows and wait for decryption to complete, then reboot into the Omarchy installer and retry. Do not offer an "I have my recovery key, continue anyway" override in v1; users who really want it can fully disable BitLocker themselves.
- Warn if non-BitLocker Windows is detected, since boot order changes can still surprise users.

### Restore Install

Recommended factory disk image layout:

```text
p1  restore ESP        FAT32   protected, boots restore environment
p2  restore payload    ext4    protected, contains live installer/offline payload
p3  restore state      ext4    protected from formatting, writable reset trigger/log state
p4  installed ESP      FAT32   writable, created/recreated by installer
p5  installed root     LUKS    writable, created/recreated by installer
```

Policy:

- Protect restore ESP, restore payload, and restore state partitions from delete/format operations. Only the restore state partition is mounted read-write, and only for trigger files and logs.
- On first boot, create installed ESP and installed root in remaining disk space.
- On reinstall, format the installed Omarchy partitions in place by default. Only delete and recreate them when their geometry no longer matches policy (e.g. the disk was resized). Format-in-place preserves PARTUUIDs, keeps NVRAM entries valid, and avoids touching the partition table.
- Set installed Omarchy first in boot order after successful install.
- Keep restore boot available as firmware fallback and as a boot menu entry.
- Require `copytoram=y` before mutating the internal disk from restore mode.

Use separate restore and installed ESPs for v1. A shared ESP saves space but makes restore easier to break during normal bootloader maintenance or reinstall.

## Restore Image Provisioning

Create a factory artifact separate from the normal consumer ISO:

```text
omarchy-restore.img.zst
```

Factory provisioning writes this image to the internal disk once:

```bash
zstd -dc omarchy-restore.img.zst | dd of=/dev/nvme0n1 bs=16M status=progress conv=fsync
```

The restore image should contain:

- A restore ESP with `EFI/BOOT/BOOTX64.EFI` fallback boot path.
- A restore payload partition labeled `OMARCHY_RESTORE`.
- A small restore state partition labeled `OMARCHY_STATE` for reset triggers and recovery logs.
- The archiso live environment payload, offline package mirror, configurator, and installer scripts.
- A boot entry that passes `omarchy.mode=restore copytoram=y`.
- Boot configuration that locates the restore payload by stable label/UUID, not by transient disk name.
- A signed manifest covering the archiso payload and offline mirror. The verification public key must be shipped outside the mutable restore payload, such as in the restore boot environment and installed reset tool package.

The factory flasher must verify the integrity of `omarchy-restore.img.zst` before writing. The on-disk restore environment must verify its signed payload manifest at boot before mutating the internal disk. A plain checksum stored on the same writable disk is not sufficient. Without a signed manifest, a tampered or corrupted restore image silently destroys the user's data the next time they invoke "factory reset."

On first restore boot:

1. Bind the candidate restore disk to the actual boot source (`/run/archiso/bootmnt`, kernel command line, or equivalent). Do not select an arbitrary disk just because it has matching labels; cloned restore images can have duplicate labels and UUIDs.
2. Move the backup GPT header to the real end of disk with `sgdisk -e` if the factory image was written to a larger disk. This relocates the header only — existing partitions are not grown. The newly-available space at the end of the disk is what installed ESP and installed root consume.
3. On first boot only, randomize the GPT disk GUID, partition GUIDs/PARTUUIDs, and filesystem UUIDs for restore-owned partitions before generating any NVRAM entries, fstab entries, or installer state. Labels may remain stable; UUIDs must not stay cloned across machines.
4. Detect and protect restore partitions by the newly-randomized PARTUUIDs.
5. Create installed ESP and installed root in remaining space.
6. Continue through the shared protected install path.

## Factory Reset

Goal: an installed Omarchy machine that has a restore partition set (any standalone install — `restore_install` today, `full_disk` after Phase 7) exposes a user-facing factory reset command that prepares the device to boot from internal restore without external media. After the next restore boot, the restore environment returns the device to a fresh-install state.

### User Flow

1. User runs `omarchy-factory-reset` from a terminal with sudo. (A GUI entry under Settings is deferred to a follow-up.)
2. The command prints which partitions will be destroyed (installed ESP, installed root) and which will be preserved (restore ESP, restore payload, restore state), by stable identifier, and asks the user to type a confirmation phrase. The typed-phrase gate is intentional friction; no `--yes` shortcut in v1.
3. On confirmation, the command writes a trigger file to the restore state partition, verifies or recreates the restore boot entry, and sets `BootNext` via `efibootmgr` to that restore entry.
4. The command exits only after the trigger file is fsynced, the restore state partition is unmounted, and `BootNext` is confirmed. At that point the installed-OS side is complete: the machine has been left as though it had just been prepared to boot from the restore partition.
5. The user reboots when ready. A later GUI may offer a "reboot now" action, but rebooting is a convenience after the staged state is durable, not part of the safety-critical mutation.
6. The restore environment detects the trigger on boot, verifies the signed restore payload manifest, writes a reset-in-progress marker to restore state, and temporarily sets persistent `BootOrder` to restore first before mutating installed partitions.
7. The restore environment runs the existing `restore_install` reinstall path — format installed ESP, LUKS-format installed root, run the standard install flow — non-interactively, then deletes the trigger and reset-in-progress marker.
8. On install completion, the restore environment restores persistent `BootOrder` to installed Omarchy first, restore second, sets `BootNext` to the installed Omarchy entry, and reboots.
9. The user lands in a fresh installed Omarchy. Normal persistent `BootOrder` (Omarchy first, restore second) has been restored.

User data on installed ESP and installed root is destroyed. Restore ESP, restore payload, and restore state are protected from destructive operations throughout. The restore payload is the source of truth for the rebuild; restore state contains only trigger and recovery state.

### Trigger Mechanism

Use a flag file on the restore state partition rather than NVRAM variables or the restore payload. NVRAM is fragile across firmware updates, and the restore payload should stay immutable/read-only so signed manifest verification remains meaningful.

- Path: `<restore-state-mount>/.omarchy-factory-reset`
- Contents: timestamp, hostname at trigger time, optional reason. Plain text, one `key=value` per line.
- The installed-OS command mounts the restore state partition by `OMARCHY_STATE` label, writes the flag, fsync, and unmounts. It may mount the restore payload read-only only long enough to verify the signed manifest before triggering.
- The restore environment checks for the flag at boot. If present, it runs the reset flow non-interactively and deletes the flag on success. If absent, restore boot behaves normally (manual install/repair menu).
- The flag must be deleted before reboot. Otherwise the machine resets itself in a loop.

### Boot Order

`efibootmgr --bootnext <restore-entry>` is one-shot — it takes effect on the next boot only, then NVRAM reverts to the existing `BootOrder`. This is what we want before the destructive phase: if the reset is interrupted before restore boot, the next normal boot still tries the installed Omarchy first.

After the restore environment accepts the trigger and before it wipes installed partitions, it must temporarily set persistent `BootOrder` to restore first, installed Omarchy second. This prevents a power loss during reinstall from leaving firmware stuck on a half-written installed ESP. On successful reinstall, the restore environment deletes the reset-in-progress marker, restores persistent `BootOrder` to installed Omarchy first and restore second, then sets `BootNext` to the installed Omarchy entry to land the user in their fresh OS.

If the installed OS cannot write and confirm `BootNext`, the staging command must remove any trigger it wrote and abort; a manual reinstall can still proceed through the firmware boot menu, but `omarchy-factory-reset` has not successfully prepared the machine. If the restore environment cannot set temporary restore-first `BootOrder` for an unattended reset, abort before destructive operations; manual reinstall can still proceed with an explicit warning.

### Safety

The factory reset command is a staging tool, not the destructive installer. It must:

- Require root and refuse to run otherwise.
- Refuse to run if no complete restore partition set is detected (restore ESP, restore payload, restore state), e.g. on a dual-boot machine or a `--no-restore` full-disk install.
- Refuse to run if the signed restore payload manifest check fails — a corrupt restore is not recoverable from inside the running OS, and triggering a reset would brick the machine.
- Verify the restore boot entry exists in NVRAM before triggering; if not, repopulate it from `EFI/BOOT/BOOTX64.EFI` fallback or abort with a message.
- Confirm `BootNext` points to the restore boot entry before exiting, so the system is actually prepared to boot restore.
- Print a final pre-confirmation list of partitions that will be destroyed, by stable identifier, so the user sees exactly what they are committing to.

The restore environment, when running due to the trigger flag, must still apply every guard from the Safety Model. The trigger is permission to run the reinstall flow, not permission to skip safety checks.

### File Changes for Factory Reset

- Ship `omarchy-factory-reset` on the installed system. Source location depends on Omarchy's package boundary — either as part of the Omarchy package on the offline mirror, or copied from the live ISO into the installed system during install. Pick one consistent approach during implementation.
- Restore state must be mountable read-write from the installed OS by an admin via `OMARCHY_STATE`. Restore payload should only be mounted read-only for manifest verification via `OMARCHY_RESTORE`.

## Safety Model

Protected installs must use stable identifiers, not only `/dev/nvme0n1pX` names.

Track:

```text
protected partition PARTUUIDs
restore state PARTUUID
writable partition PARTUUIDs
selected disk ID
install mode
install root
```

Every destructive operation must call a guard first:

```text
assert_writable_partition <partition>
assert_not_protected <partition>
```

Guarded operations include:

- `sgdisk --delete`
- `sgdisk --new`
- `wipefs`
- `mkfs.fat`
- `mkfs.btrfs`
- `cryptsetup luksFormat`
- partition table rewrites

In restore mode, also assert:

- `/proc/cmdline` contains `copytoram=y`.
- The restore payload is not mounted read-write from the target disk at mutation time.
- Restore ESP, restore payload, and restore state partitions are detected and marked protected from delete/format operations.
- The installed target partitions do not overlap protected partition ranges.

### Power Loss Recovery

A torn install must be recoverable on next boot rather than leaving the disk in a state that needs manual intervention.

- After partition table changes but before LUKS format: the new partition exists but holds no recognizable filesystem or LUKS header. On the next install boot, treat any writable partition without a valid header as discardable and re-run the format step.
- After LUKS format but before archinstall completes: the LUKS header exists but no working OS is installed. On the next boot from restore or ISO, offer to wipe and retry rather than attempting to resume.
- During archinstall: same as above. Resuming partway through a torn pacstrap is more brittle than restarting it.

In dual-boot mode, "wipe and retry" applies only to the writable Omarchy partition. Protected partitions must be re-verified by PARTUUID before any retry runs — power loss does not unlock protected ranges.

## Installer State Contract

The configurator writes `install_mode.sh` for `.automated_script.sh` to source.

Example dual-boot state:

```bash
INSTALL_MODE=dual_boot
INSTALL_ROOT=/mnt/archinstall
DISK=/dev/nvme0n1
BOOT_PARTITION=/dev/nvme0n1p1
ROOT_PARTITION=/dev/nvme0n1p4
PROTECTED_PARTUUIDS="1111-2222 3333-4444 5555-6666"
WRITABLE_PARTUUIDS="7777-8888"
PROMOTE_OMARCHY_BOOT=false
```

Example restore state:

```bash
INSTALL_MODE=restore_install
INSTALL_ROOT=/mnt/archinstall
DISK=/dev/nvme0n1
RESTORE_ESP_PARTITION=/dev/nvme0n1p1
RESTORE_PAYLOAD_PARTITION=/dev/nvme0n1p2
RESTORE_STATE_PARTITION=/dev/nvme0n1p3
INSTALLED_ESP_PARTITION=/dev/nvme0n1p4
ROOT_PARTITION=/dev/nvme0n1p5
PROTECTED_PARTUUIDS="1111-2222 3333-4444 5555-6666"
WRITABLE_PARTUUIDS="7777-8888 9999-aaaa"
PROMOTE_OMARCHY_BOOT=true
```

Keep this file simple shell, generated only by our configurator, and quote values safely.

Restore mode uses `INSTALLED_ESP_PARTITION` (distinct from `RESTORE_ESP_PARTITION`) because two ESPs are present. It also tracks `RESTORE_STATE_PARTITION` separately because that partition is writable state but protected from delete/format operations. Dual-boot mode keeps `BOOT_PARTITION` since only one ESP exists and is unambiguous.

## Archinstall Config

Protected modes generate this disk config and explicitly disable archinstall bootloader writes:

```json
{
    "bootloader": null,
    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt/archinstall"
    }
}
```

Do not include `device_modifications`, `disk_encryption`, or `btrfs_options` in protected modes. The installer handles those before and after archinstall. If archinstall does not accept `"bootloader": null`, Phase 2a must identify the supported equivalent; protected mode must not proceed while archinstall can write boot files or NVRAM entries independently.

Full-disk mode keeps the existing generated `default_layout` config.

**Verify before Phase 2b.** Under `pre_mounted_config`, archinstall still tends to run `genfstab`, write a bootloader, and may write `/etc/crypttab`. The plan currently assumes archinstall acts only as a base-system installer in protected mode; this needs to be confirmed on a throwaway VM. Once confirmed, decide for each step (fstab, crypttab, bootloader, initramfs, kernel cmdline) whether the manual steps below run *instead of* archinstall's behavior, *after* archinstall has had its turn, or with archinstall's step disabled in config. The bootloader outcome is a hard gate: protected mode must have a confirmed way to prevent archinstall from writing Limine files or NVRAM entries. Do not start writing the manual pre/post steps until this is resolved — the unknown sits underneath every downstream step.

## File Changes

### `configs/airootfs/root/configurator`

Add shared detection and policy selection:

- `detect_disk_layout` finds GPT state, partitions, partition ranges, filesystem labels, ESPs, ESP free space, and free regions.
- `detect_existing_os` mounts ESP read-only and checks known vendor paths like `EFI/Microsoft`, `EFI/ubuntu`, `EFI/fedora`, `EFI/GRUB`, and `EFI/systemd`.
- `detect_bitlocker` checks every Windows/basic-data candidate partition on the selected disk for BitLocker. Use `blkid -o value -s TYPE`; BitLocker volumes report `BitLocker` rather than `ntfs`. As a backup, read 8 bytes at offset 3 of the partition — BitLocker volumes contain `-FVE-FS-` instead of `NTFS    `. If any partition reports BitLocker, the dual-boot path aborts before any disk mutation with the message described in the dual-boot policy.
- `detect_restore_layout` finds `OMARCHY_RESTORE` and `OMARCHY_STATE` partitions and validates the restore ESP/payload/state set.
- `find_free_regions` finds unallocated GPT space using `sgdisk` or `parted`. Selection rule: pick the largest single contiguous region of at least 40 GB. Do not concatenate non-contiguous regions.
- `install_mode_form` chooses between full disk, dual boot, and restore install based on context.

User flow:

```text
Normal ISO boot:
  select disk
  detect layout
  if existing OS/install is detected:
    show detected installs and disk layout summary
    always offer "Exclusive install (erase disk)" using the existing full-disk `wipe: true` path
    if existing ESP + enough free space + guardrails pass:
      also offer "Install alongside"
    else:
      show why "Install alongside" is unavailable (for example: no ESP, no suitable free space, BitLocker/FVE, ESP too small)
  else:
    keep current erase-disk flow

Restore boot:
  detect restore disk automatically
  show first-install or reinstall warning
  protect restore ESP/payload/state partitions
  create/recreate installed partitions only
```

Generated files:

- `user_credentials.json`
- `user_configuration.json`
- `user_full_name.txt`
- `user_email_address.txt`
- `install_mode.sh`

### `configs/airootfs/root/.automated_script.sh`

Add shared protected install functions:

- Source `install_mode.sh` after configurator runs.
- Set `INSTALL_ROOT=/mnt/archinstall` for all modes, including full-disk. A single mount root avoids subtle bugs in code touched by both paths and removes one branch from every post-install step.
- Before changing the mount root, grep the live ISO and post-install scripts for hardcoded `/mnt` references and produce an explicit list of call sites. Update each one consciously rather than via a global rename.
- Add `setup_protected_partitions` before archinstall.
- Add `configure_protected_post_install` after archinstall.
- Add cleanup trap for mounts, LUKS mappings, and temporary directories.

Protected pre-install steps:

1. Verify mode-specific guardrails.
2. Create writable partitions if needed.
3. Run `partprobe "$DISK"` and `udevadm settle`.
4. Format installed ESP when policy requires it.
5. `cryptsetup luksFormat` the root partition.
6. `cryptsetup open` root as `omarchy_root`.
7. `mkfs.btrfs /dev/mapper/omarchy_root`.
8. Create Btrfs subvolumes `@`, `@home`, `@log`, and `@pkg`.
9. Mount subvolumes at `$INSTALL_ROOT` with `compress=zstd`.
10. Mount ESP at `$INSTALL_ROOT/efi`; keep `$INSTALL_ROOT/boot` as a normal directory on encrypted root.
11. Generate deterministic fstab with overwrite semantics.

Protected post-install steps:

1. Configure root unlock for the initramfs hook actually in use. Root unlock is driven by initramfs + kernel cmdline, not by `/etc/crypttab`:
   - `encrypt` hook: kernel cmdline `cryptdevice=UUID=<luks-uuid>:omarchy_root root=/dev/mapper/omarchy_root`. No crypttab entry needed for root.
   - `sd-encrypt` hook: write `/etc/crypttab.initramfs` (not `/etc/crypttab`) with the LUKS UUID, and pass `rd.luks.name=<luks-uuid>=omarchy_root root=/dev/mapper/omarchy_root` on the kernel cmdline.
2. Update mkinitcpio hooks for the initramfs mode actually present.
3. Regenerate initramfs in chroot with `mkinitcpio -P`.
4. Install an Omarchy-owned kernel/initramfs sync hook that copies boot artifacts from `/boot` to `/efi/EFI/Omarchy` after kernel or initramfs updates.
5. Run the initial boot artifact sync before writing Limine config.
6. Configure Limine kernel cmdline for encrypted root per the hook chosen above, pointing at namespaced artifacts under `EFI/Omarchy`.
7. Install or update Limine on the selected installed ESP.
8. Run `limine-scan` in chroot when appropriate.
9. Apply mode-specific boot order policy.
10. Leave swapfile creation, `resume` hook, and `resume=` cmdline injection to Omarchy's existing `omarchy-hibernation-setup` post-install hook. Verify `/etc/limine-entry-tool.d/` drop-ins are honored by the Limine config layout written here so that hook works unchanged.

### `builder/archinstall.packages`

Ensure the live environment has the tools needed for protected installs:

- `parted`
- `gptfdisk`
- `btrfs-progs`
- `cryptsetup`
- `dosfstools`
- `efibootmgr`
- `mtools`

`efibootmgr` already exists in this file, but keep it explicit in the protected-install dependency checklist.

### `builder/build-iso.sh`

Add build-time mode support:

- Persist `/root/omarchy_mode` as `normal`, `dual_boot_capable`, or `restore`.
- For restore builds, inject `copytoram=y omarchy.mode=restore` into restore boot entries.
- For restore builds, assert boot entries contain `copytoram=y`.
- For normal ISO builds, keep existing behavior except adding dual-boot capability.

### `bin/omarchy-iso-make`

Add optional build flags:

```text
--restore-image   build omarchy-restore.img.zst factory artifact
```

Keep the existing ISO output path unchanged unless a restore image is explicitly requested.

## Bootloader Policy

### Default Boot Target

For any standalone install (full-disk or restore_install, with or without a restore partition set), installed Omarchy is the default boot target. The persistent `BootOrder` after every successful install or factory reset is:

1. Installed Omarchy
2. Restore (when a restore partition set exists)
3. Firmware fallback

The user should never have to pick Omarchy from a boot menu under normal operation. Restore is reachable but never default. Boot-menu entries inside Limine for restore/reinstall are convenience; they do not replace this NVRAM ordering.

`BootNext` is used only for one-shot transitions (factory reset trigger, post-reset return to installed Omarchy) and must not be used to make Omarchy "stickily" default — that's the job of `BootOrder`. The only temporary exception is an in-progress factory reset: after the restore environment accepts the trigger and before it mutates installed partitions, restore becomes the persistent first boot target until reinstall succeeds.

For dual-boot, the previous OS's firmware order is preserved unless the user explicitly opts to make Omarchy first. Dual-boot is the only mode where Omarchy may not be the firmware default.

### Dual Boot

- Install Omarchy boot files under `EFI/Omarchy` on the shared ESP.
- Do not overwrite existing vendor directories.
- Preserve firmware default boot order unless user opts in.
- Run `limine-scan` so Windows/Linux entries are discoverable from Omarchy's menu. Verify on a real Windows + Linux dual-boot before depending on this — Limine's auto-detection is less battle-tested than GRUB's. If it does not pick them up cleanly, fall back to the firmware boot menu and document the limitation rather than hand-writing entries.
- BitLocker is handled at detection time by aborting the install (see Dual Boot policy). The bootloader path therefore only ever sees Windows volumes with BitLocker fully off/decrypted.

### Restore Install

- Installed Omarchy gets its own ESP and boot entry.
- Restore ESP keeps `EFI/BOOT/BOOTX64.EFI` fallback path.
- After successful install, write `BootOrder` as installed Omarchy first, restore second. Do not reorder on every boot — only after install or factory reset.
- Add a restore/reinstall entry to the installed Limine menu if it can be done cleanly.
- If NVRAM writes fail, rely on fallback boot paths and show a warning. The user can still recover via firmware boot menu.

## Rollout Plan

### Phase 1: Refactor Without Behavior Change

- Introduce `INSTALL_MODE=full_disk`.
- Introduce `$INSTALL_ROOT` and update post-install paths.
- Keep existing full-disk JSON and archinstall behavior.
- Add tests or dry-run checks for config generation.

### Phase 2a: Archinstall pre_mounted_config Spike

Single-purpose spike on a throwaway VM. No production code changes.

- Drive archinstall with a hand-crafted mount tree and `pre_mounted_config`.
- Record exactly what archinstall does: fstab generation, crypttab writes, bootloader install, initramfs regeneration, kernel cmdline writes.
- Prove the protected-mode config disables archinstall bootloader and NVRAM writes, or document the supported replacement setting. This is a release blocker for Phase 2b.
- Decide whether the manual fstab/Limine/initramfs steps in this plan run before, after, or instead of archinstall's own steps.
- Update this plan with the answers before Phase 2b begins. The downstream design depends on this; do not skip.

### Phase 2b: Shared Protected Install Engine

- Add `pre_mounted_config` generation.
- Add manual LUKS, Btrfs, subvolume, mount, fstab, and cleanup logic.
- Add encrypted boot post-install configuration.
- Add namespaced ESP boot artifact sync under `EFI/Omarchy`.
- Keep it behind internal mode switches until validated.

### Phase 3: Dual-Boot UI and Policy

- Add disk layout detection.
- When another install is detected, show an install-mode choice instead of assuming dual boot: "Install alongside" when eligible, and "Exclusive install (erase disk)" using the existing full-disk `wipe: true` path.
- If another install is detected but dual boot is not eligible, explain why and still offer the exclusive install path.
- Add Windows/BitLocker warnings.
- Validate alongside Windows and Linux.

### Phase 4: Restore Install Policy

- Add restore layout detection.
- Add restore partition set protection.
- Add first-install and reinstall flows.
- Validate that restore ESP, payload, and state survive installation and later reinstall.

### Phase 5: Restore Factory Image

- Build `omarchy-restore.img.zst`.
- Add factory flashing instructions or a dedicated factory flasher ISO/PXE workflow.
- Validate first boot from internal disk with no external media.
- Sign `omarchy-restore.img.zst` and the restore payload manifest. Verify in the factory flasher and at restore boot before any disk mutation.
- Add first-boot UUID randomization for cloned restore images before generating installed boot entries or state.
- Decide on Secure Boot before this phase ships. Shipping with SB disabled is a non-starter for some buyers, and BitLocker (when present on a dual-boot machine restored later) reseals against firmware state. Either implement a signed shim/Limine path, or commit to "SB off" with a documented rationale and a way for the user to flip it on later if they have keys.

### Phase 6: Factory Reset

- Implement `omarchy-factory-reset` as the installed-OS staging command: write and fsync the trigger flag, verify/recreate the restore boot entry, set and confirm `BootNext`, then leave the machine ready to boot restore.
- Wire the restore environment to detect the trigger flag and run the reinstall flow non-interactively.
- Set `BootNext` for one-shot transitions and temporary restore-first persistent `BootOrder` during the destructive reset window.
- Validate on `restore_install` machines first (the flow already has a restore partition set).

### Phase 7: Restore Partition for Standalone Installs

- Extend the standalone full-disk install path to create restore ESP + restore payload + restore state + installed ESP + installed root, mirroring the `restore_install` layout.
- Populate restore payload at install time from the live ISO offline mirror.
- Add `--no-restore` opt-out for users who explicitly want the legacy two-partition layout.
- After this phase, every consumer install gets factory reset by default.

## Acceptance Criteria

- Full-disk install behavior remains unchanged through Phase 6. Phase 7 changes the default layout to include a restore partition set; legacy layout remains available via `--no-restore`.
- Dual-boot install preserves existing OS partitions.
- Dual-boot install creates encrypted Omarchy root in free space.
- When another install is detected, the installer offers the current exclusive full-disk wipe path and only offers dual boot when guardrails pass.
- Dual-boot install writes Omarchy boot artifacts only under `EFI/Omarchy` on a shared ESP and leaves existing vendor paths untouched.
- Dual-boot install aborts cleanly when BitLocker/FVE is detected, including suspended BitLocker, before any disk mutation, with an actionable message.
- Restore install preserves restore ESP, restore payload, and restore state partitions.
- Restore install creates or recreates only installed Omarchy partitions.
- Protected modes never generate archinstall config with `wipe: true`.
- Protected modes prevent archinstall from independently writing boot files or NVRAM entries.
- Protected modes abort before destructive operations if a target partition is protected.
- Restore payload integrity is verified with a signed manifest before any restore-triggered disk mutation.
- Installed Omarchy boots and requires LUKS unlock.
- Installed Omarchy is the default firmware boot target for any standalone install (full-disk or restore_install).
- Restore boot remains available after first install but is never the default.
- Reinstall from restore works without external media.
- `omarchy-factory-reset` from the installed OS leaves the machine staged exactly like a freshly prepared restore-boot device: trigger flag durable on restore state, restore boot entry present, and `BootNext` pointing at restore. No installed partitions are destroyed before the next restore boot.
- A subsequent restore boot from that staged state wipes installed partitions, reinstalls a fresh Omarchy, and lands the user back in the installed OS without external media. Restore ESP, payload, and state partitions survive intact.
- Factory reset refuses to run when no complete restore partition set is present (e.g. dual-boot, `--no-restore` install).

## Validation Matrix

### Regression

1. Full-disk UEFI install on empty disk.
2. Current normal ISO boot menu and default install behavior.
3. Existing offline package installation flow.

### Dual Boot

1. Windows + free space + existing ESP (BitLocker off).
2. Windows + BitLocker enabled — installer must abort before any disk mutation with a clear "turn off BitLocker and wait for decryption" message.
3. Windows + BitLocker suspended — installer must still abort, because v1 treats any BitLocker/FVE signature as unsafe.
4. Linux distro + free space + existing ESP.
5. GPT disk with no free space.
6. ESP below total-size warning threshold.
7. ESP below total-size minimum threshold.
8. ESP large enough by total size but below free-space minimum.
9. Multiple free regions; choose largest suitable region.
10. Firmware boot order preservation.

### Restore

1. Factory image written to larger virtual disk.
2. First boot from internal restore ESP.
3. First install randomizes cloned disk/partition/filesystem UUIDs before creating installed boot entries.
4. First install creates installed ESP/root and preserves restore ESP, payload, and state.
5. Installed OS boots with encrypted root.
6. Installed Omarchy is the firmware default; restore is reachable but not default.
7. Restore boot still works after installed OS exists.
8. Reinstall formats only the installed Omarchy partitions in place; PARTUUIDs unchanged.
9. Restore mode without `copytoram=y` aborts before disk mutation.
10. Missing restore payload or restore state aborts before disk mutation.
11. NVRAM boot entry write failure still leaves fallback boot path usable.

### Factory Reset

1. `omarchy-factory-reset` from installed OS leaves the system staged for restore boot: trigger flag durable on restore state, restore boot entry present, and `BootNext` confirmed.
2. No installed partitions are destroyed before the staged system actually boots into restore.
3. Booting into restore from the staged state reinstalls and returns to a fresh installed Omarchy as the default-booted OS.
4. Trigger flag is deleted before the post-reset reboot. Machine does not loop.
5. Reset interrupted between trigger and restore boot: next normal boot still goes to installed Omarchy (because `BootNext` is one-shot).
6. Reset interrupted during reinstall (power loss): persistent temporary restore-first `BootOrder` boots restore again and re-runs the flow from the trigger flag/reset-in-progress state.
7. Reset refused when no complete restore partition set is detected.
8. Reset refused when signed restore payload verification fails.
9. Reset refused when running without root.
10. Reset refused when restore boot entry is missing from NVRAM and cannot be repopulated from fallback.

### Negative Safety Tests

1. Attempt to format protected restore ESP.
2. Attempt to format protected restore payload.
3. Attempt to format protected restore state.
4. Attempt to format existing Windows partition in dual-boot mode.
5. Partition overlap with protected range.
6. Power loss before partition creation.
7. Power loss after partition creation but before archinstall.
8. Power loss during archinstall.

## Open Questions

- Restore payload size: full offline mirror versus smaller network-capable restore image. Affects whether the consumer ISO's restore-partition default in Phase 7 is feasible at typical disk sizes.
- Restore update strategy after devices ship.
- Whether restore should also expose diagnostics / log upload alongside factory reset.
- Whether factory reset should preserve `/home` user data optionally, or always wipe. v1 always wipes (simpler, matches user expectation of "factory reset"); a "keep my files" variant could land later.

Resolved:

- User-facing reset staging command: yes, `omarchy-factory-reset` (Phase 6).
- Secure Boot: promoted to Phase 5 decision gate.
- Btrfs subvolume layout: protected modes use the current full-disk layout, `@`, `@home`, `@log`, and `@pkg`. The `/swap` subvolume for hibernation is created post-install by `omarchy-hibernation-setup` and is not predeclared at install time.

## Definition of Done

- One shared protected-partition implementation supports both dual-boot and restore install policies.
- Full-disk installs remain stable through Phase 6 and gain a default restore partition set in Phase 7.
- Dual-boot users can install alongside existing OSes without data loss.
- OEM devices can boot internal restore on first power-on, install Omarchy, and retain restore for future reinstall.
- All destructive operations are guarded by protected partition checks.
- Installed Omarchy is the firmware default boot target on every standalone install.
- `omarchy-factory-reset` stages any standalone install to boot internal restore without external media; the restore-triggered reinstall returns the user to a fresh installed Omarchy.
- VM and hardware validation matrices pass.
