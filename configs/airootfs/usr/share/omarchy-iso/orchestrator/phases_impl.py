"""Concrete phase implementations.

Phase ordering (full-disk):

    prepare_live           → pacman-key init, disk cleanup, load configurator
                             handlers (archinstall patch happens in the
                             wrapper before Python imports archinstall)
    arch_install_full      → archinstall-driven install (partition, base,
                             bootloader, write limine config, early omarchy
                             pkgs, useradd, runtime omarchy pkgs)
    run_chroot_finalizer   → bind mounts + sudoers shim + arch-chroot finalize.sh
    configure_login        → sddm autologin for unencrypted installs
    validate_boot_full     → assert UKI / limine.conf / kernel cmdline are sane
    finish                 → reboot prompt

Phase ordering (protected / pre-mounted):

    prepare_live              → same, minus disk cleanup
    verify_protected_mounts   → confirm target + ESP are mounted; load
                                /root/protected_install.json into ctx.state
    arch_install_base         → archinstall used as pacstrap + users +
                                packages driver only; no bootloader,
                                no fstab, no mkinitcpio
    configure_protected_boot  → Omarchy-owned fstab/crypttab/mkinitcpio/
                                bootloader — implemented in Step 8
    run_chroot_finalizer      → same
    configure_login           → same
    validate_boot_protected   → implemented in Step 8
    finish                    → same
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

from . import archinstall_adapter as arch
from .context import InstallContext
from .ui import confirm, info


# Packages installed BEFORE useradd. omarchy-settings populates /etc/skel so
# the user's home gets seeded correctly. omarchy-installer is INTENTIONALLY
# absent — it's live-ISO-only install tooling, never installed on the target.
# finalize.sh + install/ scripts get copied to /mnt/tmp/ in run_chroot_finalizer.
EARLY_PACKAGES = [
    "base-devel",
    "git",
    "omarchy-keyring",
    "omarchy-settings",
]


# ─────────────────────────────────────────────────────────────────────────────
# prepare_live: ready the live ISO for the install — pacman keyring init,
# tear down any previous holders on the install disk (via the bash helper),
# then parse the configurator output.
#
# archinstall is patched in the wrapper (omarchy-iso-install) BEFORE Python
# imports it, so no patching happens here.
# ─────────────────────────────────────────────────────────────────────────────

def prepare_live(ctx: InstallContext) -> None:
    info("› initializing pacman keyrings")
    subprocess.run(["pacman-key", "--init"], check=True)
    subprocess.run(["pacman-key", "--populate", "archlinux"], check=True)
    subprocess.run(["pacman-key", "--populate", "omarchy"], check=True)
    subprocess.run(["pacman", "-Sy", "--noconfirm"], check=True)

    if ctx.is_protected:
        info("› protected mode: skipping whole-disk cleanup")
    else:
        disk = _install_disk(ctx)
        if disk:
            info(f"› cleaning up holders on install disk: {disk}")
            subprocess.run(["omarchy-iso-cleanup-disk", disk], check=True)

    info("› loading configurator output")
    ctx.state["arch_config_handler"] = arch.load_arch_config(
        ctx.config_path, ctx.creds_path
    )
    ctx.state["mirror_handler"] = arch.make_mirror_handler(offline=True)


def _install_disk(ctx: InstallContext) -> str | None:
    """Return the device path of the disk being wiped, or None for
    pre_mounted / no-wipe configs."""
    config = ctx.user_configuration
    for mod in config.get("disk_config", {}).get("device_modifications", []):
        if mod.get("wipe"):
            return mod.get("device")
    return None


# ─────────────────────────────────────────────────────────────────────────────
# arch_install_full: everything inside a single Installer context manager.
# Reorders guided.py's perform_installation() so our limine config write
# lands between add_bootloader and the first add_additional_packages call,
# and user creation happens AFTER early omarchy packages populate /etc/skel.
# ─────────────────────────────────────────────────────────────────────────────

def arch_install_full(ctx: InstallContext) -> None:
    """Full-disk install: archinstall owns disk layout + bootloader."""
    handler = ctx.state["arch_config_handler"]
    mirror_handler = ctx.state["mirror_handler"]
    config = handler.config

    info("› partitioning + formatting + encrypting")
    arch.perform_filesystem_operations(config)

    info("› opening installer context")
    with arch.open_installer(config, ctx.target, silent=True) as installer:
        if not arch.is_pre_mount(config):
            installer.mount_ordered_layout()

        installer.sanity_check(
            offline=True,
            skip_ntp=True,
            skip_wkd=True,
        )

        if not arch.is_pre_mount(config) and arch.is_encrypted(config):
            installer.generate_key_files()

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=False)

        info("› installing base system")
        installer.minimal_installation(
            optional_repositories=(
                config.mirror_config.optional_repositories
                if config.mirror_config else []
            ),
            mkinitcpio=True,
            hostname=config.hostname,
            locale_config=config.locale_config,
            pacman_config=config.pacman_config,
        )

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=True)

        if config.swap and config.swap.enabled:
            installer.setup_swap(algo=config.swap.algorithm)

        info("› installing bootloader (Limine)")
        if config.bootloader_config:
            installer.add_bootloader(
                config.bootloader_config.bootloader,
                config.bootloader_config.uki,
                config.bootloader_config.removable,
            )

        info("› writing Limine config (so limine-mkinitcpio-hook fires correctly)")
        _write_limine_defaults(ctx)

        info(f"› installing early Omarchy packages: {', '.join(EARLY_PACKAGES)}")
        installer.add_additional_packages(EARLY_PACKAGES)

        info("› creating user (with /etc/skel populated)")
        if config.auth_config and config.auth_config.users:
            installer.create_users(config.auth_config.users)

        info("› installing Omarchy runtime + omarchy-base.packages")
        installer.add_additional_packages(_runtime_package_list(ctx))

        # Standard arch finishers.
        if config.timezone:
            installer.set_timezone(config.timezone)
        if config.ntp:
            installer.activate_time_synchronization()
        if root := arch.root_user(config):
            installer.set_user_password(root)

        installer.genfstab()


def _write_limine_defaults(ctx: InstallContext) -> None:
    if not arch.is_limine(ctx.state["arch_config_handler"].config):
        return

    limine_conf = ctx.target / "boot" / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} not found after add_bootloader")

    cmdline = _extract_cmdline(limine_conf)
    if not cmdline.strip():
        raise RuntimeError("Could not extract kernel cmdline from limine.conf")
    if "root=" not in cmdline:
        raise RuntimeError(f"Extracted cmdline has no root=: {cmdline!r}")

    # Template lives in omarchy-installer's install tree, present on the live
    # ISO via the omarchy-installer package.
    template = ctx.omarchy_path / "install" / "assets" / "limine" / "default.conf"
    if not template.exists():
        template = ctx.omarchy_path / "default" / "limine" / "default.conf"
    if not template.exists():
        raise RuntimeError(f"Limine template not found at {template}")

    default_limine = ctx.target / "etc" / "default" / "limine"
    default_limine.parent.mkdir(parents=True, exist_ok=True)
    default_limine.write_text(template.read_text().replace("@@CMDLINE@@", cmdline))

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    kernel_cmdline.parent.mkdir(parents=True, exist_ok=True)
    kernel_cmdline.write_text(cmdline + "\n")


def _extract_cmdline(limine_conf: Path) -> str:
    for line in limine_conf.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("cmdline:"):
            return stripped[len("cmdline:"):].strip()
    return ""


def _runtime_package_list(ctx: InstallContext) -> list[str]:
    """omarchy + every package in install/omarchy-base.packages that isn't
    already in EARLY_PACKAGES."""
    base_pkgs_file = ctx.omarchy_path / "install" / "omarchy-base.packages"
    pkgs = ["omarchy"]
    early = set(EARLY_PACKAGES)
    for raw in base_pkgs_file.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s not in early and s not in pkgs:
            pkgs.append(s)
    return pkgs


# ─────────────────────────────────────────────────────────────────────────────
# verify_protected_mounts: confirm the configurator pre-mounted everything
# we need under ctx.target and load /root/protected_install.json so
# configure_protected_boot has the partition intent to act on.
# ─────────────────────────────────────────────────────────────────────────────

PROTECTED_INTENT_PATH = Path("/root/protected_install.json")


def verify_protected_mounts(ctx: InstallContext) -> None:
    target = ctx.target
    if not _is_mountpoint(target):
        raise RuntimeError(f"protected mode: {target} is not a mountpoint")

    boot_mp = target / "boot"
    efi_mp = target / "efi"
    if not (_is_mountpoint(boot_mp) or _is_mountpoint(efi_mp)):
        raise RuntimeError(
            f"protected mode: no ESP mounted under {target} (checked {boot_mp}, {efi_mp})"
        )

    if not PROTECTED_INTENT_PATH.exists():
        raise RuntimeError(
            f"protected mode: expected partition intent at {PROTECTED_INTENT_PATH} "
            "(configurator should have written it)"
        )

    intent = json.loads(PROTECTED_INTENT_PATH.read_text())
    for key in ("esp_mount", "esp_path", "luks_uuid", "root_device", "kernel"):
        if key not in intent:
            raise RuntimeError(
                f"protected mode: {PROTECTED_INTENT_PATH} missing key '{key}'"
            )
    ctx.state["protected"] = intent
    info(f"› protected intent loaded: kernel={intent['kernel']} esp={intent['esp_mount']}")


def _is_mountpoint(path: Path) -> bool:
    res = subprocess.run(
        ["findmnt", "-rn", str(path)],
        capture_output=True,
        text=True,
    )
    return res.returncode == 0 and bool(res.stdout.strip())


# ─────────────────────────────────────────────────────────────────────────────
# arch_install_base: archinstall used as a pacstrap + base-config driver only.
# No disk layout, no bootloader, no fstab, no mkinitcpio (step 8 owns those).
# ─────────────────────────────────────────────────────────────────────────────

def arch_install_base(ctx: InstallContext) -> None:
    """Protected install base: archinstall handles pacstrap + users + packages
    only. Bootloader, fstab, mkinitcpio, crypttab are owned by
    configure_protected_boot."""
    handler = ctx.state["arch_config_handler"]
    mirror_handler = ctx.state["mirror_handler"]
    config = handler.config

    info("› opening installer context (pre-mounted target)")
    with arch.open_installer(config, ctx.target, silent=True) as installer:
        installer.sanity_check(
            offline=True,
            skip_ntp=True,
            skip_wkd=True,
        )

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=False)

        info("› installing base system (mkinitcpio deferred to configure_protected_boot)")
        installer.minimal_installation(
            optional_repositories=(
                config.mirror_config.optional_repositories
                if config.mirror_config else []
            ),
            mkinitcpio=False,
            hostname=config.hostname,
            locale_config=config.locale_config,
            pacman_config=config.pacman_config,
        )

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=True)

        if config.swap and config.swap.enabled:
            installer.setup_swap(algo=config.swap.algorithm)

        info(f"› installing early Omarchy packages: {', '.join(EARLY_PACKAGES)}")
        installer.add_additional_packages(EARLY_PACKAGES)

        info("› creating user (with /etc/skel populated)")
        if config.auth_config and config.auth_config.users:
            installer.create_users(config.auth_config.users)

        info("› installing Omarchy runtime + omarchy-base.packages")
        installer.add_additional_packages(_runtime_package_list(ctx))

        if config.timezone:
            installer.set_timezone(config.timezone)
        if config.ntp:
            installer.activate_time_synchronization()
        if root := arch.root_user(config):
            installer.set_user_password(root)


# ─────────────────────────────────────────────────────────────────────────────
# configure_protected_boot: Omarchy-owned fstab/crypttab/mkinitcpio/bootloader.
#
# Order:
#   1. fstab    — written from our known mount intent (no genfstab)
#   2. crypttab + mkinitcpio.conf — encrypt/btrfs hooks + initramfs btrfs deps
#   3. mkinitcpio -P — generate /boot/initramfs-{kernel}{,-fallback}.img
#   4. Limine into EFI/Omarchy — never touches EFI/Microsoft or EFI/BOOT
#   5. efibootmgr entry, BootOrder preserves whatever was there + Omarchy first
#   6. Sanity: Windows entry must survive
# ─────────────────────────────────────────────────────────────────────────────

def configure_protected_boot(ctx: InstallContext) -> None:
    protected = ctx.state["protected"]

    info("› ensuring limine + efibootmgr installed in target")
    subprocess.run(
        ["arch-chroot", str(ctx.target), "pacman", "-S",
         "--needed", "--noconfirm", "limine", "efibootmgr"],
        check=True,
    )

    info("› writing /etc/fstab")
    _write_fstab(ctx, protected)

    if protected.get("luks_uuid"):
        info("› writing /etc/crypttab.initramfs")
        _write_crypttab(ctx, protected)

    info("› editing /etc/mkinitcpio.conf")
    _edit_mkinitcpio_conf(ctx, protected)

    info("› running mkinitcpio -P")
    _run_mkinitcpio(ctx)

    info("› capturing efibootmgr state pre-install")
    pre_state = _read_efibootmgr()
    windows_before = _find_label_entries(pre_state["entries"], "Windows")

    info("› installing Limine into EFI/Omarchy")
    _install_limine(ctx, protected)

    info("› registering efibootmgr entry")
    _register_efibootmgr_entry(ctx, protected, pre_state)

    info("› verifying Windows boot entry survived")
    post_state = _read_efibootmgr()
    windows_after = _find_label_entries(post_state["entries"], "Windows")
    if windows_before and not windows_after:
        raise RuntimeError(
            "Windows boot entry disappeared during Limine install — aborting"
        )


# ── fstab ────────────────────────────────────────────────────────────────────

def _btrfs_root_device(protected: dict) -> str:
    """Device that holds the btrfs filesystem (mapper for encrypted, raw
    partition for plain)."""
    if protected.get("luks_uuid"):
        return "/dev/mapper/omarchy_root"
    return protected["root_device"]


def _blkid_uuid(device: str) -> str:
    res = subprocess.run(
        ["blkid", "-s", "UUID", "-o", "value", device],
        capture_output=True, text=True, check=True,
    )
    uuid = res.stdout.strip()
    if not uuid:
        raise RuntimeError(f"blkid returned no UUID for {device}")
    return uuid


def _esp_device(ctx: InstallContext, protected: dict) -> str:
    esp_mp = ctx.target / protected["esp_mount"].lstrip("/")
    res = subprocess.run(
        ["findmnt", "-n", "-o", "SOURCE", str(esp_mp)],
        capture_output=True, text=True, check=True,
    )
    dev = res.stdout.strip()
    if not dev:
        raise RuntimeError(f"could not resolve ESP device at {esp_mp}")
    return dev


def _write_fstab(ctx: InstallContext, protected: dict) -> None:
    btrfs_dev = _btrfs_root_device(protected)
    btrfs_uuid = _blkid_uuid(btrfs_dev)
    esp_dev = _esp_device(ctx, protected)
    esp_uuid = _blkid_uuid(esp_dev)
    esp_mount = protected["esp_mount"]

    btrfs_opts = "noatime,compress=zstd,subvol="
    lines = [
        "# /etc/fstab — generated by omarchy installer (protected mode)",
        "# <device>  <mount>  <fs>  <options>  <dump>  <pass>",
        f"UUID={btrfs_uuid}  /                      btrfs  {btrfs_opts}@       0 0",
        f"UUID={btrfs_uuid}  /home                  btrfs  {btrfs_opts}@home   0 0",
        f"UUID={btrfs_uuid}  /var/log               btrfs  {btrfs_opts}@log    0 0",
        f"UUID={btrfs_uuid}  /var/cache/pacman/pkg  btrfs  {btrfs_opts}@pkg    0 0",
        f"UUID={esp_uuid}  {esp_mount}                   vfat   umask=0077              0 2",
        "",
    ]
    fstab = ctx.target / "etc" / "fstab"
    fstab.write_text("\n".join(lines))


# ── crypttab ─────────────────────────────────────────────────────────────────

def _write_crypttab(ctx: InstallContext, protected: dict) -> None:
    luks_uuid = protected["luks_uuid"]
    crypttab = ctx.target / "etc" / "crypttab.initramfs"
    crypttab.write_text(f"omarchy_root  UUID={luks_uuid}  none  luks,discard\n")


# ── mkinitcpio.conf ──────────────────────────────────────────────────────────

def _edit_mkinitcpio_conf(ctx: InstallContext, protected: dict) -> None:
    conf = ctx.target / "etc" / "mkinitcpio.conf"
    text = conf.read_text()

    if protected.get("luks_uuid"):
        hooks = (
            "HOOKS=(base udev autodetect microcode modconf kms keyboard "
            "keymap consolefont block encrypt filesystems fsck)"
        )
    else:
        hooks = (
            "HOOKS=(base udev autodetect microcode modconf kms keyboard "
            "keymap consolefont block filesystems fsck)"
        )

    text = _replace_assignment(text, "HOOKS", hooks)
    text = _replace_assignment(text, "MODULES", "MODULES=(btrfs)")
    text = _replace_assignment(text, "BINARIES", "BINARIES=(/usr/bin/btrfs)")

    conf.write_text(text)


def _replace_assignment(text: str, key: str, new_line: str) -> str:
    """Replace a `KEY=(...)` line in mkinitcpio.conf-style text. If the key
    isn't present, append the line."""
    pattern = re.compile(rf"^{re.escape(key)}=\(.*\)\s*$", re.MULTILINE)
    if pattern.search(text):
        return pattern.sub(new_line, text, count=1)
    if not text.endswith("\n"):
        text += "\n"
    return text + new_line + "\n"


