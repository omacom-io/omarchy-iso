# AArch64 platform support

`configs/aarch64/platforms.json` is the source of truth for ARM machines that
need more than the generic `linux-aarch64` boot path. It keeps hardware support
in one ISO: the builder stages the union of the declared resources, and the
installer applies only the entry matching the target machine.

An entry in the manifest is not, by itself, a claim that a machine has been
tested. See [Current coverage](#current-coverage) for the validation state of
the entries shipped today.

## The support model

AArch64 support has three layers:

1. `linux-aarch64` is a multi-platform kernel. A separate kernel or ISO is not
   normally required for each board.
2. A SoC family shares most kernel modules, firmware packages, and boot
   arguments. For example, Snapdragon X Elite laptops based on `x1e80100` can
   start from the same family requirements.
3. Each board still needs its own hardware description and identity. A DTB is
   exact board data, not a generic driver bundle; it describes regulators,
   GPIOs, panels, input devices, buses, and power domains. Never substitute a
   DTB from a similar product.

The kernel package currently carries hundreds of Qualcomm DTBs, including the
upstream laptop DTBs. They are available inside the live root after Linux has
booted. A board whose firmware does not give Linux a usable hardware
description needs its selected DTB copied outside the squashfs so GRUB can load
it *before* the kernel. Declaring `boot.hardware_description` as
`dtb-override` is what asks the builder to make that second copy.

Staging the supported Snapdragon laptop DTB catalog is safe and inexpensive;
choosing the wrong board description is not. Do not turn the kernel's entire
Qualcomm tree (which also contains phones, routers, development boards, and
revision-specific variants) into an undifferentiated boot menu. Add one product
entry per board, with its exact DTB and SMBIOS selector. A manual live-boot
choice may be added while identity data is being collected, but automatic and
installed-system selection require a reliable match.

The same rule applies to initramfs contents. Drivers present in the universal
kernel are not necessarily included by `mkinitcpio`, and firmware filenames
constructed at runtime are not necessarily visible to `modinfo`. Everything
needed between kernel entry and encrypted-root unlock must be made explicit.

## Current coverage

| Platform | Hardware description | Declared coverage | Physical validation |
| --- | --- | --- | --- |
| Lenovo Yoga Slim 7x (83ED) | Explicit `x1e80100` DTB | DTB, Qualcomm package, pre-LUKS display/input/watchdog/retimer modules, dynamic GPU firmware | Full encrypted installation validated: the corrected initramfs renders the Plymouth LUKS prompt, Limine finalization completes, and the installed OS boots successfully |
| NVIDIA DGX Spark | Firmware | NVIDIA packages and graphical unlock boot arguments | September 5 ISO installed to an external SSD; graphical unlock and desktop boot validated with edited boot arguments, including a boot without debug logging. A fresh ISO with this manifest change has not been tested |
| ASUS Ascent GX10 | Firmware | NVIDIA runtime and DKMS packages only | Early-boot dependency audit and physical installation are not complete |

The GX10 package-only entry and Spark support remain bring-up work. They
must not be described as complete platform support until their storage,
display, input, watchdog, firmware, and encrypted-boot paths have been tested.

## Manifest reference

The document has a `schema_version`, a human-readable `description`, and a
`platforms` array. Each platform contains the following fields.

### Identity

- `id`: stable lowercase identifier used by tests and logs.
- `name`: human-readable product name.
- `match`: one or more SMBIOS selectors. Selectors are ORed; all fields inside
  one selector are ANDed. Matching is exact and case-sensitive after leading
  and trailing whitespace is removed. Supported fields are `sys_vendor`,
  `product_name`, and `product_version` from `/sys/class/dmi/id/`.

Use the smallest selector that uniquely identifies the board. Do not guess a
marketing name or match only a broad vendor string. Multiple selectors are
appropriate for confirmed firmware revisions that report different identities.

### Boot description

- `boot.hardware_description`: `firmware` when UEFI/ACPI supplies Linux with a
  usable description; `dtb-override` when the bootloader must supply one.
- `boot.dtb`: required only for `dtb-override`. It is the path relative to
  `/boot/dtbs` in the `linux-aarch64` package, such as
  `qcom/x1e80100-lenovo-yoga-slim7x.dtb`.
- `boot.kernel_cmdline`: persistent, platform-specific arguments appended to
  installed Limine entries. Each array item is one argument with no whitespace.

Kernel arguments must have a demonstrated requirement. Diagnostic arguments
such as extra logging, removed quiet mode, or a temporary timeout belong in a
test boot entry until hardware results justify making them permanent.

### Kernel

- `kernel.package` identifies the package used by the platform.
- `kernel.availability` is `iso` when the configured repositories can place it
  in the offline mirror, or `vendor-required` when support cannot be shipped in
  the ISO yet.

The existence of an upstream DTB does not prove the selected kernel has every
required driver enabled. Confirm the DTB exists in the exact kernel package
being built and verify the resulting machine, rather than relying on a newer
upstream source tree.

### Initramfs

- `initramfs.modules`: modules that must be present before root unlock. Use
  module names, not `.ko` paths.
- `initramfs.files`: absolute firmware paths under `/usr/lib/firmware` that
  must be copied even when automatic discovery misses them.
- `initramfs.omit_hooks`: exceptional removal of an inherited mkinitcpio hook.
  This is a diagnostic or last-resort compatibility mechanism; explain and
  test every use.

The installer writes these values to
`/etc/mkinitcpio.conf.d/zz-omarchy-aarch64-platform.conf`. The drop-in persists
across kernel upgrades. Do not solve a missing-firmware failure by embedding an
entire firmware tree in every initramfs.

### Packages

`packages` contains target packages needed only by the matched platform. The
builder downloads the union of all platform packages into the ISO's offline
repository; the installer installs only the matched entry's list. Every package
must exist for AArch64 in the configured repositories.

Package installation and initramfs inclusion are separate concerns. Installing
`linux-firmware-qcom` or `nvidia-utils` into the target does not make firmware
available before an encrypted root has been opened. Add early firmware to
`initramfs.files` when automatic inclusion cannot be proven.

## Adding a platform

### 1. Record exact identity

Collect the values on the physical machine; do not infer them from a product
page:

```sh
for field in sys_vendor product_name product_version; do
  printf '%s: ' "$field"
  cat "/sys/class/dmi/id/$field"
done
```

Record the firmware version and the exact product/SKU used for testing in the
pull request. If the installer cannot boot yet, obtain the same data from the
factory OS or a working ARM live environment.

### 2. Determine the hardware-description path

Establish whether the kernel successfully consumes ACPI or a DTB supplied by
firmware, or instead requires a bootloader DTB override. For an override:

- Select the exact upstream board DTB, including revision or display variants.
- Confirm it exists and is non-empty in the built `linux-aarch64` package.
- Add a distinct live GRUB entry so generic ARM systems never receive it.
- Verify the installed Limine entry receives the same DTB.

An upstream DTB makes a board a good support candidate, not automatically a
supported system. We still need its boot identity and pre-root dependency set.

### 3. Find the pre-root dependency closure

For an encrypted installation, inventory everything required before the LUKS
prompt can be displayed and operated:

- boot storage and its bus/controller;
- display controller, GPU, clocks, resets, PHYs, and panel/output path;
- built-in keyboard or the USB/I2C path used for input;
- watchdog and power-domain drivers that can reset or disable the board;
- firmware requested by any of those drivers.

Use the working system's journal and driver bindings as evidence. `lsmod`,
`modinfo -F firmware`, `/sys/bus/*/devices/*/driver`, and kernel logs are useful,
but none is complete alone. Search driver source or trace firmware requests
when filenames are selected from DT properties, SMBIOS identity, or chip IDs.

Start a same-SoC board from the established family list, then verify it. Copying
the X Elite baseline is reasonable for another `x1e80100` laptop; treating it
as proven without checking board-specific firmware and input/display paths is
not. A later SoC generation such as Snapdragon X2 needs a separate family
baseline even though it uses the same multi-platform kernel.

### 4. Separate diagnosis from the permanent fix

Change one boot boundary at a time. Useful diagnostic images include a full
no-`autodetect` image and a delayed-KMS image. A black screen with a responsive
keyboard and successful blind passphrase is evidence of a display handoff
failure, not a stalled kernel or broken encryption.

Do not commit a huge diagnostic initramfs, permanently disable Plymouth, or
remove early KMS merely because it masks the symptom. Translate the result into
the smallest explicit module and firmware set that preserves the branded
unlock flow.

### 5. Validate the installed lifecycle

A platform is ready to be marked physically validated only after checking:

1. The live ISO boots using the intended entry.
2. Display and input work in the installer.
3. Installation completes from the offline repository.
4. The normal encrypted Limine entry shows a usable LUKS prompt.
5. The installed desktop starts and the expected hardware is functional.
6. `limine-update` preserves the selected DTB and arguments.
7. Regenerating the initramfs, including after a kernel update, preserves the
   declared modules and firmware.
8. A cold boot succeeds; a warm reboot alone is insufficient for firmware and
   watchdog validation.

In the pull request, state which checks were performed and retain logs for any
behavior that motivated a platform-specific setting.

### 6. Run repository checks

At minimum:

```sh
python -m unittest \
  test.unit.test_aarch64_platforms \
  test.unit.test_protected_esp_mount -q
git diff --check
```

Add or update matching tests for every new SMBIOS identity, DTB, required
package, and exceptional initramfs rule. The ISO build also fails when a
declared DTB is absent from the exact kernel package used for that image.

## Build and persistence boundaries

- `builder/build-iso.sh` copies the manifest into the live root, downloads the
  union of platform packages, and stages declared DTB overrides outside the
  squashfs.
- `_current_aarch64_platform()` matches the physical machine's SMBIOS identity.
- `_runtime_package_list()` installs packages only for the matched entry.
- `_configure_aarch64_platform_boot()` writes persistent mkinitcpio and Limine
  drop-ins into the target.
- The installed Limine post-hook reinserts the selected DTB into every generated
  Linux entry because `limine-update` rewrites `limine.conf`.
- `test/unit/test_aarch64_platforms.py` checks manifest safety, matching,
  persistent DTB injection, and early-boot configuration.

## NVIDIA DGX Spark graphical unlock

Plymouth's boot log detected `ttyS0` alongside the local console and reported
"serial consoles detected, managing them with details forced". Setting
`console=tty0` made the text unlock prompt visible; adding
`plymouth.ignore-serial-consoles` allowed the Omarchy graphical unlock theme.
The Spark entry retains Plymouth and the normal quiet boot settings. The
installer writes these arguments to the target's Limine configuration drop-in
so future boot-image generation includes them.

## ASUS Zenbook 14 UX3480Q bring-up candidate

The supplied box photo identifies model `UX3480QA-U1160W` (family label
`UX3480Q`), Snapdragon X `X1-26-100`, 8 GB LPDDR5X, 256 GB PCIe storage,
and a 14-inch WUXGA OLED display. These are packaging identifiers, not verified
SMBIOS match values. Proposed platform ID: `asus-zenbook-14-ux3480qa`.

Reported behavior: selecting either the generic live entry or the Lenovo Yoga
entry produces a black screen followed by a return to GRUB. No diagnostic log
yet distinguishes a bootloader failure from a kernel or firmware reset. The
Yoga entry supplies a different board's device tree and is not a valid ASUS
hardware-description test.

The exact `linux-aarch64-7.2.3-2-aarch64` package used for the September 9 ISO
contains `x1p42100-asus-zenbook-a14.dtb`, its LCD and EL2 variants, and
`x1e80100-asus-zenbook-a14.dtb` with its EL2 variant. It has no DTB named for
UX3480. The upstream [Qualcomm DTB catalog](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/Makefile)
also has no UX3480-named entry at the time of this audit. The
[A14 support submission](https://www.spinics.net/lists/devicetree/msg818212.html)
describes UX3407QA/UX3407RA; that does not establish UX3480QA compatibility.

Do not activate a manifest entry by substituting an A14 DTB or declaring a
working firmware-description path without evidence. The current manifest
schema requires a concrete boot description and nonempty SMBIOS selectors;
this candidate remains documented here until those fields can be established.

Collect identity from the ASUS's factory Windows installation with PowerShell:

```powershell
Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, SystemSKUNumber
Get-CimInstance Win32_ComputerSystemProduct | Format-List Vendor, Name, Version
Get-CimInstance Win32_BaseBoard | Format-List Manufacturer, Product, Version
Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion
```

Then establish the board's hardware-description path from a working Linux
boot or board-specific kernel work. For the initial log capture, use the
generic live entry, remove `quiet splash`, and add
`console=tty0 loglevel=7 panic=0`, preserving the media arguments. Record the
last messages and whether the firmware logo reappears before GRUB. Neither
these diagnostic arguments nor a matching identity alone establishes a working
platform profile.

## HP OmniBook X 16-cp1013dx Snapdragon X2 bring-up candidate

The user-confirmed ordered model is an HP OmniBook X 16-cp1013dx with Snapdragon X2 Elite
X2E-84-100. HP lists this processor in the
[16-cp1000 series specifications](https://support.hp.com/us-en/document/ish_14096181-14096226-16).
Qualcomm identifies its GPU as Adreno X2-85 in the
[X2 Elite product brief](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Snapdragon-X2-Elite-Product-Brief.pdf).
The user supplied the full order identifier `CPPP1013DX/D3LN7UA#ABA` after
confirming model `16-cp1013dx`; preserve that spelling as supplied rather than
treating it as a firmware identity. The HP product number is `D3LN7UA#ABA`.
The Windows reports collected from the physical machine establish the following
identity. Linux sysfs values still need confirmation on a live boot.

| Field | Observed value |
| --- | --- |
| System manufacturer / product vendor | `HP` |
| System model / product name | `HP OmniBook X Laptop 16-cp1xxx` |
| Product version | `ConfigID` |
| System SKU | `D3LN7UA#ABA` |
| Board manufacturer / product / version | `HP` / `8F46` / `87.26` |
| BIOS vendor | `Qualcomm Technologies Inc., Insyde Inc.` |
| BIOS version | `F.04` |
| BIOS Mode (user-reported Windows System Information) | `UEFI` |
| Secure Boot State (user-reported Windows System Information) | `On` |
| BIOS release date as exported by Windows | `3/18/2026 6:00:00 PM` |
| CPU | `Snapdragon(R) X2 Elite - X2E84100 - Qualcomm Oryon(TM) CPU`, 12 cores / 12 threads |

The candidate SMBIOS selector is `sys_vendor=HP` plus
`product_name=HP OmniBook X Laptop 16-cp1xxx`, subject to confirming Linux's
values and whether the series includes board variants needing separate boot
resources. `ConfigID` supplies no useful additional distinction in this report.

### Windows hardware inventory

Source: user-provided `system.txt`, `devices.csv` (268 records), and
`drivers.csv` (269 records). All device records report
`ConfigManagerErrorCode=0`; this is not a physical functionality test or proof
of Linux support.

| Component | Observed hardware / identity | Windows driver evidence |
| --- | --- | --- |
| GPU | Adreno X2-85; `QCOM0FF5`, subsystem `8F46103C`, revision `0049` | `32.0.146.0`, `oem126.inf` |
| Internal panel | `ATNA60KJ02-0`, `MONITOR\SDC4214` | Windows monitor driver |
| Keyboard | `QTEC0001`, I2C HID plus keyboard HID collection | `hidi2c`, `kbdhid` |
| Touchpad | `ELAN0189`, I2C HID | ELAN filter `44.2.2.1`, `oem48.inf` |
| Touchscreen | `ELAN2513`, I2C HID | `hidi2c`, touchscreen HID collection |
| NVMe storage | `PC SN5000S SDEPNSJ-512G-1006`; PCI `15B7:5036` | `stornvme` |
| Wi-Fi | FastConnect C7700 NCM820A; PCI `17CB:1112`, subsystem `8EF3103C` | `685.13804.40.10`, `oem142.inf` |
| Bluetooth | FastConnect C7700 NCM820A; `QCA_SHB\UART_H4_CLG` | `685.13804.30.0`, `oem133.inf` |
| USB-C control | `QCOM0F9D` | `qcusbcucsi_8480` |

The inventory includes Qualcomm I2C, PCIe, IOMMU, PMIC GLink, display services,
and peripheral image-loader devices. Many Windows service names use an `_8480`
suffix. These names and hardware IDs are research inputs, not Linux module
names or a verified DTB filename. The CSV files do not include firmware blobs,
ACPI tables, or the device parent/resource graph needed to reconstruct board
dependencies. The user separately confirmed BIOS Mode `UEFI` and Secure Boot
State `On` in Windows System Information. UEFI mode alone does not establish
that Linux can use this board's ACPI tables without a DTB override.

This now has an experimental firmware/ACPI manifest entry with
`initcall_blacklist=arm_smmu_init`. On September 8 this workaround reached the
live installer and its BitLocker check, with the boot stick on the working
USB-A path. Built-in input and USB-C remain unavailable; a powered hub showed
unreliable keyboard input. Installed boot and accelerated graphics are not
validated. The selector uses the Windows-reported HP product identity pending
Linux sysfs confirmation. There is no verified board DTB or complete pre-root
module and firmware inventory for this machine. Do not use the
Yoga's `x1e80100` DTB, clock modules, or Lenovo GPU firmware path as substitutes.

### Windows System Information export

The subsequently supplied `x2e nfo.nfo` is an XML System Information export
created at `09/08/26 02:50:17` UTC. It confirms the same model, SKU, board and
BIOS, and reports no Problem Devices. It adds 52 Memory resource records,
1101 IRQ records, and 37 Conflicts/Sharing records (sharing is not itself a
fault). Those records provide useful register/interrupt inventory for a board
comparison. No watchdog/SBSA/WDAT/GTDT entry was found in the parsed data rows,
and the export does not contain raw ACPI table payloads. This absence from
System Information does not establish absence of a firmware watchdog.

### Raw ACPI collection

`X2-ACPI-20260908-132713.zip` was retrieved from the user-specified SMB share.
It contains APIC (1529 bytes), DSDT (460121), FACP (276), GTDT (156), and
IORT (6074). All five have matching declared lengths and valid ACPI checksums.
WDAT was not enumerated, and retrieval returned Win32 error 1168.
GTDT revision 3 has `platform_timer_count=0` and `platform_timer_offset=0`,
so it supplies no SBSA watchdog subtable. Thus enabling WDAT or adding
`sbsa_gwdt` alone is not a supported fix for this ACPI boot path: neither has
a standard watchdog description in the collected tables. This does not rule
out a vendor-controlled or otherwise undescribed hardware watchdog.

The remaining investigation includes the DSDT and IORT, particularly the
SMMU initialization path seen immediately before the screen cuts out.
Three SSDT signatures were enumerated but their payloads were not collected
by the targeted script; AML analysis must account for that missing context.

### Ubuntu and upstream DTB search

Ubuntu Concept's [X Elite PPA](https://launchpad.net/~ubuntu-concept/+archive/ubuntu/x1e)
lists the older HP OmniBook X 14 among tested devices; this is not evidence for
the X2-based 16-cp1xxx. Its [kernel build guide](https://discourse.ubuntu.com/t/how-to-build-your-own-ubuntu-concept-x-elite-kernel/49941)
points to the Resolute `qcom-x1e-7.0` branch. Direct inspection of that branch's
Qualcomm DTB Makefile was blocked by HTTP 403, so the current package/source
DTB inventory has not been exhaustively verified.

An [August 30 upstream patch](https://lkml.iu.edu/2608.3/12244.html) adds
`glymur-hp-omnibook-ultra-kg0xxx.dts` for the OmniBook Ultra 14, SKU
`D29KLAS#ABA`, board `8F03`. This is a potential development reference, not a
DTB for the user's `8F46` board. No exact 16-cp1xxx/8F46 DTB was found in the
Ubuntu pages and upstream submissions searched. This is a search result,
not proof that no unpublished or unindexed board support exists.

### Initial live-boot evidence

The user confirmed the September 5 AArch64 ISO. Its package list contains
`linux-aarch64 7.2.3-1` and `grub 2:2.14-1.1`. Both the generic entry and the
Yoga entry with its entire `devicetree` command removed returned to GRUB.
The user also reported seeing an echo placed after an explicit `boot` command,
without an intervening HP logo.

A photograph of a subsequent `set debug=linux,efi` attempt shows GRUB recognizing
the UEFI-stub kernel, enabling LoadFile2 initrd loading, reporting a kernel size
of 44509696 bytes, starting the EFI image, and printing
`Providing initrd via EFI_LOAD_FILE2_PROTOCOL`. The photograph contains neither
an explicit error nor the post-boot echo. It establishes progress to the EFI
initrd callback, not successful completion of the transfer or Linux startup.
The failure cause remains undetermined; these observations do not establish
that Plymouth or a missing DTB caused the return.

The follow-up photograph with `efi=debug` shows EFI-stub messages reporting
the initrd loaded, its measurement into PCR 9, `Generating empty DTB`, and
`Exiting boot services...`. This confirms initrd loading progressed beyond
the earlier callback trace. The exit message precedes completion of the
boot-services exit path and does not prove that exit succeeded. An empty DTB
means no board DTB was supplied to the stub; it does not itself establish that
ACPI is unusable. The post-boot echo is not visible in this photograph. Whether
the post-boot echo appears remains unconfirmed. The user reports this attempt
goes black and then returns to GRUB. This does not distinguish a reset from
a returned EFI image on its own. The next isolated test replaces `efi=debug`
with `efi=debug,novamap` to bypass runtime virtual-address-map installation;
this tests a possible failure near the observed boundary, not a proven fix.
The user confirmed `efi=debug,novamap` produced the same black screen and return
to GRUB, so it is not an established workaround.

The embedded IKCONFIG extracted directly from the September 5 ISO's
`arch/boot/aarch64/vmlinuz-linux-aarch64` confirms `CONFIG_EFI_EARLYCON=y`,
`CONFIG_ACPI=y`, `CONFIG_ARCH_QCOM=y`, and `CONFIG_ARM64_4K_PAGES=y`.
The next diagnostic enables `earlycon=efifb keep_bootcon` to seek kernel output
after EFI-stub logging ends. These configuration flags do not establish full
X2 or OmniBook board support.

The `earlycon=efifb keep_bootcon` test produced substantial kernel output.
The supplied final-frame screenshot contains timestamps from approximately
7.07 through 7.77 seconds, proving this attempt passed the EFI handoff and
entered normal kernel initialization. This supersedes the earlier working
hypothesis of an EFI-handoff-only failure. Visible messages include:

- `acpi-ged ACPI0013:00` and `:01` IRQ/`_CRS` parsing failures, probe error `-22`;
- a missing GenericSerialBus operation-region handler and AC-adapter state
  evaluation failure with `AE_NOT_EXIST`;
- lid-switch registration and multiple thermal `_PSL` evaluation failures;
- `msm_serial: driver initialized` followed by `arm-smmu.0.auto` SMMUv2
  capability reporting, still printing at approximately 7.77 seconds.

No kernel panic, reset reason, or watchdog expiry is visible in this frame.
Neither the ACPI errors nor the last visible SMMU driver identify the cause
of the subsequent black screen and return to GRUB. Next evidence needed is
the elapsed wall-clock time to the return and earlier boot messages about
watchdogs, ACPI tables, and the kernel command line, ideally from the full video.

Inspection of the September 5 ISO's embedded kernel configuration and live
initramfs on September 8 found `CONFIG_ARM_SBSA_WATCHDOG=m`, but no `sbsa_gwdt`
module or watchdog module directory in the initramfs file list. `CONFIG_WDAT_WDT`
is disabled. `CONFIG_PANIC_TIMEOUT=0` is already the kernel build default.
These are gaps in watchdog coverage, not proof that this HP uses either timer.
The supplied boot video was extracted at 10 fps over video seconds 20–41;
sampled OCR did not establish a panic or watchdog expiry. A firmware-table
inventory (particularly GTDT/WDAT) is needed before selecting a watchdog fix.

September 8 ACPI follow-up: the collected GTDT has zero platform timers and
WDAT was not enumerated, so these tables do not advertise either an SBSA or
WDAT watchdog. This does not rule out an undocumented firmware watchdog.
Local ACPICA disassembly of DSDT reports 13 unresolved external methods;
the three enumerated SSDTs were not captured by the targeted collector.
IORT describes an ARM MMU-500 at `0x15000000` (plus other IOMMU nodes).

Matching upstream Linux v7.2.3 `drivers/iommu/arm/arm-smmu/arm-smmu.c`
prints `preserved 0 boot mappings` at the end of
`arm_smmu_rmr_install_bypass_smr()`. The next call in the probe is
`arm_smmu_device_reset()`, followed by `arm_smmu_test_smr_masks()`.
This makes SMMU initialization a concrete diagnostic target, not a proven
reset cause. The built-in driver's registered init function is `arm_smmu_init`.
Proposed one-boot test: generic ISO entry, no devicetree override, remove
`quiet splash`, retain original media arguments and `initramfs_async=0`, append:

```text
earlycon=efifb keep_bootcon loglevel=8 ignore_loglevel efi=debug,novamap panic=0 initcall_debug initcall_blacklist=arm_smmu_init
```

This temporarily skips the SMMUv1/v2 driver registration; it is not a production
configuration and dependent devices may fail to probe. Record whether the
blacklist is acknowledged, whether boot advances, and the last output before
any reset.

The user reported this test progressed much farther. The supplied September 8
photo shows approximately 52 seconds of uptime and an interactive `[rootfs ~]#`
initramfs prompt after the live-media search failed to locate
`2026-09-05-17-23-29-00`. NVMe partitions are visible; the displayed filesystem
probe errors alone do not establish disk corruption. This strongly implicates
the skipped SMMU initialization path in the earlier reset, but does not isolate
the failing register operation. USB enumeration and the exact command line
still need inspection to distinguish unavailable live media from a marker
mismatch. The blacklist is diagnostic, not a validated platform fix.

Before enabling the entry:

1. The initial Windows identity collection is complete. To refresh it after a
   firmware change, run these in PowerShell:

   ```powershell
   Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, SystemSKUNumber
   Get-CimInstance Win32_ComputerSystemProduct | Format-List Vendor, Name, Version
   Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion
   ```

   Confirm the Linux `sys_vendor`, `product_name`, and `product_version` values
   with the identity commands above when a live environment boots.
2. Establish a working hardware-description path for this exact board and
   confirm any required DTB and drivers exist in the ISO's kernel package.
3. Inventory the X2 display/GPU firmware, clock and power drivers, storage,
   keyboard, and USB-C display dependencies before encrypted-root unlock.
   `linux-firmware-qcom` is a candidate package; its presence alone does not
   establish that the required firmware is shipped or included in the initramfs.
4. Add the verified manifest entry, matching tests, and live boot entries if a
   DTB override is required. Validate the encrypted installation lifecycle
   using the same procedure as the Yoga.

## Lenovo Yoga Slim 7x (83ED) findings

Observed on physical hardware on 2026-09-03:

1. The generic installed Limine entry supplied no DTB. The kernel did not
   initialize `sbsa_gwdt`, and firmware's reported 10-second watchdog reset the
   machine. Supplying `x1e80100-lenovo-yoga-slim7x.dtb` changed this from a boot
   loop to a continuing kernel boot.
2. The live ISO contained `linux-firmware-qcom`, but the target package set did
   not. The installed root therefore had no `/usr/lib/firmware/qcom`. The Yoga
   entry now selects that package from the offline mirror.
3. The target initramfs was about 20 MiB versus about 191 MiB for the working
   live image. The working unencrypted system's journal showed EFI framebuffer
   and NVMe at about 1.8 seconds, root mount at 2.86 seconds, and the Qualcomm
   firmware, I2C keyboard, and MSM display takeover at about 5 seconds. The
   encrypted target runs `kms` before root unlock.
4. A 159 MiB no-`autodetect` diagnostic image included 573 modules but omitted
   DT-selected firmware and reproduced the black screen. A 17 MiB delayed-KMS
   image booted after a blind passphrase, proving storage, encryption, watchdog,
   keyboard, kernel, and installed userspace were healthy.
5. An EFI-backed pre-unlock trace proved that loading the initial MSM module set
   was insufficient: from 2 through 17 seconds the only framebuffer remained
   `EFI VGA`, no DRM connectors appeared, and all three external DisplayPort
   controllers remained in deferred probe. Their `aux_bridge` instances could
   not acquire the downstream DRM bridges supplied by the Yoga's three Parade
   PS8830 USB-C retimers. The `ps883x` module appeared only after switch-root;
   it must therefore be explicit in the initramfs even though the internal
   panel is eDP.
6. The production entry retains early KMS and the branded Plymouth unlock. It
   explicitly includes the MSM display stack, PS8830 retimer bridge, I2C
   keyboard, SBSA watchdog, and the three dynamically selected GPU firmware
   files. On 2026-09-05, a full encrypted installation rendered the unlock
   prompt, completed Limine finalization, and booted successfully.

## HP September 8 installation follow-up

The September 8 ISO's unedited HP entry reached the installer after more than
30 seconds. The command line confirms only `initcall_blacklist=arm_smmu_init`
was added; diagnostic EFI arguments were not necessary for this result.
Linux confirms `HP` / `HP OmniBook X Laptop 16-cp1xxx`. External USB input and
storage work on at least one USB-A path; built-in input, USB-C, and Wi-Fi are
not working in the observed session. A keyboard hub rejected the SanDisk's
power requirement; a powered hub had dropped keystrokes (cause unresolved).

Installation stopped reading EFI entries: efibootmgr reports variables are not
supported and manually mounting efivarfs returns EOPNOTSUPP. An efivars.0
platform device exists. This does not establish the underlying firmware or
kernel defect. Root packages are present, but user creation and subsequent
finalization did not complete. The target has its own 2 GiB FAT partition p5
and LUKS/Btrfs p6; recovery inspection used a read-only mapping.

An explicit protected/pre-mounted install option is now available in
`omarchy_install.boot`: `"registration": "firmware-file"`. Default remains
`"nvram"`; EFI failures never silently select this mode. It installs and
maintains the dedicated `/EFI/limine/limine_aa64.efi` loader, disables fallback
replacement, and omits NVRAM registration/checks while retaining other boot
validation. This requires selecting that file in firmware (or independently
registering it); HP firmware support for that operation has not been verified.
This is not automatic resume and has not been deployed to the running HP.
Do not rerun a partitioning workflow to recover the partial installation.
