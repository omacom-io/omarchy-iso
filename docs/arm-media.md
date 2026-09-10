# ARM media and hardware profiles

The ARM installer shares one build and install path, with two live-boot
targets. Both install `linux-aarch64` and use the package-owned
`linux-aarch64-pkgbase-shim` for kernel-image handling.

| Media target | Live boot | Default |
| --- | --- | --- |
| `x86_64/pc` | Existing x86 BIOS/UEFI path | x86 hosts |
| `aarch64/snapdragon` | UKI with Qualcomm DTBs selected by systemd hardware IDs | ARM hosts, including macOS `arm64` |
| `aarch64/generic` | GRUB kernel/initramfs with firmware-provided hardware description | Explicit opt-in |

Selecting generic media does not make firmware without usable Linux hardware
tables work. Apple Silicon and Raspberry Pi boot support are not added here.
The Snapdragon target retains its existing DTBs, kernel arguments and
initramfs module handling. Neither target implies support for every ARM board.

## Building

From the repository root, with Docker and a working ARM package repository
containing this PR's prerequisites:

```sh
bin/omarchy-iso-make --arch aarch64 --media-target aarch64/snapdragon --edge --keep-pkg-cache --no-boot-offer
bin/omarchy-iso-make --arch aarch64 --media-target aarch64/generic --edge --keep-pkg-cache --no-boot-offer
```

Use `--local-repo` and `--local-source` as before when the required packages or
runtime changes have not been published. `--arch` selects Docker's platform;
cross-architecture builds require working container emulation. Native ARM
builds are preferred. The existing `omarchy-iso-boot` helper remains x86-only,
so the launcher does not offer it for ARM images.

Offline caches are separated by channel, architecture and media target.
Snapdragon image names remain `omarchy-<date>-aarch64-<ref>.iso`; generic image
names start with `omarchy-generic-`. The manual ARM workflow has a matching
media-target selector. Neither workflow enables production package publishing.

## Live DSP startup

Snapdragon media keeps `qcom_q6v5_pas` blacklisted during the initramfs phase
because starting the DSP can reset USB-C installation media. On the tested
Yoga Slim 7x, leaving it disabled also prevents USB hotplug and battery status
from working in the live session.

`omarchy-live-dsp.service` starts the driver before the installer welcome
screen only when the active device tree identifies `lenovo,yoga-slim7x` and
the helper verifies the archiso overlay, its loop backing file and both
writable directories are in RAM. It refuses disk-backed or unfamiliar
layouts, mounted installation media, other mounted block devices and active
swap. Archiso normally copies sufficiently small images to RAM when memory
allows; if it does not, the driver stays disabled. No extra RAM copy is forced.

This service is staged only into Snapdragon live media, not generic ARM media
or the installed system. Other boards remain unchanged pending validation.
To disable it while investigating a boot problem, add `omarchy.live_dsp=0`
to the live boot arguments. Read its decisions with
`journalctl -b -u omarchy-live-dsp.service`; the helper's `--check` option
validates the guards without loading a driver. Failed checks skip startup,
and a driver-load failure is logged without requiring the installer to fail.

A manual late-load test on the Yoga with kernel 7.2.4 restored USB at
5000 Mbit/s and battery status. One subsequent unplug/replug and full ISO
readback passed. This does not yet validate automatic startup on a new boot.
CDSP remained offline because its firmware DTB was missing; the successful
ADSP test does not establish camera, compute-DSP or audio support.

## Installed hardware setup

`configs/aarch64/platforms.json` records exact SMBIOS vendor/product matches,
media targets, additional packages and installed kernel arguments. The same
manifest supplies the build's offline package union and the installer's
matched package list. A malformed or ambiguous manifest, or a known board
using the wrong media target, fails before disk cleanup.

| Profile | Identity | Additional setup |
| --- | --- | --- |
| Lenovo Yoga Slim 7x | `LENOVO` / `83ED` | Qualcomm firmware; boot/display setup stays in the Omarchy runtime |
| NVIDIA DGX Spark | `NVIDIA` / `NVIDIA_DGX_Spark` | ARM NVIDIA packages and `console=tty0 plymouth.ignore-serial-consoles` |
| ASUS Ascent GX10 | `ASUSTeK COMPUTER INC.` / `GX10` | ARM NVIDIA packages; no new kernel arguments |

Unmatched boards get no profile-specific package or command-line changes.
Existing Snapdragon runtime detection continues to handle its other boards;
the Yoga manifest entry is not a whitelist for all Snapdragon support.

Spark's arguments are written to
`/etc/limine-entry-tool.d/80-omarchy-aarch64-platform.conf` before the final UKI
build. This is persistent configuration consumed by subsequent
`limine-update` runs, not a patch to an installed package script. It does not
replace root/encryption arguments. The manifest is an installer input, not a
new runtime updater. Future changes to installed hardware settings belong in
the runtime or a maintained package.

The reusable kernel-image package remains in
[omarchy-pkgs#222](https://github.com/omacom/omarchy-pkgs/pull/222).
Repository refresh stays in
[omarchy#8672](https://github.com/omacom/omarchy/pull/8672), and the Yoga display
setup stays in [omarchy#8673](https://github.com/omacom/omarchy/pull/8673).
No second kernel shim, DTB rewrite hook or repository-refresh script is added.

## Attribution

- Marcelo Alcantara's [#149](https://github.com/omacom/omarchy-iso/pull/149),
  commit [`4897e8b`](https://github.com/maralcbr/omarchy-iso/commit/4897e8b740b163f2f0241736bcc7a72a0db008c3),
  supplied the architecture/media-target separation and isolated build-cache
  approach. Its offline keyboard implementation and tests are carried
  unchanged in a commit retaining his authorship. The build changes are
  adapted to preserve #129's tested Snapdragon path.
- Matt Gilg's [#156](https://github.com/omacom/omarchy-iso/pull/156), reviewed at
  [`b333b46`](https://github.com/gilgm12/omarchy-iso/commit/b333b46c6f3d1ec4e1c97ab6811b94b53006da55),
  supplied the hardware-profile model, identities and package requirements,
  plus the generated-initramfs inspection approach. The adapted manifest
  delegates Yoga setup to the existing runtime instead of duplicating it.
- Jim Martin's [`4f70137`](https://github.com/gilgm12/omarchy-iso/commit/4f70137c27598c54450d155982eb4e58b9a8e367)
  supplied the Spark graphical disk-unlock settings.

Adapted work carries co-author trailers, including the original AI co-author
credit from Matt's source commit. Sean's and Jimmy Van Veen's existing commits
remain in #129's history.

## Validation boundary

`test/all` covers architecture/target selection, cache isolation, build
command construction, exact platform matching, offline package coverage,
pre-install rejection and persistent boot configuration. The live-root
customization also inspects the generated initramfs for `archiso` and
`archiso_loop_mnt`, rejecting an installed-system image before wrapping a UKI.

Previous Yoga live-USB tests validate the earlier Snapdragon build. Matt's
and Jim's fresh-install reports apply to their source branch, not automatically
to this consolidation. A newly built image, live boot, fresh install onto a
disposable drive, update and reboot are still required for the combined path.
Do not use an existing installation containing valuable files as that test
target. Camera, fan, suspend and hibernation support are separate from these
installer changes.