# ── mkinitcpio ───────────────────────────────────────────────────────────────

def _run_mkinitcpio(ctx: InstallContext) -> None:
    subprocess.run(
        ["arch-chroot", str(ctx.target), "mkinitcpio", "-P"],
        check=True,
    )


# ── Limine ───────────────────────────────────────────────────────────────────

LIMINE_CONF_TEMPLATE = """\
timeout: 3
default_entry: 1
interface_branding: Omarchy Bootloader

/Omarchy Linux
    protocol: linux
    path: uuid({btrfs_uuid}):/@/boot/vmlinuz-{kernel}
    cmdline: {cmdline}
    module_path: uuid({btrfs_uuid}):/@/boot/initramfs-{kernel}.img

/Omarchy Linux (fallback)
    protocol: linux
    path: uuid({btrfs_uuid}):/@/boot/vmlinuz-{kernel}
    cmdline: {cmdline}
    module_path: uuid({btrfs_uuid}):/@/boot/initramfs-{kernel}-fallback.img
"""


def _omarchy_esp_path(ctx: InstallContext, protected: dict) -> Path:
    esp_mount = ctx.target / protected["esp_mount"].lstrip("/")
    return esp_mount / protected["esp_path"].lstrip("/")


def _build_cmdline(protected: dict, btrfs_uuid: str) -> str:
    if protected.get("luks_uuid"):
        return (
            f"cryptdevice=UUID={protected['luks_uuid']}:omarchy_root "
            "root=/dev/mapper/omarchy_root rw "
            "rootflags=subvol=@ rootfstype=btrfs quiet splash"
        )
    return (
        f"root=UUID={btrfs_uuid} rw "
        "rootflags=subvol=@ rootfstype=btrfs quiet splash"
    )


