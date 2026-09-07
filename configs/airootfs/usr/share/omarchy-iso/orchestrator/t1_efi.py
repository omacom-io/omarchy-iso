"""Fail-closed Apple EFI protection for T1 Macs.

The configurator owns partitioning for preservation-aware installs. This
module is the unattended/orchestrator backstop: every attached disk is checked
read-only, and a destructive plan is accepted only when all readable Apple EFI
sources are on disks the plan will not modify.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .command import capture


SUPPORTED_T1_MODELS = frozenset({
    "MacBookPro13,2",
    "MacBookPro13,3",
    "MacBookPro14,2",
    "MacBookPro14,3",
})

_DMI_ROOT = Path("/sys/class/dmi/id")
_FAT_FILESYSTEMS = frozenset({"fat", "fat12", "fat16", "fat32", "msdos", "vfat"})
_ESP_PARTTYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"


@dataclass(frozen=True)
class _InstallPlan:
    target_disk: str
    omarchy_esp: str | None
    destructive: bool


def validate_t1_efi_preservation(ctx: Any) -> None:
    """Reject unsafe T1 plans before any installer-owned disk operation.

    No serial number, UUID, hash, or other unique machine value is read or
    logged.  The DMI model is used only to decide whether this guard applies.
    """
    if not _is_supported_t1_mac():
        return

    plan = _read_install_plan(ctx)
    sources = _discover_apple_efi_sources(ctx.state_dir, plan.target_disk)
    if not any(sources.values()):
        raise _missing_apple_data_error()

    canonical_target = os.path.realpath(plan.target_disk)
    if canonical_target not in sources:
        raise RuntimeError(
            "Apple T1 safety check stopped installation before disk changes: "
            "the install target is not one attached whole-disk device"
        )
    target_sources = sources[canonical_target]
    if target_sources and plan.destructive:
        raise RuntimeError(
            "Apple T1 safety check stopped installation before disk changes: "
            "the target disk contains Apple EFI data that this plan would not preserve"
        )

    if target_sources:
        if plan.omarchy_esp is None:
            raise RuntimeError(
                "Apple T1 safety check stopped installation before disk changes: "
                "Omarchy must use a separate EFI partition"
            )
        if os.path.realpath(plan.omarchy_esp) in target_sources:
            raise RuntimeError(
                "Apple T1 safety check stopped installation before disk changes: "
                "Omarchy must use a separate EFI partition"
            )


def _is_supported_t1_mac() -> bool:
    try:
        vendor = (_DMI_ROOT / "sys_vendor").read_text().strip()
        model = (_DMI_ROOT / "product_name").read_text().strip()
    except OSError:
        return False
    return vendor == "Apple Inc." and model in SUPPORTED_T1_MODELS


def _read_install_plan(ctx: Any) -> _InstallPlan:
    disk_config = ctx.user_configuration.get("disk_config") or {}
    modifications = disk_config.get("device_modifications") or []
    wipe_devices = [
        modification.get("device")
        for modification in modifications
        if isinstance(modification, dict) and bool(modification.get("wipe"))
    ]

    if ctx.mode == "full_disk" and disk_config.get("config_type") == "default_layout":
        if (
            len(modifications) == 1
            and len(wipe_devices) == 1
            and isinstance(wipe_devices[0], str)
            and wipe_devices[0]
        ):
            return _InstallPlan(
                target_disk=os.path.realpath(wipe_devices[0]),
                omarchy_esp=None,
                destructive=True,
            )

    if (
        ctx.mode == "protected"
        and disk_config.get("config_type") == "pre_mounted_config"
        and not wipe_devices
    ):
        storage = ctx.omarchy_install.get("storage") or {}
        omarchy_esp = storage.get("esp_device")
        if isinstance(omarchy_esp, str) and omarchy_esp:
            return _InstallPlan(
                target_disk=_parent_disk(omarchy_esp),
                omarchy_esp=omarchy_esp,
                destructive=False,
            )

    raise RuntimeError(
        "Apple T1 safety check stopped installation before disk changes: "
        "the install plan does not identify one safely handled target disk"
    )


def _discover_apple_efi_sources(
    state_dir: Path, target_disk: str,
) -> dict[str, set[str]]:
    sources: dict[str, set[str]] = {}
    canonical_target = os.path.realpath(target_disk)
    for disk in _whole_disks():
        canonical_disk = os.path.realpath(disk)
        sources[canonical_disk] = set()
        target = canonical_disk == canonical_target
        for partition in _fat_partitions(disk, strict=target):
            contents = _inspect_partition(partition, state_dir)
            if contents == "unreadable":
                if target:
                    raise _inspection_error()
                continue
            if contents == "apple":
                sources[canonical_disk].add(os.path.realpath(partition))
    return sources


def _whole_disks() -> list[str]:
    try:
        result = capture(["lsblk", "--json", "--paths", "--output", "PATH,TYPE"])
    except OSError:
        raise _inspection_error() from None
    if result.returncode != 0:
        raise _inspection_error()
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        raise _inspection_error() from None

    disks = []
    for node in _walk_blockdevices(payload.get("blockdevices")):
        path = node.get("path")
        if node.get("type") == "disk" and isinstance(path, str) and path.startswith("/dev/"):
            disks.append(path)
    if not disks:
        raise _inspection_error()
    return disks


def _parent_disk(partition: str) -> str:
    try:
        result = capture(["lsblk", "-npo", "PKNAME", "--", partition])
    except OSError:
        raise _inspection_error() from None
    parent = result.stdout.strip() if result.returncode == 0 else ""
    if not parent.startswith("/dev/") or "\n" in parent:
        raise _inspection_error()
    return parent


def _fat_partitions(parent: str, *, strict: bool = True) -> list[str]:
    try:
        result = capture([
            "lsblk", "--json", "--paths", "--output", "PATH,TYPE,FSTYPE,PARTTYPE", "--", parent,
        ])
    except OSError:
        raise _inspection_error() from None
    if result.returncode != 0:
        raise _inspection_error()
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        raise _inspection_error() from None

    partitions: list[str] = []
    for node in _walk_blockdevices(payload.get("blockdevices")):
        path = node.get("path")
        fs_type = node.get("fstype")
        part_type = node.get("parttype")
        if node.get("type") != "part":
            continue
        if not isinstance(part_type, str) or not part_type.strip():
            if strict:
                raise _inspection_error()
            continue
        if part_type.casefold() != _ESP_PARTTYPE:
            continue
        if (
            not isinstance(path, str)
            or not path.startswith("/dev/")
            or not isinstance(fs_type, str)
            or fs_type.casefold() not in _FAT_FILESYSTEMS
        ):
            if strict:
                raise _inspection_error()
            continue
        partitions.append(path)
    return partitions


def _walk_blockdevices(nodes: Any):
    if not isinstance(nodes, list):
        return
    for node in nodes:
        if not isinstance(node, dict):
            continue
        yield node
        yield from _walk_blockdevices(node.get("children"))


def _inspect_partition(device: str, state_dir: Path) -> str:
    """Return ``apple``, ``other``, or ``unreadable`` without logging device data."""
    mounted_contents = _inspect_existing_mount(device)
    if mounted_contents is not None:
        return mounted_contents

    state_dir.mkdir(parents=True, exist_ok=True)
    mountpoint = Path(tempfile.mkdtemp(prefix=".apple-efi-check-", dir=state_dir))
    mounted = False
    try:
        try:
            result = subprocess.run(
                ["mount", "-o", "ro,nodev,nosuid,noexec", "--", device, str(mountpoint)],
                check=False,
                capture_output=True,
            )
        except OSError:
            return "unreadable"
        if result.returncode != 0:
            return "unreadable"
        mounted = True
        try:
            return "apple" if _contains_apple_directory(mountpoint) else "other"
        except OSError:
            return "unreadable"
    finally:
        if mounted:
            result = subprocess.run(
                ["umount", "--", str(mountpoint)],
                check=False,
                capture_output=True,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    "Apple T1 safety check could not finish its read-only EFI check; "
                    "installation stopped before disk changes"
                )
        try:
            mountpoint.rmdir()
        except OSError:
            # Never recursively remove a probe directory: if unmount failed,
            # doing so could modify the filesystem mounted beneath it.
            pass


def _inspect_existing_mount(device: str) -> str | None:
    """Inspect one existing mount, avoiding a second mount of the same ESP."""
    try:
        result = capture(["findmnt", "--json", "--source", device, "--output", "TARGET"])
    except OSError:
        return "unreadable"
    if result.returncode == 1:
        return None
    if result.returncode != 0:
        return "unreadable"
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return "unreadable"
    filesystems = payload.get("filesystems")
    if not isinstance(filesystems, list) or len(filesystems) != 1:
        return "unreadable"
    target = filesystems[0].get("target")
    if not isinstance(target, str) or not target.startswith("/"):
        return "unreadable"
    try:
        return "apple" if _contains_apple_directory(Path(target)) else "other"
    except OSError:
        return "unreadable"


def _contains_apple_directory(root: Path) -> bool:
    efi = _casefolded_directory(root, "efi")
    return efi is not None and _casefolded_directory(efi, "apple") is not None


def _casefolded_directory(parent: Path, name: str) -> Path | None:
    for child in parent.iterdir():
        if child.name.casefold() == name and child.is_dir():
            return child
    return None


def _inspection_error() -> RuntimeError:
    return RuntimeError(
        "Apple T1 safety check could not safely inspect every EFI partition on "
        "the install target, so installation stopped before disk changes. Check "
        "the disk for filesystem errors and retry; do not erase an Apple EFI "
        "partition to bypass this check"
    )


def _missing_apple_data_error() -> RuntimeError:
    return RuntimeError(
        "Apple system data is missing or unreadable, so installation stopped "
        "before disk changes. Without this data, Omarchy cannot use the Touch "
        "Bar (including Esc and the function-key row), Touch ID, the FaceTime "
        "camera, or the ambient-light sensor. Back up anything needed from the "
        "internal disk, connect the Mac to power, and quit the installer. Restart "
        "while holding Option-Command-R. In Disk Utility choose View > Show All "
        "Devices, select the internal physical disk, and erase it as APFS with GUID "
        "Partition Map. This erases everything on that disk. Reinstall macOS, let "
        "it boot successfully once, then retry Omarchy"
    )
