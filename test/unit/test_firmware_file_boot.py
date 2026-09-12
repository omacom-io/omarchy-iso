import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'configs/airootfs/usr/share/omarchy-iso'))
sys.modules.setdefault('orchestrator.archinstall_adapter', types.ModuleType('orchestrator.archinstall_adapter'))
from orchestrator import phases_impl as p


class FirmwareFileBootTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = types.SimpleNamespace(
            target=Path(self.tmp.name), is_protected=True,
            omarchy_install={'boot': {'registration': 'firmware-file'},
                             'storage': {'esp_device': '/dev/nvme0n1p5'}})

    def test_explicit_file_mode_copies_loader_without_nvram_calls(self):
        with mock.patch.object(p, '_read_efibootmgr') as read, \
             mock.patch.object(p, '_register_limine_efi_entry') as register, \
             mock.patch.object(p, '_split_partition_device', return_value=('/dev/nvme0n1', 5)), \
             mock.patch.object(p, '_copy_required') as copy, \
             mock.patch.object(p, '_write_limine_pacman_hook') as hook, \
             mock.patch.object(p, 'info'):
            p._install_pre_mounted_limine(self.ctx)
        read.assert_not_called()
        register.assert_not_called()
        self.assertEqual(copy.call_args.args[1], self.ctx.target / 'boot/EFI/limine' / p.efi_binary_name())
        self.assertIn('/EFI/limine/', hook.call_args.args[1])
        self.assertFalse(p._boot_intent(self.ctx)['enable_fallback'])

    def test_default_mode_still_surfaces_variable_failure(self):
        self.ctx.omarchy_install['boot'] = {}
        with mock.patch.object(p, '_read_efibootmgr', side_effect=RuntimeError('EFI unavailable')), \
             self.assertRaisesRegex(RuntimeError, 'EFI unavailable'):
            p._install_pre_mounted_limine(self.ctx)

    def test_rejects_shared_fallback_path(self):
        self.ctx.omarchy_install['boot']['esp_path'] = '/EFI/BOOT'
        with self.assertRaisesRegex(RuntimeError, 'dedicated Limine'):
            p._boot_intent(self.ctx)

    def test_rejects_unknown_mode(self):
        self.ctx.omarchy_install['boot']['registration'] = 'ignore-errors'
        with self.assertRaisesRegex(RuntimeError, 'registration'):
            p._boot_intent(self.ctx)

    def test_rejects_full_disk_mode(self):
        self.ctx.is_protected = False
        with self.assertRaisesRegex(RuntimeError, 'protected/pre-mounted'):
            p._boot_intent(self.ctx)
