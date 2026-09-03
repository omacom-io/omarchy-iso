# LVM install mode

Install Omarchy into logical volumes that already exist, on a machine whose disk is already an LVM physical volume. The target case is a multi-boot workstation: one volume group holds the current distribution's root, a large shared `/home`, and swap; the owner has carved out a spare logical volume for Omarchy and wants Omarchy in it without touching anything else in the group.

Today that install is impossible. `disk_form` offers whole disks only, and both install modes write a GPT partition table. A disk fully consumed by a PV reports no free space, so `requires_full_disk_install` forces the full-disk path, whose first act is to overwrite the volume group.

## What already exists

The installer is closer to this than it looks. The free-space mode is already non-destructive to its neighbours and already hands archinstall a pre-mounted target:

- `run_partition_execute` (configurator) creates, formats and mounts everything under `/mnt` itself, then writes `"config_type": "pre_mounted_config"` with `"mode": "protected"`.
- `archinstall_adapter.py` honours that: `Pre_mount` skips `mount_ordered_layout`, because the mounts are already standing.
- `_write_pre_mounted_fstab` and `_write_pre_mounted_crypttab` (phases_impl) write the target's fstab and crypttab from an explicit `omarchy_install.storage` intent rather than from a scan.
- `create_factory_snapshot` already degrades gracefully when the root is not btrfs.

So LVM mode is a third producer of the same pre-mounted handoff. Everything downstream — Limine, the UKI build, `omarchy-apply-system` — is unchanged and untested-against only in the sense that it never sees a device-mapper path today.

## Design

### Root stays btrfs

The chosen root LV is formatted `btrfs` and given the same `@`, `@log`, `@pkg` subvolumes as every other Omarchy install. This is the single most important scoping decision in this plan.

Reusing whatever filesystem the LV already holds would sound friendlier, but it would cost snapper, the Limine snapshot menu and `omarchy-system-factory-reset`, and it would force `_write_pre_mounted_fstab` and `_validate_pre_mounted_filesystems` to be rewritten around an arbitrary filesystem. Formatting the root LV keeps both functions nearly as they are, keeps every Omarchy feature, and matches what the owner expects: they nominated a *spare* volume.

`@home` is the exception, and it is the whole point of the mode — see below.

### Reuse, never format, everything else

Only the root LV is formatted. Every other volume the owner nominates is mounted as it stands:

| Role       | Source                     | Formatted |
| ---------- | -------------------------- | --------- |
| `/`        | chosen LV                  | yes, btrfs `@` |
| `/home`    | chosen LV, or root `@home` | never     |
| swap       | chosen LV, optional        | never     |
| ESP        | existing partition         | never     |

When the owner nominates an existing `/home` volume, the `@home` subvolume is not created and its fstab line is replaced by one naming the chosen volume. When they do not, the mode behaves exactly like the free-space path.

The ESP is the sharpest edge. The free-space path always creates its own ESP and deliberately refuses to adopt the Windows one; that reasoning is about Windows reclaiming the partition, and does not carry over to an ESP that a sibling Linux owns. Limine installs under `/EFI/limine` with its own `efibootmgr` entry, so it coexists with `systemd-boot` under `/EFI/systemd` rather than displacing it. The mode therefore adopts an existing ESP and never runs `mkfs.fat` on it. **This needs verifying against limine's installer before the PR is opened** — it is the one step that can cost the owner their working system.

### The initramfs needs the lvm2 hook

Without it the target cannot find its own root. Two parts:

- `lvm2` joins the package list for this mode.
- A drop-in adds the `lvm2` hook to `HOOKS`, before `encrypt` (LUKS-on-LV) and before `filesystems`.

The drop-in's **name is load-bearing**. `omarchy-settings` ships `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, which *assigns* `HOOKS=(...)` outright. mkinitcpio sources drop-ins in lexical order, so a `99-` prefix — the convention the provisioning-key drop-in uses — is sourced *before* `omarchy_hooks.conf` and silently discarded. That drop-in survives only because it uses `FILES+=`. The LVM drop-in must sort after, hence `zz-omarchy-lvm.conf`.

### Encryption

LUKS on the root LV is supported and is the default, matching every other mode. The `cryptsetup luksFormat` call is identical to the free-space path's; only the device differs. Hook order becomes `... block lvm2 encrypt filesystems ...`, since the PV is not itself encrypted and the volume group must be assembled before the mapper device exists.

