"""T1 Apple-EFI safety checks for interactive and unattended installs."""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl, t1_efi  # noqa: E402


def make_ctx(tmp: Path, *, mode="protected", config_type=None, wipe=None):
    if config_type is None:
        config_type = "pre_mounted_config" if mode == "protected" else "default_layout"
    if wipe is None:
        wipe = mode == "full_disk"
    modifications = [{"device": "/dev/target", "wipe": True}] if wipe else []
    return types.SimpleNamespace(
        mode=mode,
        is_protected=mode == "protected",
        target=tmp / "mnt",
        state_dir=tmp / "state",
        state={},
        user_configuration={"disk_config": {
            "config_type": config_type,
            "device_modifications": modifications,
        }},
        omarchy_install={"mode": mode, "storage": {"esp_device": "/dev/target2"}},
    )


class T1PreservationPlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def validate(self, ctx, sources, *, supported=True):
        with (
            mock.patch.object(t1_efi, "_is_supported_t1_mac", return_value=supported),
            mock.patch.object(t1_efi, "_parent_disk", return_value="/dev/target"),
            mock.patch.object(
                t1_efi, "_discover_apple_efi_sources", return_value=sources,
            ) as discover,
        ):
            t1_efi.validate_t1_efi_preservation(ctx)
            return discover

    def test_non_t1_full_disk_plan_is_unchanged(self):
        ctx = make_ctx(self.root, mode="full_disk")
        discover = self.validate(ctx, {}, supported=False)
        discover.assert_not_called()

    def test_t1_full_disk_target_with_apple_data_hard_stops(self):
        ctx = make_ctx(self.root, mode="full_disk")
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {"/dev/target": {"/dev/target1"}})

    def test_t1_full_disk_target_is_valid_with_apple_data_on_another_disk(self):
        ctx = make_ctx(self.root, mode="full_disk")
        self.validate(ctx, {
            "/dev/target": set(),
            "/dev/internal": {"/dev/internal1"},
        })

    def test_t1_without_any_readable_apple_source_hard_stops(self):
        ctx = make_ctx(self.root, mode="full_disk")
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {})

    def test_t1_target_must_be_an_attached_whole_disk(self):
        ctx = make_ctx(self.root, mode="full_disk")
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {"/dev/internal": {"/dev/internal1"}})

    def test_t1_mode_label_cannot_hide_default_layout(self):
        ctx = make_ctx(self.root, mode="protected", config_type="default_layout")
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {"/dev/internal": {"/dev/internal1"}})

    def test_t1_pre_mounted_plan_cannot_retain_a_wipe_operation(self):
        ctx = make_ctx(self.root, wipe=True)
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {"/dev/internal": {"/dev/internal1"}})

    def test_t1_protected_target_with_distinct_preserved_data_is_valid(self):
        ctx = make_ctx(self.root)
        self.validate(ctx, {"/dev/target": {"/dev/target1"}})

    def test_t1_protected_target_with_only_external_data_is_valid(self):
        ctx = make_ctx(self.root)
        self.validate(ctx, {
            "/dev/target": set(),
            "/dev/internal": {"/dev/internal1"},
        })

    def test_t1_protected_target_cannot_reuse_apple_esp_for_omarchy(self):
        ctx = make_ctx(self.root)
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {"/dev/target": {"/dev/target2"}})

    def test_each_boundary_rescans_plan_and_live_data(self):
        ctx = make_ctx(self.root)
        first = self.validate(ctx, {"/dev/target": {"/dev/target1"}})
        first.assert_called_once_with(ctx.state_dir, "/dev/target")
        second = self.validate(ctx, {"/dev/target": {"/dev/target1"}})
        second.assert_called_once_with(ctx.state_dir, "/dev/target")
        ctx.user_configuration["disk_config"]["device_modifications"] = [{"wipe": True}]
        with self.assertRaises(RuntimeError):
            self.validate(ctx, {"/dev/target": {"/dev/target1"}})


