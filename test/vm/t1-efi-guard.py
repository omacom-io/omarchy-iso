"""Run the production unattended-install guard against this VM's real disks."""

import os
import sys
from pathlib import Path
from types import SimpleNamespace

from orchestrator.t1_efi import _is_supported_t1_mac, validate_t1_efi_preservation


assert os.environ.get("OMARCHY_T1_VM_TEST") == "1"
assert Path("/sys/class/block/vda/serial").read_text().strip() == "T1_TEST_DISK_A"
assert _is_supported_t1_mac(), "model gate must execute the T1 checks"


def context(*, disk=None, esp=None):
    if esp:
        config = {"config_type": "pre_mounted_config"}
    else:
        config = {
            "config_type": "default_layout",
            "device_modifications": [{"device": disk, "wipe": True}],
        }
    return SimpleNamespace(
        mode="protected" if esp else "full_disk",
        state_dir=Path("/run/t1-guard"),
        user_configuration={"disk_config": config},
        omarchy_install={"storage": {"esp_device": esp}},
    )


def rejects(plan, reason):
    try:
        validate_t1_efi_preservation(plan)
    except RuntimeError as error:
        assert reason in str(error), f"unexpected rejection: {error}"
    else:
        raise AssertionError("unsafe plan accepted")


stage = sys.argv[1]
if stage == "layouts":
    rejects(context(disk="/dev/vda"), "target disk contains Apple EFI data")
    rejects(context(esp="/dev/vda1"), "separate EFI partition")
    validate_t1_efi_preservation(context(esp=sys.argv[2]))
    validate_t1_efi_preservation(context(disk="/dev/vdb"))
elif stage == "damaged":
    rejects(context(disk="/dev/vda"), "could not safely inspect")
elif stage == "missing":
    rejects(context(disk="/dev/vdb"), "Apple system data is missing")
else:
    raise AssertionError("unknown fixture stage")

assert not list(Path("/run/t1-guard").glob(".apple-efi-check-*")), "probe mount leaked"
print(f"ok - unattended T1 guard: {stage}")