An already-encrypted PV (LUKS containing the VG) is out of scope. The installer would have to unlock a container it did not create, and the owner is better served booting the existing system and running the install from there.

## Changes

### `configs/airootfs/usr/share/omarchy-iso/lvm.sh` (new)

Pure discovery helpers, sourced by the configurator and by the unit tests, mirroring how `disk-partitioning.sh` is structured. No side effects, so they are testable without a disk:

- `disk_has_lvm <disk>` — does this disk carry a PV with a volume group
- `volume_groups_on_disk <disk>`
- `logical_volumes <vg>` — name, size, current filesystem, current label
- `device_is_busy <device>` — the guard that keeps the running system's own root off the candidate list. Takes any block device, not only a logical volume: the ESP is checked through it too
- `describe_lv <lv>` — the display string for the picker

### `configs/airootfs/root/configurator`

- `install_mode_form` gains "Use existing LVM volumes" when `disk_has_lvm "$disk"`.
- `run_lvm_decide` — pick the VG, then root / `/home` / swap / ESP; refuse any device that is currently mounted or that backs the live system; refuse an adopted `/home` or swap volume that carries no filesystem, since this mode mounts them rather than creating them; confirm; set the same globals `run_lvm_execute` reads. Every one of those refusals happens here, before `run_lvm_execute` formats anything — a check deferred to mount time fires after the root volume is already erased.
- `run_lvm_execute` — format and mount root, mount the rest, emit `user_configuration.json` with `mode: protected`, `config_type: pre_mounted_config`, and a `storage` block carrying `home_device` and `swap_device`.
- `select_installation` and the `install_target` dispatch gain the `lvm` branch.

### `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`

- `_write_pre_mounted_fstab` — emit the `/home` line from `storage.home_device` when set, otherwise the `@home` subvolume line as today; append a swap line when `storage.swap_device` is set.
- `_validate_pre_mounted_filesystems` — assert the `/home` and swap UUIDs when those devices are set.
- A `_write_lvm_mkinitcpio_dropin` step writing `zz-omarchy-lvm.conf`.

### `test/unit/lvm-discovery-test.sh` (new)

The discovery helpers against fixture output, following `partition-numbering-test.sh`. The mount guard is the case that matters: nominating a volume the live system is using must be refused, not merely warned about.

## Open questions for review

1. **ESP adoption.** Verified assumption pending: that `limine-install` writes only `/EFI/limine` and its own NVRAM entry, leaving a sibling bootloader's directory and entries intact.
2. **Volumes outside the group.** Should the mode allow a `/home` on a plain partition, or only on an LV in the same VG? Only-in-VG is simpler to explain and to validate.
3. **`swap: true`** in the emitted config. With a real swap volume the archinstall-level swap flag likely wants to be `false`, but its exact effect on a pre-mounted target is unconfirmed. This is an open question shipped inside the code rather than beside it, and it should be settled before the PR is opened.

## Adversarial review

Reviewed against `2673c61...HEAD` by a reviewer with no access to the author's reasoning. Findings acted on:

- **The ESP was the one runtime-chosen device with no in-use check.** Every logical volume went through `choose_lv`, which refuses a busy selection; the ESP picker did not. This was the site missing from the mode's own stated invariant.
- **An adopted `/home` or swap volume with no filesystem was accepted**, and failed at mount time — which is after `run_lvm_execute` has already formatted the root volume. Both are now refused during the decide half.
- **`_lvm_on_disk` matched by bare prefix.** `/dev/nvme0n10p1`, and the whole disk `/dev/nvme0n10`, both matched disk `/dev/nvme0n1`, so the mode could offer to install into a volume group living on a different disk. The original test covered `sdaa1` against `sda`, which does not catch it.

Checked and found closed, recorded so the next reader does not re-derive them:

- `builder/build-iso.sh:66` copies `configs/` wholesale, so `lvm.sh` reaches the ISO. The merge gate builds the ISO and never runs `./test/all`, so this needed confirming separately.
- `builder/build-iso.sh:121` already installs `lvm2` in the live environment, so `pvs`, `lvs` and `vgchange` exist when the configurator calls them. Without it the mode would never appear, silently.
