# Try Omarchy — Unofficial Live Desktop Preview ISO

> [!WARNING]
> **Community Build Notice & Hardware Testing Disclosure**  
> This is an unofficial, community-compiled bootable ISO built from John Sideserf's [`try-omarchy` branch](https://github.com/johnsideserf/omarchy-iso/tree/try-omarchy) (commit `91ec6f94fdff6d8bd01b23ccd09adbb0fce3ecfd`).  
> **Testing Status:** The build completed successfully and passed 100% of John's automated test suite (`test/unit/try-*`). However, **it has not yet been booted on bare-metal hardware** by the author. Community testers on physical x86_64 PCs or Intel T2 MacBooks are warmly welcomed to test and report feedback!

---

## What is "Try Omarchy"?

"Try Omarchy" lets you boot the Omarchy ISO on the machine you are about to wipe and experience the real Hyprland desktop on your actual hardware before committing — the x86 counterpart of the `try-omarchy` Mac app.

- **Ephemeral live session** running entirely in RAM (overlayfs).
- Installed **just-in-time** directly from the ISO's offline bundled mirror (`/var/cache/omarchy/mirror/offline`).
- Does not modify your existing drives until you explicitly choose to install.
- Exiting or rebooting leaves no persistent changes behind.

---

## System Requirements

- **Processor:** Standard 64-bit x86 processor (`x86_64`) or Intel-based MacBook (including T2 security chip models).
- **RAM:** Minimum **4 GiB** of RAM (required for the in-memory live overlay).
- **USB Drive:** At least **8 GB** USB flash drive.

---

## Flashing the ISO to USB

### On Windows (using Rufus)
1. Download and open [Rufus](https://rufus.ie/).
2. Select your USB drive under **Device**.
3. Under **Boot selection**, select `omarchy-2026.09.09-x86_64.iso`.
4. Click **START**.
5. **IMPORTANT:** When prompted with the dialog asking for *ISO Image mode* vs. *DD Image mode*, select:
   👉 **Write in DD Image mode**.  
   *(Archiso requires a raw 1:1 bit copy to find the offline package mirror during boot).*

### On Linux / macOS (using `dd`)
```bash
# Identify your USB drive (e.g. /dev/sdX on Linux or /dev/rdiskN on macOS)
sudo dd if=omarchy-2026.09.09-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### Using Ventoy
Simply copy `omarchy-2026.09.09-x86_64.iso` directly onto your Ventoy USB drive.

---

## How to Boot & Try Omarchy

1. Plug the USB into your PC / laptop.
2. Power on and open your BIOS/UEFI boot menu (typically `F12`, `F11`, `F8`, `F2`, or `Option/Alt` on Intel Macs).
3. Select your USB drive in UEFI mode.
4. From the boot menu, launch Omarchy.
5. In the installer dashboard / welcome screen, select **"Try Omarchy"**.
6. The system will unpack the desktop into memory and launch the live Hyprland session!

---

## Image Specifications & Integrity Verification

- **ISO Filename:** `omarchy-2026.09.09-x86_64.iso`
- **File Size:** `6,260,654,080 bytes` (5.83 GiB)
- **Kernel:** `linux-t2` (universal x86_64 support + Intel T2 Mac support)
- **Squashfs Superblock:** SquashFS 4.0, zstd-19 (`airootfs.sfs`: 5.53 GiB)
- **SHA-256 Checksum:**
  ```text
  EE781743C4BDDF3257241FC5C5464A7D5E66F557D280F58F59D5BA32D9489C0D
  ```

### Verify Integrity Before Booting

#### Windows (PowerShell):
```powershell
Get-FileHash .\omarchy-2026.09.09-x86_64.iso -Algorithm SHA256
```

#### Linux / macOS:
```bash
sha256sum omarchy-2026.09.09-x86_64.iso
```

---

## Author & License

- **Compiled & Maintained by:** Aarav Tank ([@aaravtank](https://github.com/aaravtank))
- **Based on original work by:** John Sideserf ([@johnsideserf](https://github.com/johnsideserf)) and the Omarchy project contributors.
- **License:** [MIT License](LICENSE)

```text
Copyright (c) 2026 Aarav Tank

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```
