"""Concrete phase implementations.

Phase ordering:

    prepare_live          → pacman-key init, disk cleanup, load configurator
                            handlers (archinstall patch happens in the
                            wrapper before Python imports archinstall)
    arch_install          → archinstall-driven install (partition, base,
                            bootloader, write limine config, early omarchy
                            pkgs, useradd, runtime omarchy pkgs)
    run_chroot_finalizer  → bind mounts + sudoers shim + arch-chroot finalize.sh
    configure_login       → sddm autologin for unencrypted installs
    validate_boot         → assert UKI / limine.conf / kernel cmdline are sane
    finish                → reboot prompt
"""

from __future__ import annotations

import os
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
# arch_install: everything inside a single Installer context manager. Reorders
# guided.py's perform_installation() so our limine config write lands between
# add_bootloader and the first add_additional_packages call, and user
# creation happens AFTER early omarchy packages populate /etc/skel.
# ─────────────────────────────────────────────────────────────────────────────

def arch_install(ctx: InstallContext) -> None:
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
    for src, dst in bind_mounts:
        target_dst = ctx.target / dst.lstrip("/")
        target_dst.mkdir(parents=True, exist_ok=True)
        subprocess.run(["mount", "--bind", src, str(target_dst)], check=True)
    ctx.state["bind_mounts"] = [str(ctx.target / d.lstrip("/")) for _, d in bind_mounts]

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
# validate_boot: hard checks before reboot. If the install ran but produced a
# UKI that can't actually boot, halt here rather than surprise the user.
# ─────────────────────────────────────────────────────────────────────────────

def validate_boot(ctx: InstallContext) -> None:
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
# finish: unwind bind mounts, prompt for reboot.
# ─────────────────────────────────────────────────────────────────────────────

def finish(ctx: InstallContext) -> None:
    for mount_point in ctx.state.get("bind_mounts", []):
        subprocess.run(["umount", mount_point], check=False, capture_output=True)

    info("Installation finished. Reboot when ready.")
    if confirm("Reboot now?", default=True):
        os.system("reboot")
