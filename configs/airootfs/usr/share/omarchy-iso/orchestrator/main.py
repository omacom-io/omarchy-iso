"""Omarchy install orchestrator.

Single tool that owns the full install phase ordering, with archinstall used as
a library subsystem (not as the top-level installer).

The live-ISO wrapper consumes CLI args and passes configuration paths via
OMARCHY_INSTALL_* environment variables before Python starts. This keeps
archinstall's import-time CLI parsing from seeing Omarchy-specific flags.
"""

from __future__ import annotations

import sys
from .context import InstallContext
from .phases import PhaseError, run
from .ui import error, info


def build_phases(ctx: InstallContext):
    """Phase order. Each entry is (display name, callable taking InstallContext).

    The ordering is the whole point of this orchestrator: package-install
    hooks (limine-mkinitcpio-hook, in particular) and useradd happen at
    points where their prerequisites are guaranteed to be in place.

    Two modes:
      - full_disk: archinstall owns disk layout + bootloader.
      - protected: Omarchy owns disk layout + bootloader; archinstall is
        used for pacstrap + users + packages only.
    """
    from .phases_impl import (
        prepare_live,
        arch_install_full,
        arch_install_base,
        verify_protected_mounts,
        configure_protected_boot,
        configure_hibernation,
        run_chroot_finalizer,
        configure_login,
        validate_boot_full,
        validate_boot_protected,
    )

    if ctx.is_protected:
        return [
            ("Preparing live environment",      prepare_live),
            ("Verifying protected mounts",      verify_protected_mounts),
            ("Installing base system",          arch_install_base),
            ("Configuring protected boot",      configure_protected_boot),
            ("Configuring hibernation",         configure_hibernation),
            ("Finalizing in chroot",            run_chroot_finalizer),
            ("Configuring login",               configure_login),
            ("Validating protected boot setup", validate_boot_protected),
        ]

    return [
        ("Preparing live environment", prepare_live),
        ("Installing Arch + Omarchy",  arch_install_full),
        ("Configuring hibernation",    configure_hibernation),
        ("Finalizing in chroot",       run_chroot_finalizer),
        ("Configuring login",          configure_login),
        ("Validating boot setup",      validate_boot_full),
    ]


def main() -> int:
    try:
        ctx = InstallContext.from_env()
    except RuntimeError as e:
        error(f"Configuration error: {e}")
        return 2

    info(f"Installing Omarchy for {ctx.username} → {ctx.target}")

    from .phases_impl import cleanup_bind_mounts, cleanup_protected_state

    success = False
    try:
        try:
            run(ctx, build_phases(ctx))
            success = True
        except PhaseError:
            error("Installation halted.")
            return 1
        except KeyboardInterrupt:
            error("Installation interrupted.")
            return 130

        info("Installation complete.")
        return 0
    finally:
        cleanup_bind_mounts(ctx)
        if not success:
            cleanup_protected_state(ctx)


if __name__ == "__main__":
    sys.exit(main())