def _install_limine(ctx: InstallContext, protected: dict) -> None:
    src = ctx.target / "usr" / "share" / "limine" / "BOOTX64.EFI"
    if not src.exists():
        raise RuntimeError(
            f"Limine EFI binary not found at {src} — limine package missing in target"
        )

    omarchy_esp = _omarchy_esp_path(ctx, protected)
    omarchy_esp.mkdir(parents=True, exist_ok=True)

    dst = omarchy_esp / "BOOTX64.EFI"
    shutil.copy2(src, dst)

    btrfs_uuid = _blkid_uuid(_btrfs_root_device(protected))
    cmdline = _build_cmdline(protected, btrfs_uuid)
    conf = LIMINE_CONF_TEMPLATE.format(
        btrfs_uuid=btrfs_uuid,
        kernel=protected["kernel"],
        cmdline=cmdline,
    )
    (omarchy_esp / "limine.conf").write_text(conf)


# ── efibootmgr ───────────────────────────────────────────────────────────────

_BOOT_ENTRY_RE = re.compile(r"^Boot([0-9A-Fa-f]{4})\*?\s+(.*)$")
_BOOT_ORDER_RE = re.compile(r"^BootOrder:\s*(.*)$")


def _read_efibootmgr() -> dict:
    res = subprocess.run(
        ["efibootmgr"],
        capture_output=True, text=True, check=True,
    )
    entries: dict[str, str] = {}
    order: list[str] = []
    for line in res.stdout.splitlines():
        m = _BOOT_ENTRY_RE.match(line)
        if m:
            entries[m.group(1).upper()] = m.group(2).strip()
            continue
        m = _BOOT_ORDER_RE.match(line)
        if m:
            order = [n.strip().upper() for n in m.group(1).split(",") if n.strip()]
    return {"entries": entries, "order": order, "raw": res.stdout}


