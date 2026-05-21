"""Omarchy install orchestrator.

Single tool that owns the full install phase ordering, with archinstall used as
a library subsystem (not as the top-level installer).

Usage (typically invoked by bin/omarchy-install on the live ISO):

    omarchy-install \\
        --config user_configuration.json \\
        --creds user_credentials.json \\
        --full-name-file user_full_name.txt \\
        --email-file user_email_address.txt \\
        --encrypt-file user_encrypt_installation.txt
"""

from __future__ import annotations

import argparse
import sys

from . import archinstall_adapter as arch
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
        run_chroot_finalizer,
        configure_login,
        validate_boot_full,
        validate_boot_protected,
        finish,
    )

    if ctx.is_protected:
        return [
            ("Preparing live environment",      prepare_live),
            ("Verifying protected mounts",      verify_protected_mounts),
            ("Installing base system",          arch_install_base),
            ("Configuring protected boot",      configure_protected_boot),
            ("Finalizing in chroot",            run_chroot_finalizer),
            ("Configuring login",               configure_login),
            ("Validating protected boot setup", validate_boot_protected),
            ("Finishing",                       finish),
        ]

    return [
        ("Preparing live environment", prepare_live),
        ("Installing Arch + Omarchy",  arch_install_full),
        ("Finalizing in chroot",       run_chroot_finalizer),
        ("Configuring login",          configure_login),
        ("Validating boot setup",      validate_boot_full),
        ("Finishing",                  finish),
    ]


def parse_args(argv):
    p = argparse.ArgumentParser(prog="omarchy-install")
    p.add_argument("--config", required=True, help="archinstall user_configuration.json")
    p.add_argument("--creds", required=True, help="archinstall user_credentials.json")
    p.add_argument("--full-name-file", help="text file with the user's full name")
    p.add_argument("--email-file", help="text file with the user's email address")
    p.add_argument("--encrypt-file", help="text file holding 'true' if root encryption enabled")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv or sys.argv[1:])
    ctx = InstallContext.from_args(args)

    info(f"Installing Omarchy for {ctx.username} → {ctx.target}")

    from .phases_impl import cleanup_bind_mounts

    try:
        try:
            run(ctx, build_phases(ctx))
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


if __name__ == "__main__":
    sys.exit(main())
