# T1 EFI VM test

Run `./test/t1-efi-vm` on Arch with QEMU, a readable kernel and matching modules, Python, cpio, gzip, tar, kmod, systemd, util-linux, parted, dosfstools, btrfs-progs, cryptsetup, and pciutils.

The runner needs no root privileges. It boots an initramfs with two synthetic disks, without host disk access, shared directories, USB passthrough, or networking. Logs and disposable images remain in `test-runs/t1-efi-vm.*/`. Missing completion markers or a ten-minute timeout fail the test.

Override `QEMU`, `QEMU_FIRMWARE_PATH`, `KERNEL_VERSION`, or `KERNEL_IMAGE` when their defaults do not match your host.

The guest checks production partitioning helpers and the unattended-install guard with real GPT/FAT/LUKS2/Btrfs operations: multiple Apple ESPs, separate install disk, format guards, rollback, damaged metadata, and missing data. Preserved GPT entries, PARTUUIDs, and raw ESP hashes must remain identical.

This does **not** validate a complete ISO install, bootloader, remaining orchestrator phases, T1 hardware, or calibration import. Encryption uses a test-only KDF. Run `./test/all` for unit coverage.