def _find_label_entries(entries: dict[str, str], needle: str) -> list[str]:
    return [num for num, label in entries.items() if needle.lower() in label.lower()]


def _split_partition_device(part_dev: str) -> tuple[str, int]:
    parent = subprocess.run(
        ["lsblk", "-ndo", "PKNAME", part_dev],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not parent:
        raise RuntimeError(f"could not find parent disk for {part_dev}")
    part_num = subprocess.run(
        ["lsblk", "-ndo", "PARTN", part_dev],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not part_num:
        raise RuntimeError(f"could not find partition number for {part_dev}")
    return f"/dev/{parent}", int(part_num)


def _register_efibootmgr_entry(
    ctx: InstallContext, protected: dict, pre_state: dict
) -> None:
    esp_dev = _esp_device(ctx, protected)
    disk, part_num = _split_partition_device(esp_dev)

    # Clean up any stale "Omarchy Linux" entries so we don't accumulate dupes
    # across re-installs.
    for num in _find_label_entries(pre_state["entries"], "Omarchy Linux"):
        subprocess.run(
            ["efibootmgr", "--bootnum", num, "--delete-bootnum"],
            check=False, capture_output=True,
        )

    subprocess.run(
        [
            "efibootmgr",
            "--create",
            "--disk", disk,
            "--part", str(part_num),
            "--label", "Omarchy Linux",
            "--loader", "\\EFI\\Omarchy\\BOOTX64.EFI",
            "--unicode",
        ],
        check=True, capture_output=True, text=True,
    )

    post = _read_efibootmgr()
    new_omarchy = _find_label_entries(post["entries"], "Omarchy Linux")
    if not new_omarchy:
        raise RuntimeError(
            "efibootmgr --create reported success but no Omarchy Linux entry found"
        )
    omarchy_num = new_omarchy[0]

    # Preserve the original BootOrder, but put Omarchy first.
    keep = [n for n in pre_state["order"] if n not in new_omarchy]
    new_order = ",".join([omarchy_num, *keep])
    subprocess.run(
        ["efibootmgr", "--bootorder", new_order],
        check=True, capture_output=True,
    )


# ─────────────────────────────────────────────────────────────────────────────
# run_chroot_finalizer:
#  1. point the target at the offline pacman.conf so chroot pacman uses the
#     bundled mirror
#  2. bind-mount the offline mirror + /opt/packages into /mnt so chroot sees
#     the same paths
#  3. write a passwordless-sudo shim for the install user (finalize.sh's
#     scripts run as the user and shell out to sudo repeatedly)
#  4. copy the omarchy install tooling into /mnt/tmp/omarchy-install (the
#     target never gets the omarchy-installer package installed)
#  5. arch-chroot -u $user → /tmp/omarchy-install/finalize.sh
# ─────────────────────────────────────────────────────────────────────────────

def run_chroot_finalizer(ctx: InstallContext) -> None:
    # 1: offline pacman.conf
    shutil.copy("/etc/pacman.conf", str(ctx.target / "etc" / "pacman.conf"))

    # 2: bind mounts. Tracked so the finish phase can tear them down cleanly.
    bind_mounts = [
        ("/var/cache/omarchy/mirror/offline", "/var/cache/omarchy/mirror/offline"),
        ("/opt/packages", "/opt/packages"),
    ]
    ctx.state.setdefault("bind_mounts", [])
    for src, dst in bind_mounts:
        target_dst = ctx.target / dst.lstrip("/")
        target_dst.mkdir(parents=True, exist_ok=True)
        subprocess.run(["mount", "--bind", src, str(target_dst)], check=True)
        ctx.state["bind_mounts"].append(str(target_dst))

    # 3: sudoers shim. Cleaned up by omarchy's first-run flow.
    sudoers = ctx.target / "etc" / "sudoers.d" / "99-omarchy-installer"
    sudoers.parent.mkdir(parents=True, exist_ok=True)
    sudoers.write_text(
        "root ALL=(ALL:ALL) NOPASSWD: ALL\n"
        "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n"
        f"{ctx.username} ALL=(ALL:ALL) NOPASSWD: ALL\n"
    )
    sudoers.chmod(0o440)

    # 4: copy install tooling to /mnt/tmp (ephemeral on first reboot, leaves
    # zero install detritus on the target).
    target_tooling = ctx.target / "tmp" / "omarchy-install"
    target_tooling.parent.mkdir(exist_ok=True)
    if target_tooling.exists():
        shutil.rmtree(target_tooling)
    subprocess.run(
        ["cp", "-a", f"{ctx.omarchy_path}/.", str(target_tooling)],
        check=True,
    )
    subprocess.run(
        ["chown", "-R", f"{ctx.username}:{ctx.username}", str(target_tooling)],
        check=False,
    )

    # 5: arch-chroot -u $user → finalize.sh
    mirror_channel = _read_omarchy_mirror()
    env_extras = [
        "OMARCHY_INSTALL_MODE=offline",
        "OMARCHY_PATH=/tmp/omarchy-install",
        f"OMARCHY_USER_NAME={ctx.full_name}",
        f"OMARCHY_USER_EMAIL={ctx.email}",
        f"OMARCHY_MIRROR={mirror_channel}",
        f"USER={ctx.username}",
        f"HOME=/home/{ctx.username}",
    ]
    cmd = [
        "arch-chroot",
        "-u", ctx.username,
        str(ctx.target),
        "env", "--unset=XDG_RUNTIME_DIR",
        *env_extras,
        "/bin/bash", "-lc",
        "bash /tmp/omarchy-install/finalize.sh",
    ]
    subprocess.run(cmd, check=True)


def _read_omarchy_mirror() -> str:
    p = Path("/root/omarchy_mirror")
    return p.read_text().strip() if p.exists() else "stable"


# ─────────────────────────────────────────────────────────────────────────────
# configure_login: sddm autologin for unencrypted installs only (encrypted
# installs already get a LUKS unlock prompt, no need for sddm autologin).
# ─────────────────────────────────────────────────────────────────────────────

def configure_login(ctx: InstallContext) -> None:
    if ctx.encrypt:
        return

    sddm_dir = ctx.target / "etc" / "sddm.conf.d"
    sddm_dir.mkdir(parents=True, exist_ok=True)
    (sddm_dir / "autologin.conf").unlink(missing_ok=True)
    (sddm_dir / "99-omarchy-login.conf").write_text(
        "[Theme]\nCurrent=omarchy\n\n"
        "[Users]\nRememberLastUser=true\nRememberLastSession=true\n"
    )

    state_dir = ctx.target / "var" / "lib" / "sddm"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "state.conf").write_text(
        f"[Last]\nSession=omarchy.desktop\nUser={ctx.username}\n"
    )

    autologin = ctx.target / "etc" / "systemd" / "system" / "getty@tty1.service.d" / "autologin.conf"
    autologin.unlink(missing_ok=True)

    subprocess.run(
        ["arch-chroot", str(ctx.target), "chown", "sddm:sddm",
         "/var/lib/sddm", "/var/lib/sddm/state.conf"],
        check=False, capture_output=True,
    )
    subprocess.run(
        ["arch-chroot", str(ctx.target), "systemctl", "enable", "sddm.service"],
        check=False, capture_output=True,
    )


# ─────────────────────────────────────────────────────────────────────────────
# validate_boot_full: hard checks before reboot. If the install ran but
# produced a UKI that can't actually boot, halt here rather than surprise
# the user.
# ─────────────────────────────────────────────────────────────────────────────

def validate_boot_full(ctx: InstallContext) -> None:
    limine_conf = ctx.target / "boot" / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")

    content = limine_conf.read_text()
    if "Omarchy" not in content:
        raise RuntimeError("/boot/limine.conf has no Omarchy entry")

    if ctx.encrypt and "cryptdevice=" not in content:
        raise RuntimeError("Encrypted install but /boot/limine.conf has no cryptdevice=")

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    if not kernel_cmdline.exists():
        raise RuntimeError(f"{kernel_cmdline} missing — UKI would have no cmdline")

    uki_dir = ctx.target / "boot" / "EFI" / "Linux"
    if uki_dir.exists():
        ukis = list(uki_dir.glob("*_linux*.efi"))
        if not ukis:
            raise RuntimeError(f"No UKI found in {uki_dir}")


# ─────────────────────────────────────────────────────────────────────────────
# validate_boot_protected: hard checks for the dualboot/protected path.
# Mirrors validate_boot_full but checks the Omarchy ESP subdir, fstab/crypttab,
# kernel/initramfs presence, and efibootmgr entry registration.
# ─────────────────────────────────────────────────────────────────────────────

def validate_boot_protected(ctx: InstallContext) -> None:
    protected = ctx.state["protected"]
    kernel = protected["kernel"]

    omarchy_esp = _omarchy_esp_path(ctx, protected)

    bootx64 = omarchy_esp / "BOOTX64.EFI"
    if not bootx64.exists() or bootx64.stat().st_size == 0:
        raise RuntimeError(f"{bootx64} missing or empty")

    limine_conf = omarchy_esp / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")
    if "/Omarchy Linux" not in limine_conf.read_text():
        raise RuntimeError(f"{limine_conf} has no /Omarchy Linux entry")

    fstab = ctx.target / "etc" / "fstab"
    if not fstab.exists():
        raise RuntimeError(f"{fstab} missing")
    fstab_text = fstab.read_text()
    btrfs_uuid = _blkid_uuid(_btrfs_root_device(protected))
    esp_uuid = _blkid_uuid(_esp_device(ctx, protected))
    if btrfs_uuid not in fstab_text:
        raise RuntimeError(f"{fstab} missing btrfs UUID {btrfs_uuid}")
    if esp_uuid not in fstab_text:
        raise RuntimeError(f"{fstab} missing ESP UUID {esp_uuid}")

    if protected.get("luks_uuid"):
        crypttab = ctx.target / "etc" / "crypttab.initramfs"
        if not crypttab.exists():
            raise RuntimeError(f"{crypttab} missing")
        if protected["luks_uuid"] not in crypttab.read_text():
            raise RuntimeError(f"{crypttab} missing LUKS UUID {protected['luks_uuid']}")

    vmlinuz = ctx.target / "boot" / f"vmlinuz-{kernel}"
    if not vmlinuz.exists():
        raise RuntimeError(f"{vmlinuz} missing")

    initramfs = ctx.target / "boot" / f"initramfs-{kernel}.img"
    if not initramfs.exists():
        raise RuntimeError(f"{initramfs} missing")

    post = _read_efibootmgr()
    if not _find_label_entries(post["entries"], "Omarchy Linux"):
        raise RuntimeError("no 'Omarchy Linux' entry registered in efibootmgr")


# ─────────────────────────────────────────────────────────────────────────────
# cleanup_bind_mounts: invoked from main()'s finally so bind mounts get
# unwound on success, failure, or interrupt. Idempotent.
# ─────────────────────────────────────────────────────────────────────────────

def cleanup_bind_mounts(ctx: InstallContext) -> None:
    for mount_point in ctx.state.get("bind_mounts", []):
        subprocess.run(["umount", mount_point], check=False, capture_output=True)
    ctx.state["bind_mounts"] = []


def cleanup_protected_state(ctx: InstallContext) -> None:
    """Tear down protected-mode mounts and LUKS mapper after a failed install.

    Idempotent and safe to call multiple times. Successful protected installs
    intentionally keep the target mounted until reboot.
    """
    if not ctx.is_protected:
        return

    subprocess.run(["umount", "-R", str(ctx.target)], check=False, capture_output=True)
    if Path("/dev/mapper/omarchy_root").exists():
        subprocess.run(
            ["cryptsetup", "close", "omarchy_root"],
            check=False,
            capture_output=True,
        )


# ─────────────────────────────────────────────────────────────────────────────
# finish: prompt for reboot. Bind mounts are unwound in main()'s finally.
# ─────────────────────────────────────────────────────────────────────────────

def finish(ctx: InstallContext) -> None:
    info("Installation finished. Reboot when ready.")
    if confirm("Reboot now?", default=True):
        os.system("reboot")