class T1ModelDetectionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dmi = Path(self.tmp.name)

    def detected(self, vendor, model):
        (self.dmi / "sys_vendor").write_text(vendor)
        (self.dmi / "product_name").write_text(model)
        with mock.patch.object(t1_efi, "_DMI_ROOT", self.dmi):
            return t1_efi._is_supported_t1_mac()

    def test_exact_supported_apple_model_is_detected(self):
        self.assertTrue(self.detected("Apple Inc.\n", "MacBookPro13,3\n"))

    def test_other_apple_model_is_not_detected(self):
        self.assertFalse(self.detected("Apple Inc.\n", "MacBookPro15,1\n"))

    def test_model_name_without_apple_vendor_is_not_detected(self):
        self.assertFalse(self.detected("Example Vendor\n", "MacBookPro13,3\n"))


class T1AppleEfiProbeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_apple_path_match_is_case_insensitive(self):
        (self.root / "efi" / "Apple").mkdir(parents=True)
        self.assertTrue(t1_efi._contains_apple_directory(self.root))

    def test_whole_disk_inventory_excludes_partitions_and_mappers(self):
        payload = {"blockdevices": [
            {"path": "/dev/mapper/root", "type": "crypt"},
            {"path": "/dev/internal", "type": "disk", "children": [
                {"path": "/dev/internal1", "type": "part"},
            ]},
            {"path": "/dev/loop0", "type": "loop"},
        ]}
        result = CompletedProcess([], 0, stdout=json.dumps(payload), stderr="")
        with mock.patch.object(t1_efi, "capture", return_value=result):
            self.assertEqual(t1_efi._whole_disks(), ["/dev/internal"])

    def test_fat_partition_list_is_limited_to_parts(self):
        payload = {"blockdevices": [{
            "path": "/dev/fake",
            "type": "disk",
            "fstype": None,
            "children": [
                {
                    "path": "/dev/fake1",
                    "type": "part",
                    "fstype": "vfat",
                    "parttype": t1_efi._ESP_PARTTYPE,
                },
                {
                    "path": "/dev/fake2",
                    "type": "part",
                    "fstype": "btrfs",
                    "parttype": "not-an-esp",
                },
                {
                    "path": "/dev/fake3",
                    "type": "part",
                    "fstype": "vfat",
                    "parttype": "not-an-esp",
                },
            ],
        }]}
        result = CompletedProcess([], 0, stdout=json.dumps(payload), stderr="")
        with mock.patch.object(t1_efi, "capture", return_value=result):
            self.assertEqual(t1_efi._fat_partitions("/dev/fake"), ["/dev/fake1"])

    def test_esp_with_unreadable_filesystem_hard_stops_inventory(self):
        payload = {"blockdevices": [{
            "path": "/dev/fake1",
            "type": "part",
            "fstype": None,
            "parttype": t1_efi._ESP_PARTTYPE,
        }]}
        result = CompletedProcess([], 0, stdout=json.dumps(payload), stderr="")
        with mock.patch.object(t1_efi, "capture", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "could not safely inspect"):
                t1_efi._fat_partitions("/dev/fake")

    def test_missing_partition_type_stops_target_inventory(self):
        for part_type in (None, "", " "):
            with self.subTest(part_type=part_type):
                payload = {"blockdevices": [{
                    "path": "/dev/fake1", "type": "part",
                    "fstype": "vfat", "parttype": part_type,
                }]}
                result = CompletedProcess([], 0, stdout=json.dumps(payload), stderr="")
                with mock.patch.object(t1_efi, "capture", return_value=result):
                    with self.assertRaisesRegex(RuntimeError, "could not safely inspect"):
                        t1_efi._fat_partitions("/dev/fake")
                    self.assertEqual(t1_efi._fat_partitions("/dev/fake", strict=False), [])

    def test_already_mounted_new_omarchy_esp_is_inspected_without_remount(self):
        mounted = self.root / "target-esp"
        (mounted / "EFI" / "limine").mkdir(parents=True)
        findmnt = CompletedProcess(
            [], 0,
            stdout=json.dumps({"filesystems": [{"target": str(mounted)}]}),
            stderr="",
        )
        with (
            mock.patch.object(t1_efi, "capture", return_value=findmnt),
            mock.patch.object(t1_efi.subprocess, "run") as run,
        ):
            self.assertEqual(
                t1_efi._inspect_partition("/dev/target2", self.root / "state"),
                "other",
            )
            run.assert_not_called()

    def test_sources_are_discovered_across_attached_whole_disks(self):
        contents = {
            "/dev/target1": "other",
            "/dev/internal1": "apple",
            "/dev/internal2": "apple",
        }
        with (
            mock.patch.object(
                t1_efi, "_whole_disks", return_value=["/dev/target", "/dev/internal"],
            ),
            mock.patch.object(
                t1_efi,
                "_fat_partitions",
                side_effect=lambda disk, **_kwargs: {
                    "/dev/target": ["/dev/target1"],
                    "/dev/internal": ["/dev/internal1", "/dev/internal2"],
                }[disk],
            ),
            mock.patch.object(t1_efi, "_inspect_partition", side_effect=contents.get),
        ):
            self.assertEqual(
                t1_efi._discover_apple_efi_sources(self.root, "/dev/target"),
                {
                    "/dev/target": set(),
                    "/dev/internal": {"/dev/internal1", "/dev/internal2"},
                },
            )

    def test_unreadable_target_efi_probe_hard_stops_complete_discovery(self):
        contents = {"/dev/target1": "unreadable", "/dev/internal1": "apple"}
        with (
            mock.patch.object(
                t1_efi, "_whole_disks", return_value=["/dev/target", "/dev/internal"],
            ),
            mock.patch.object(
                t1_efi,
                "_fat_partitions",
                side_effect=lambda disk, **_kwargs: {
                    "/dev/target": ["/dev/target1"],
                    "/dev/internal": ["/dev/internal1"],
                }[disk],
            ),
            mock.patch.object(t1_efi, "_inspect_partition", side_effect=contents.get),
        ):
            with self.assertRaisesRegex(RuntimeError, "could not safely inspect"):
                t1_efi._discover_apple_efi_sources(self.root, "/dev/target")

    def test_unreadable_off_target_efi_does_not_hide_readable_source(self):
        contents = {"/dev/extra1": "unreadable", "/dev/internal1": "apple"}
        with (
            mock.patch.object(
                t1_efi,
                "_whole_disks",
                return_value=["/dev/target", "/dev/extra", "/dev/internal"],
            ),
            mock.patch.object(
                t1_efi,
                "_fat_partitions",
                side_effect=lambda disk, **_kwargs: {
                    "/dev/target": [],
                    "/dev/extra": ["/dev/extra1"],
                    "/dev/internal": ["/dev/internal1"],
                }[disk],
            ),
            mock.patch.object(t1_efi, "_inspect_partition", side_effect=contents.get),
        ):
            self.assertEqual(
                t1_efi._discover_apple_efi_sources(self.root, "/dev/target"),
                {
                    "/dev/target": set(),
                    "/dev/extra": set(),
                    "/dev/internal": {"/dev/internal1"},
                },
            )


class FilesystemBoundaryTest(unittest.TestCase):
    def test_guard_runs_before_archinstall_filesystem_operations(self):
        ctx = types.SimpleNamespace(state={})
        with (
            mock.patch.object(
                phases_impl,
                "validate_t1_efi_preservation",
                side_effect=RuntimeError("unsafe"),
            ),
            mock.patch.object(
                phases_impl.arch, "perform_filesystem_operations", create=True,
            ) as mutate,
        ):
            with self.assertRaises(RuntimeError):
                phases_impl.arch_install_system(ctx)
            mutate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
