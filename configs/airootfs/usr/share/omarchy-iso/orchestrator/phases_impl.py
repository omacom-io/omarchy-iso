"""Concrete phase implementations.

Phase ordering (full-disk):

    prepare_live           → pacman-key init, disk cleanup, load configurator
                             handlers (archinstall patch happens in the
                             wrapper before Python imports archinstall)
    arch_install_full      → archinstall-driven install (partition, base,
                             early omarchy pkgs, Omarchy Limine setup,
                             useradd, runtime omarchy pkgs)
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
    configure_protected_boot  → protected fstab/crypttab + Limine EFI handoff;
                                final UKI build still happens in finalizer
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
import textwrap
import time
from pathlib import Path

from . import archinstall_adapter as arch
from .context import InstallContext
from .ui import confirm, info


# Packages installed BEFORE useradd. omarchy-settings and omarchy-nvim
# populate /etc/skel so the user's home gets seeded correctly. omarchy-installer
# is INTENTIONALLY absent — it's live-ISO-only install tooling, never installed
# on the target. finalize.sh + install/ scripts get copied to /opt in
# run_chroot_finalizer.
EARLY_PACKAGES = [
    "base-devel",
    "git",
    "limine",
    "efibootmgr",
    "omarchy-keyring",
    "omarchy-settings",
    "omarchy-nvim",
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
# Reorders guided.py's perform_installation() so early Omarchy packages install
# before user creation and before our Omarchy-owned Limine setup copies files
# from the target's limine package.
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

        info("› installing base system (mkinitcpio deferred to final Limine UKI build)")
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

        if arch.bootloader_enabled(config):
            if not arch.is_limine(config):
                raise RuntimeError(
                    "Omarchy full-disk installs only support Limine bootloader setup"
                )
            info("› installing bootloader (Limine)")
            _install_limine_omarchy(ctx, installer, config)

            info("› writing Limine config (so limine-mkinitcpio-hook fires correctly)")
            _write_limine_defaults_from_config(ctx, installer, config)

        info("› creating user (with /etc/skel populated)")
        if config.auth_config and config.auth_config.users:
            installer.create_users(config.auth_config.users)

        info("› installing Omarchy runtime + omarchy-base.packages")
        installer.add_additional_packages(_runtime_package_list(ctx))

        info("› configuring root Snapper snapshots")
        _configure_snapper_root(ctx)

        # Standard arch finishers.
        if config.timezone:
            installer.set_timezone(config.timezone)
        if config.ntp:
            installer.activate_time_synchronization()
        if root := arch.root_user(config):
            installer.set_user_password(root)

        installer.genfstab()


def _install_limine_omarchy(ctx: InstallContext, installer, config) -> None:
    boot_partition = installer._get_boot_partition()
    efi_partition = installer._get_efi_partition()
    root = installer._get_root()

    if boot_partition is None:
        raise RuntimeError(f"Could not detect boot at mountpoint {ctx.target}")
    if root is None:
        raise RuntimeError(f"Could not detect root at mountpoint {ctx.target}")

    bootloader_config = config.bootloader_config
    bootloader_removable = bool(
        getattr(bootloader_config, "removable", False) if bootloader_config else False
    )
    limine_path = ctx.target / "usr" / "share" / "limine"

    if arch.has_uefi():
        if efi_partition is None:
            raise RuntimeError("Could not detect EFI partition")
        if not efi_partition.mountpoint:
            raise RuntimeError("EFI partition is not mounted")

        parent_dev_path = arch.parent_device_path(efi_partition.safe_dev_path)
        efi_dir_path = ctx.target / efi_partition.mountpoint.relative_to("/") / "EFI"
        efi_dir_path_target = efi_partition.mountpoint / "EFI"
        if bootloader_removable:
            efi_dir_path = efi_dir_path / "BOOT"
            efi_dir_path_target = efi_dir_path_target / "BOOT"
        else:
            # Non-removable UEFI installs place the x64 binary at EFI/limine/BOOTX64.EFI.
            efi_dir_path = efi_dir_path / "limine"
            efi_dir_path_target = efi_dir_path_target / "limine"

        efi_dir_path.mkdir(parents=True, exist_ok=True)
        for filename in ("BOOTIA32.EFI", "BOOTX64.EFI"):
            _copy_required(limine_path / filename, efi_dir_path / filename)

        hook_command = (
            f"/usr/bin/cp /usr/share/limine/BOOTIA32.EFI {efi_dir_path_target}/ && "
            f"/usr/bin/cp /usr/share/limine/BOOTX64.EFI {efi_dir_path_target}/"
        )

        loader_path = _limine_efi_loader_path(bootloader_removable)
        subprocess.run(
            [
                "efibootmgr",
                "--create",
                "--disk", str(parent_dev_path),
                "--part", str(efi_partition.partn),
                "--label", "Limine",
                "--loader", loader_path,
                "--unicode",
                "--verbose",
            ],
            check=True,
        )
    else:
        boot_limine_path = ctx.target / "boot" / "limine"
        boot_limine_path.mkdir(parents=True, exist_ok=True)

        parent_dev_path = arch.parent_device_path(boot_partition.safe_dev_path)
        if unique_path := arch.unique_device_path(parent_dev_path):
            parent_dev_path = unique_path

        _copy_required(limine_path / "limine-bios.sys", boot_limine_path / "limine-bios.sys")
        subprocess.run(
            ["arch-chroot", str(ctx.target), "limine", "bios-install", str(parent_dev_path)],
            check=True,
        )
        hook_command = (
            f"/usr/bin/limine bios-install {parent_dev_path} && "
            "/usr/bin/cp /usr/share/limine/limine-bios.sys /boot/limine/"
        )

    _write_limine_pacman_hook(ctx.target, hook_command)
    installer._helper_flags["bootloader"] = "limine"


def _copy_required(src: Path, dst: Path) -> None:
    if not src.exists():
        raise RuntimeError(f"Required Limine file missing: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def _limine_efi_loader_path(bootloader_removable: bool) -> str:
    try:
        efi_bitness = Path("/sys/firmware/efi/fw_platform_size").read_text().strip()
    except Exception as err:
        raise RuntimeError(
            "Could not read /sys/firmware/efi/fw_platform_size to determine EFI bitness"
        ) from err

    if efi_bitness == "64":
        return "\\EFI\\BOOT\\BOOTX64.EFI" if bootloader_removable else "\\EFI\\limine\\BOOTX64.EFI"
    if efi_bitness == "32":
        return "\\EFI\\BOOT\\BOOTIA32.EFI" if bootloader_removable else "\\EFI\\limine\\BOOTIA32.EFI"
    raise RuntimeError(f'EFI bitness is neither 32 nor 64 bits. Found "{efi_bitness}".')


def _write_limine_pacman_hook(target: Path, hook_command: str) -> None:
    hook_contents = textwrap.dedent(
        f"""\
        [Trigger]
        Operation = Upgrade
        Type = Package
        Target = limine

        [Action]
        Description = Deploying Omarchy Limine after upgrade...
        When = PostTransaction
        Exec = /bin/sh -c "{hook_command}"
        """
    )
    hooks_dir = target / "etc" / "pacman.d" / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / "99-omarchy-limine.hook").write_text(hook_contents)


def _write_limine_defaults_from_config(ctx: InstallContext, installer, config) -> None:
    if not arch.is_limine(config):
        return

    root = installer._get_root()
    if root is None:
        raise RuntimeError(f"Could not detect root at mountpoint {ctx.target}")

    cmdline = " ".join(installer._get_kernel_params(root))
    if not cmdline.strip():
        raise RuntimeError("Could not compute kernel cmdline from install config")
    if "root=" not in cmdline:
        raise RuntimeError(f"Computed cmdline has no root=: {cmdline!r}")

    default_template = _limine_template(ctx, "default.conf")
    default_limine = ctx.target / "etc" / "default" / "limine"
    default_limine.parent.mkdir(parents=True, exist_ok=True)
    default_limine.write_text(default_template.read_text().replace("@@CMDLINE@@", cmdline))

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    kernel_cmdline.parent.mkdir(parents=True, exist_ok=True)
    kernel_cmdline.write_text(cmdline + "\n")

    limine_conf = ctx.target / "boot" / "limine.conf"
    limine_conf.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(_limine_template(ctx, "limine.conf"), limine_conf)


def _configure_snapper_root(ctx: InstallContext) -> None:
    """Configure Omarchy's root-only Snapper setup during the archinstall
    phase, not inside the finalizer chroot.

    archinstall's own setup_btrfs_snapshot() uses `snapper --no-dbus` because
    snapperd/DBus are not available in arch-chroot. We mirror that proven
    chroot-safe call, but only create the root config: Omarchy intentionally
    does not snapshot /home user data.
    """
    config_path = ctx.target / "etc" / "snapper" / "configs" / "root"
    if not config_path.exists():
        subprocess.run(
            [
                "arch-chroot",
                "-S",
                str(ctx.target),
                "snapper",
                "--no-dbus",
                "-c",
                "root",
                "create-config",
                "/",
            ],
            check=True,
        )

    template_candidates = [
        ctx.target / "etc" / "snapper" / "config-templates" / "omarchy",
        ctx.target / "usr" / "share" / "omarchy" / "default" / "snapper" / "root",
    ]
    template = next((path for path in template_candidates if path.exists()), None)
    if template is None:
        searched = "\n  ".join(str(path) for path in template_candidates)
        raise RuntimeError(f"Snapper root template not found. Searched:\n  {searched}")

    config_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(template, config_path)

    conf_path = ctx.target / "etc" / "conf.d" / "snapper"
    conf_path.parent.mkdir(parents=True, exist_ok=True)
    if conf_path.exists():
        text = conf_path.read_text()
        if re.search(r"^SNAPPER_CONFIGS=", text, flags=re.MULTILINE):
            text = re.sub(r'^SNAPPER_CONFIGS=.*$', 'SNAPPER_CONFIGS="root"', text, flags=re.MULTILINE)
        else:
            text = text.rstrip() + '\nSNAPPER_CONFIGS="root"\n'
        conf_path.write_text(text)
    else:
        conf_path.write_text('SNAPPER_CONFIGS="root"\n')



def _limine_template(ctx: InstallContext, filename: str) -> Path:
    candidates = [
        ctx.omarchy_path / "install" / "assets" / "limine" / filename,
        ctx.omarchy_path / "default" / "limine" / filename,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    searched = "\n  ".join(str(p) for p in candidates)
    raise RuntimeError(f"Limine template {filename} not found. Searched:\n  {searched}")


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

    if not PROTECTED_INTENT_PATH.exists():
        raise RuntimeError(
            f"protected mode: expected partition intent at {PROTECTED_INTENT_PATH} "
            "(configurator should have written it)"
        )

    intent = json.loads(PROTECTED_INTENT_PATH.read_text())
    for key in ("esp_device", "esp_mount", "esp_path", "luks_uuid", "root_device", "kernel"):
        if key not in intent:
            raise RuntimeError(
                f"protected mode: {PROTECTED_INTENT_PATH} missing key '{key}'"
            )

    esp_mp = target / intent["esp_mount"].lstrip("/")
    if not _is_mountpoint(esp_mp):
        esp_dev = intent["esp_device"]
        if not Path(esp_dev).exists():
            raise RuntimeError(
                f"protected mode: ESP device {esp_dev} from {PROTECTED_INTENT_PATH} does not exist"
            )
        info(f"› remounting protected ESP {esp_dev} at {esp_mp}")
        esp_mp.mkdir(parents=True, exist_ok=True)
        subprocess.run(["mount", esp_dev, str(esp_mp)], check=True)

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

        info("› configuring root Snapper snapshots")
        _configure_snapper_root(ctx)

        # Protected mode owns boot setup separately, so pacstrap limine +
        # efibootmgr here while the live ISO's offline mirror is still the
        # active pacman source. Doing it later via arch-chroot would hit
        # the target's network-mirror pacman.conf and fail offline.
        info("› installing limine + efibootmgr (protected boot)")
        installer.add_additional_packages(["limine", "efibootmgr"])

        if config.timezone:
            installer.set_timezone(config.timezone)
        if config.ntp:
            installer.activate_time_synchronization()
        if root := arch.root_user(config):
            installer.set_user_password(root)


# ─────────────────────────────────────────────────────────────────────────────
# configure_protected_boot: protected-mode fstab + Limine handoff.
#
# Free-space installs should converge with full-disk installs as soon as the
# target is mounted. This phase only writes the mount/boot intent that the
# common finalizer needs, and registers a Limine EFI entry on the chosen ESP.
# The final UKI/initramfs build is deliberately left to login/limine-snapper.sh
# (`limine-update`), same as full-disk installs.
# ─────────────────────────────────────────────────────────────────────────────

def configure_protected_boot(ctx: InstallContext) -> None:
    protected = ctx.state["protected"]

    info("› writing /etc/fstab")
    _write_fstab(ctx, protected)

    if protected.get("luks_uuid"):
        info("› writing /etc/crypttab.initramfs")
        _write_crypttab(ctx, protected)

    info("› writing Limine defaults")
    _write_protected_limine_defaults(ctx, protected)

    info("› capturing efibootmgr state pre-install")
    pre_state = _read_efibootmgr()
    windows_before = _find_label_entries(pre_state["entries"], "Windows")

    info("› installing Limine into protected ESP")
    _install_protected_limine_efi(ctx, protected)

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


# ── Limine ───────────────────────────────────────────────────────────────────

def _protected_esp_mount(ctx: InstallContext, protected: dict) -> Path:
    return ctx.target / protected["esp_mount"].lstrip("/")


def _omarchy_esp_path(ctx: InstallContext, protected: dict) -> Path:
    return _protected_esp_mount(ctx, protected) / protected["esp_path"].lstrip("/")


def _build_cmdline(protected: dict, btrfs_uuid: str) -> str:
    if protected.get("luks_uuid"):
        return (
            f"cryptdevice=UUID={protected['luks_uuid']}:omarchy_root "
            "root=/dev/mapper/omarchy_root zswap.enabled=0 "
            "rootflags=subvol=@ rw rootfstype=btrfs"
        )
    return (
        f"root=UUID={btrfs_uuid} zswap.enabled=0 "
        "rootflags=subvol=@ rw rootfstype=btrfs"
    )


def _write_protected_limine_defaults(ctx: InstallContext, protected: dict) -> None:
    btrfs_uuid = _blkid_uuid(_btrfs_root_device(protected))
    cmdline = _build_cmdline(protected, btrfs_uuid)

    default_text = _limine_template(ctx, "default.conf").read_text()
    default_text = default_text.replace("@@CMDLINE@@", cmdline)
    default_text = re.sub(r'^ESP_PATH=.*$', f'ESP_PATH="{protected["esp_mount"]}"', default_text, flags=re.MULTILINE)
    # Free-space installs may share a Windows ESP. Never claim EFI/BOOT as a
    # fallback loader in that mode; use the explicit NVRAM entry instead.
    default_text = re.sub(r'^ENABLE_LIMINE_FALLBACK=.*$', 'ENABLE_LIMINE_FALLBACK=no', default_text, flags=re.MULTILINE)

    default_limine = ctx.target / "etc" / "default" / "limine"
    default_limine.parent.mkdir(parents=True, exist_ok=True)
    default_limine.write_text(default_text)

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    kernel_cmdline.parent.mkdir(parents=True, exist_ok=True)
    kernel_cmdline.write_text(cmdline + "\n")


def _install_protected_limine_efi(ctx: InstallContext, protected: dict) -> None:
    src = ctx.target / "usr" / "share" / "limine" / "BOOTX64.EFI"
    if not src.exists():
        raise RuntimeError(
            f"Limine EFI binary not found at {src} — limine package missing in target"
        )

    limine_dir = _omarchy_esp_path(ctx, protected)
    limine_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, limine_dir / "limine_x64.efi")

    esp_mount_target = Path(protected["esp_mount"])
    hook_command = (
        f"/usr/bin/cp /usr/share/limine/BOOTX64.EFI "
        f"{esp_mount_target / protected['esp_path'].lstrip('/')}/limine_x64.efi"
    )
    _write_limine_pacman_hook(ctx.target, hook_command)


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

    # Clean up any stale Limine entries pointing at our protected install path
    # so we don't accumulate dupes across re-installs.
    for num in _find_label_entries(pre_state["entries"], "Limine"):
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
            "--label", "Limine",
            "--loader", "\\EFI\\limine\\limine_x64.efi",
            "--unicode",
        ],
        check=True, capture_output=True, text=True,
    )

    post = _read_efibootmgr()
    new_omarchy = _find_label_entries(post["entries"], "Limine")
    if not new_omarchy:
        raise RuntimeError(
            "efibootmgr --create reported success but no Limine entry found"
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
#  4. copy the omarchy install tooling into /mnt/opt/omarchy-install (the
#     target never gets the omarchy-installer package installed). Do NOT use
#     /tmp: arch-chroot mounts a fresh tmpfs over the target's /tmp.
#  5. arch-chroot -u $user → /opt/omarchy-install/finalize.sh
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

    # 3: sudoers shim. Removed after finalize.sh returns.
    sudoers = ctx.target / "etc" / "sudoers.d" / "99-omarchy-installer"
    sudoers.parent.mkdir(parents=True, exist_ok=True)
    sudoers.write_text(
        "root ALL=(ALL:ALL) NOPASSWD: ALL\n"
        "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n"
        f"{ctx.username} ALL=(ALL:ALL) NOPASSWD: ALL\n"
    )
    sudoers.chmod(0o440)

    # run_logged appends as the install user. Create the target log before
    # arch-chroot so the first redirection cannot fail on /var/log perms.
    target_log = ctx.target / "var" / "log" / "omarchy-install.log"
    omarchy_start_epoch = int(time.time())
    omarchy_start_time = time.strftime("%Y-%m-%d %H:%M:%S")
    target_log.parent.mkdir(parents=True, exist_ok=True)
    target_log.write_text(f"=== Omarchy Installation Started: {omarchy_start_time} ===\n")
    target_log.chmod(0o666)

    # 4: copy install tooling somewhere arch-chroot will not mask. /tmp is not
    # safe here: arch-chroot mounts a fresh tmpfs over the target's /tmp before
    # running commands, so files copied to /mnt/tmp are invisible in the chroot.
    tooling_path = Path("/opt/omarchy-install")
    target_tooling = ctx.target / tooling_path.relative_to("/")
    target_tooling.parent.mkdir(parents=True, exist_ok=True)
    if target_tooling.exists():
        shutil.rmtree(target_tooling)
    subprocess.run(
        ["cp", "-a", f"{ctx.omarchy_path}/.", str(target_tooling)],
        check=True,
    )
    if not (target_tooling / "finalize.sh").exists():
        raise RuntimeError(
            f"Copied installer tooling but {target_tooling / 'finalize.sh'} is missing"
        )

    # Keep the payload root-owned. It only needs to be traversable/readable by
    # the install user; sudoers below handles privileged work inside scripts.
    subprocess.run(["chmod", "-R", "a+rX", str(target_tooling)], check=True)
    subprocess.run(
        [
            "arch-chroot", "-u", ctx.username, str(ctx.target),
            "test", "-r", str(tooling_path / "finalize.sh"),
        ],
        check=True,
    )

    # 5: arch-chroot -u $user → finalize.sh
    mirror_channel = _read_omarchy_mirror()
    env_extras = [
        "OMARCHY_INSTALL_MODE=offline",
        "OMARCHY_CHROOT_FINALIZER=1",
        "OMARCHY_PATH=/usr/share/omarchy",
        f"OMARCHY_INSTALL={tooling_path / 'install'}",
        f"OMARCHY_START_TIME={omarchy_start_time}",
        f"OMARCHY_START_EPOCH={omarchy_start_epoch}",
        f"OMARCHY_USER_NAME={ctx.full_name}",
        f"OMARCHY_USER_EMAIL={ctx.email}",
        f"OMARCHY_MIRROR={mirror_channel}",
        "OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log",
        f"USER={ctx.username}",
        f"HOME=/home/{ctx.username}",
    ]
    cmd = [
        "arch-chroot",
        "-u", ctx.username,
        str(ctx.target),
        "env", "--unset=XDG_RUNTIME_DIR",
        *env_extras,
        "/bin/bash", str(tooling_path / "finalize.sh"),
    ]
    try:
        subprocess.run(cmd, check=True)
    finally:
        sudoers.unlink(missing_ok=True)


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
# Mirrors validate_boot_full but checks the protected ESP, fstab/crypttab,
# final Limine UKI, and efibootmgr entry registration.
# ─────────────────────────────────────────────────────────────────────────────

def validate_boot_protected(ctx: InstallContext) -> None:
    protected = ctx.state["protected"]
    kernel = protected["kernel"]

    limine_dir = _omarchy_esp_path(ctx, protected)
    esp_mount = _protected_esp_mount(ctx, protected)

    bootx64 = limine_dir / "limine_x64.efi"
    if not bootx64.exists() or bootx64.stat().st_size == 0:
        raise RuntimeError(f"{bootx64} missing or empty")

    limine_conf = esp_mount / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")
    if "Omarchy" not in limine_conf.read_text():
        raise RuntimeError(f"{limine_conf} has no Omarchy entry")

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

    uki = esp_mount / "EFI" / "Linux" / f"omarchy_{kernel}.efi"
    if not uki.exists() or uki.stat().st_size == 0:
        raise RuntimeError(f"{uki} missing or empty")

    post = _read_efibootmgr()
    if not _find_label_entries(post["entries"], "Limine"):
        raise RuntimeError("no 'Limine' entry registered in efibootmgr")


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

def _dashboard_stopped(pid: int) -> bool:
    stat = Path(f"/proc/{pid}/stat")
    if not stat.exists():
        return True
    try:
        # /proc/<pid>/stat field 3 is process state. A zombie cannot write to
        # the tty anymore; the shell parent will reap it when control returns.
        return stat.read_text().split()[2] == "Z"
    except OSError:
        return True


def _pid_is_dashboard(pid: int) -> bool:
    try:
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ")
    except OSError:
        return False
    return b"omarchy-install-dashboard" in cmdline


def _dashboard_pids() -> list[int]:
    pids: list[int] = []
    pid_text = os.environ.get("OMARCHY_INSTALL_DASHBOARD_PID")
    if pid_text:
        try:
            pid = int(pid_text)
            if _pid_is_dashboard(pid):
                pids.append(pid)
        except ValueError:
            pass

    # Belt-and-suspenders fallback in case the env var was lost before finish.
    try:
        proc = subprocess.run(
            ["pgrep", "-f", "omarchy-install-dashboard"],
            capture_output=True,
            text=True,
            check=False,
        )
        for line in proc.stdout.splitlines():
            try:
                pid = int(line)
            except ValueError:
                continue
            if pid not in pids and _pid_is_dashboard(pid):
                pids.append(pid)
    except OSError:
        pass
    return pids


def _signal_dashboard(pid: int, signal_number: int) -> None:
    # Dashboard is launched with setsid, making its PID the process group ID.
    # Signal the group first so child sleep/tte processes cannot keep drawing.
    try:
        os.killpg(pid, signal_number)
    except OSError:
        pass
    try:
        os.kill(pid, signal_number)
    except OSError:
        pass


def _stop_install_dashboard() -> None:
    stop_file = Path("/run/omarchy-install/dashboard.stop")
    try:
        stop_file.parent.mkdir(parents=True, exist_ok=True)
        stop_file.touch()
    except OSError:
        pass

    pids = _dashboard_pids()
    for signal_number in (15, 9):
        for pid in pids:
            if _dashboard_stopped(pid):
                continue
            if not _pid_is_dashboard(pid):
                continue
            _signal_dashboard(pid, signal_number)
        deadline = time.time() + (1.0 if signal_number == 15 else 0.5)
        while time.time() < deadline:
            if all(_dashboard_stopped(pid) for pid in pids):
                break
            time.sleep(0.05)
        if all(_dashboard_stopped(pid) for pid in pids):
            break

    try:
        with open("/dev/tty", "w", encoding="utf-8") as tty:
            tty.write("\033[?25h\033[H\033[2J")
            tty.flush()
    except OSError:
        pass


def _tty_size() -> tuple[int, int]:
    try:
        with open("/dev/tty", "rb") as tty:
            res = subprocess.run(
                ["stty", "size"],
                stdin=tty,
                capture_output=True,
                text=True,
                check=True,
            )
        rows, cols = res.stdout.strip().split()
        return int(rows), int(cols)
    except Exception:  # noqa: BLE001
        return 24, 80


def _center_text(text: str, width: int) -> str:
    pad = max((width - len(text)) // 2, 0)
    return " " * pad + text


def _install_duration(ctx: InstallContext) -> str | None:
    candidates = [
        ctx.target / "var" / "log" / "omarchy-install.log",
        Path("/var/log/omarchy-install.log"),
    ]
    patterns = ("Total:", "Omarchy:")
    for path in candidates:
        if not path.exists():
            continue
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for prefix in patterns:
            for line in reversed(lines[-80:]):
                if line.startswith(prefix):
                    duration = line.split(":", 1)[1].strip()
                    if duration:
                        return duration
    return None


def _render_tte_logo(logo_path: Path) -> bool:
    if not logo_path.exists() or not shutil.which("tte"):
        return False
    try:
        with open("/dev/tty", "rb", buffering=0) as stdin, open("/dev/tty", "wb", buffering=0) as stdout:
            subprocess.run(
                [
                    "tte",
                    "-i", str(logo_path),
                    "--canvas-width", "0",
                    "--anchor-text", "c",
                    "--frame-rate", "920",
                    "laseretch",
                ],
                stdin=stdin,
                stdout=stdout,
                stderr=subprocess.DEVNULL,
                timeout=8,
                check=True,
            )
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def _render_static_finish_logo(tty, logo_path: Path, cols: int) -> None:
    green = "\033[32m"
    reset = "\033[0m"
    if logo_path.exists():
        logo_lines = logo_path.read_text(errors="ignore").splitlines()
        logo_width = max((len(line) for line in logo_lines), default=0)
        left = max((cols - logo_width) // 2, 0)
        for line in logo_lines:
            tty.write(" " * left + green + line + reset + "\n")
    else:
        tty.write(_center_text("Omarchy", cols) + "\n")


def _render_finish_screen(ctx: InstallContext) -> None:
    _, cols = _tty_size()
    logo_path = Path("/usr/share/omarchy/logo.txt")
    try:
        with open("/dev/tty", "w", encoding="utf-8") as tty:
            tty.write("\033[?25h\033[H\033[2J\n")
            tty.flush()

        if not _render_tte_logo(logo_path):
            with open("/dev/tty", "w", encoding="utf-8") as tty:
                tty.write("\033[?25h\033[H\033[2J\n")
                _render_static_finish_logo(tty, logo_path, cols)
                tty.flush()

        with open("/dev/tty", "w", encoding="utf-8") as tty:
            tty.write("\n")
            duration = _install_duration(ctx)
            message = f"Installed in {duration}" if duration else "Finished installing"
            tty.write(_center_text(message, cols) + "\n\n")
            tty.flush()
    except OSError:
        pass


def finish(ctx: InstallContext) -> None:
    _stop_install_dashboard()
    _render_finish_screen(ctx)
    if confirm("Reboot now?", default=True):
        os.system("reboot")
