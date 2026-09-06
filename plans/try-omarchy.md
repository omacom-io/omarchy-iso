# Plan: Try Omarchy — a live desktop installed just-in-time from the bundled mirror

## Goal

Let someone boot the Omarchy ISO on the machine they are about to wipe and see the real desktop on their real hardware before committing — the x86 counterpart of the `try-omarchy` Mac app — without adding a byte to the ISO, without touching the install path, and without a second boot entry.

Not a rescue mode, not a persistent USB, not a portable Omarchy. The session is ephemeral by design and ends in "Install Omarchy".

## Context

The ISO already contains everything a live desktop needs. `omarchy-4.0.2.iso` is 6,227,752,960 bytes (5.80 GiB); `arch/x86_64/airootfs.sfs` is 5.51 GiB of that. Inside the squashfs, `/var/cache/omarchy/mirror/offline` holds **1,248 packages / 4.40 GiB** — the full closure of `omarchy-base.packages`, `omarchy-other.packages`, and `builder/archinstall.packages`, stored uncompressed (`configs/profiledef.sh:29`) so pacstrap reads it at line speed. The live root around it is 483 packages, ~1.1 GiB compressed, and boots to a TTY: `builder/build-iso.sh:121` adds only `linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring omarchy-settings lvm2 cryptsetup parted` on top of archiso's `releng` profile. No compositor, no mesa, no display manager.

So a try desktop does not need to be *shipped*. It needs to be *installed* — into the archiso copy-on-write overlay, from the mirror that is already on the stick, at the moment someone asks for it.

### Measured

Resolved against the shipped squashfs listing and the live pacman sync DB (2026-09-05):

| | packages | read from stick | lands in RAM |
|---|---|---|---|
| Try set (`omarchy` + mesa/vulkan-radeon/vulkan-intel + networkmanager + noto-fonts + foot, minus what the live root already has) | 167 | 0.39 GiB | 1.17 GiB |

Every one of the 167 is already in the mirror. The only desktop-adjacent packages *not* in the mirror are `vulkan-nouveau` and `vulkan-swrast`, which `install/hardware/vulkan.sh` does not install either, so they are not part of the product and not part of the try set. Net ISO growth: the scripts in this plan.

`pacman -U` of a *larger* set (385 packages, 1.14 GiB of archives, hooks masked, into tmpfs) on a Ryzen 9800X3D: **8.7 s** with signature verification, **6.6 s** without. Peak RSS 70 MiB; libalpm is single-threaded, so a 2–3× slower laptop CPU lands at 13–26 s. The `[offline]` repo is `SigLevel = Never` (`configs/pacman-offline.conf:23`), so the lower number applies. The USB read (0.39 GiB) overlaps with the greeter wait (below).

### Why this shape and not the obvious ones

- **Prebake a desktop into the live squashfs.** `build-iso.sh:194` folds the finalized `packages.x86_64` into the offline-mirror download set, so anything added to `arch_packages` ships *twice*: once installed, once as an archive. +0.39 GiB becomes ~+0.6 GiB of ISO, at 20,000 downloads/day. Rejected on size.
- **A second `desktop.sfs` mounted on demand.** Mainline overlayfs cannot add a lower layer to a mounted root (`ovl_reconfigure` only flips ro/rw; Slax ships a patched aufs kernel for exactly this). It would need a boot-menu entry to select before the initramfs builds the overlay, and it still grows the ISO. Rejected.
- **Make the live root the full desktop and install by copying it.** Net size ≈ 0 because the copied packages leave the mirror, but it replaces `arch_install_system` (`orchestrator/phases_impl.py:216-318`) — the most safety-critical path in the product — and invalidates `manifests/`. Not a change an outside PR should carry alongside a feature.
- **Install at try-time from the mirror.** Zero ISO growth, zero installer change, reuses the mirror the install already validates. This is what Alpine's diskless ISO does on every boot (`apk add --root $sysroot --repository <on-medium repo>` into tmpfs). Chosen.

## Current State

Relevant facts about the tree this lands in:

- `configs/airootfs/root/.automated_script.sh:13` guards on tty1, starts `warm_offline_mirror` (page-cache prefetch, largest-first, half of `MemAvailable`) at `:89`, runs `./configurator` at `:102`, then hands off to the dashboard + orchestrator. The try branch belongs between the prefetch and the configurator.
- `configs/airootfs/root/configurator:102-176` `greeter()` is a single "Press Return to Start Install" modal with no state committed. Deferred provisioning (Ctrl+C on the keyboard screen, `:206`) and the encryption toggle (`:949`) are the existing precedents for "another mode, no boot entry".
- The live `/etc/pacman.conf` **is** `pacman-offline.conf` (`build-iso.sh:347`), so `pacman -S` in the live root already resolves against `[offline]` at `file:///var/cache/omarchy/mirror/offline/`. Nothing to configure.
- `orchestrator/phases_impl.py:678` `_mask_mkinitcpio_pacman_hooks` masks boot-image hooks by symlinking their names to `/dev/null` under `/etc/pacman.d/hooks`; the list is `DEFERRED_BOOT_HOOKS` (`:590`). Same technique, same list, for the try install.
- `configure_login` (`phases_impl.py:1403`) writes `etc/sddm.conf.d/autologin.conf` as `[Autologin]\nUser=…\nSession=omarchy.desktop`. The try session writes the identical file.
- `omarchy-settings` is already in the live root (`build-iso.sh:118-121`), so `/etc/skel` carries the full Omarchy dotfile payload. A new user gets the product's config for free.
- The live root runs **iwd + systemd-networkd** (releng). Omarchy's shell drives NetworkManager (`shell/plugins/panels/network/Model.js`). `networkmanager` and `wpa_supplicant` are both on the stick.
- archiso mounts the overlay upper on a tmpfs sized by `cow_spacesize`, default **256M** (`mkinitcpio-archiso` hook `:231`). The try set needs ~1.2 GiB there.
- `linux-firmware` (full, including NVIDIA GSP firmware) is in the live root, so in-kernel `nouveau` has what it needs on Turing and later.
- `bin/omarchy-iso-make:73-104` refuses to build if an executable under `configs/airootfs/usr/local/bin` or `/root` lacks a `file_permissions` entry in `profiledef.sh`.
- `bin/omarchy-iso-test:364` `session_started()` (`ls /run/user/1000/hypr`) is already the harness's "Hyprland is up" predicate.

## Approach

One new script, one new greeter choice, one branch in `.automated_script.sh`, one harness flag. The install path is not modified; Try is a blocking call *in front of* it that returns to the same place.

```
tty1 ─ .automated_script.sh
        │  prefetch: try-set first, then the rest of the mirror
        ▼
      greeter ──── "Install Omarchy" (Return, default) ──────────────┐
        │                                                            │
        └─ "Try Omarchy first" ─▶ omarchy-try                        │
                                    │ guard RAM, resize cowspace     │
                                    │ pacman -S <try set> [offline]  │
                                    │ iwd → NetworkManager           │
                                    │ useradd try (skel) + theme     │
                                    │ systemd-run uwsm → Hyprland    │
                                    │ … session …                    │
                                    │ "Install" stops the unit       │
                                    ▼                                │
                                  return ────────────────────────────┤
                                                                     ▼
                                                             ./configurator (unchanged)
```

### Time-to-desktop budget (Try chosen)

| step | cost |
|---|---|
| ISO boot to greeter | unchanged |
| read 0.39 GiB of archives | overlapped with the greeter wait by prefetching the try set first; otherwise 1–4 s on USB 3, ~13 s on USB 2 |
| `pacman -S` 167 packages into tmpfs | 4–6 s here, 10–20 s on a laptop |
| kept hooks (fontconfig, gdk-pixbuf, glib schemas, mime, desktop-database, sysusers/tmpfiles, ldconfig) | ~5–10 s |
| NetworkManager start, useradd, theme set | ~2 s |
| systemd-run session → uwsm → Hyprland on VT7 | ~2–5 s |
| **Try → desktop** | **~15 s here, ~25–40 s on a laptop** |

The two things that would blow it are `mkinitcpio` and `limine` hooks, which are masked, and `copytoram`, which is never set.

### RAM

1.17 GiB in the cowspace tmpfs plus the running session (~0.8 GiB with a browser closed). Gate on `MemTotal ≥ 4 GiB`; below that, explain and return to the greeter. Prefetch is page cache and is reclaimed under pressure.

### GPU

`mesa` + `vulkan-radeon` + `vulkan-intel` from the mirror; `nouveau` is in-kernel with GSP firmware already present. Hybrid NVIDIA laptops drive the panel from the iGPU and just work. A desktop with a discrete NVIDIA card as its only output gets nouveau — a working but unaccelerated session, which is enough to check wifi, input, display and the look. Proprietary NVIDIA is out: the userspace alone is 300 MiB of archive / 886 MiB installed, and both branches in the mirror are DKMS (`nvidia-open-dkms`, `nvidia-580xx-dkms`) — a multi-minute compile into RAM. The installer does it properly on disk afterwards (`install/hardware/nvidia.sh`), which is the right place.

### Apps on demand

The live `pacman.conf` already points at `[offline]`, so inside the session `omarchy-install-app`, `omarchy-webapp-install` and `pacman -S` resolve against the stick with no network. Chromium is a 133 MiB archive on the stick: a few seconds. This is the reason the try set is deliberately small — everything else Omarchy ships is one command away, offline. Packages *not* in the mirror need the real repos and a network; the try session does not add them (out of scope, see below).

## Concrete changes

### 1. `configs/airootfs/usr/local/bin/omarchy-try` (new, ~150 lines bash)

Runs as root on tty1, called from `.automated_script.sh`. Returns 0 when the user chose Install from the session, non-zero (with a one-line reason already shown) on any failure. Never touches a block device.

1. **Guard.** `MemTotal ≥ 4 GiB` or bail with a message. Kill the mirror prefetch (`warm_pid` is exported by the caller; see §3).
2. **Grow the overlay.** `mount -o remount,size=50% /run/archiso/cowspace`. tmpfs resizes live; the mount point is the one archiso created.
3. **Mask boot hooks.** Symlink each name in `DEFERRED_BOOT_HOOKS` (`60-mkinitcpio-remove.hook`, `60-limine-mkinitcpio-remove-pre.hook`, `80-limine-efi-deploy.hook`, `90-limine-mkinitcpio-remove-post.hook`, `90-mkinitcpio-install.hook`) to `/dev/null` under `/etc/pacman.d/hooks`. Mirrors `_mask_mkinitcpio_pacman_hooks`; the live root is discarded at reboot so no unmask is needed.
4. **Install.** `pacman -Sy --needed --noconfirm --assume-installed limine --assume-installed limine-mkinitcpio-hook --assume-installed limine-snapper-sync --assume-installed snapper omarchy mesa vulkan-radeon vulkan-intel networkmanager noto-fonts noto-fonts-emoji foot`. `--assume-installed` keeps the four bootloader/snapshot packages (17 MiB, and the source of the dangerous hooks) out of a root that has no ESP and no btrfs. `-Sy` rather than `-S` because mkarchiso empties `/var/lib/pacman/sync` in the live root; the sync reads `offline.db` off the medium and touches no network. Progress goes to the TTY under the Tokyo Night palette the script already sets.
5. **Network.** `systemctl stop iwd systemd-networkd`; `systemctl start NetworkManager`. `systemd-resolved` stays (NM uses it). This is the installed product's stack.
6. **User.** `useradd -m -G wheel,video,input,audio -s /bin/bash try`; empty password; `/etc/sudoers.d/try` NOPASSWD. `/etc/skel` seeds the dotfiles. Then as `try`: `OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "Tokyo Night"` and `xdg-user-dirs-update`. Not `omarchy-provision-user`: `install/user/mise.sh` and `chromium.sh` reach for the network and have no guards, and none of what they do matters for a look-and-feel session.
7. **Session.** Start the desktop as a transient unit: `systemd-run --unit=omarchy-try-session --uid=try -p PAMName=login -p TTYPath=/dev/tty7 … uwsm start … Hyprland`. Not SDDM: SDDM claims VT1, where the configurator that called us lives, so starting it kills the greeter and stopping it leaves VT1 blank (verified on the stock 4.0.2 ISO). A logind session on VT7 leaves the configurator running on VT1 the whole time. `chvt 7` once the compositor socket appears; then wait until the unit goes inactive.
8. **Return.** When the session unit goes inactive (the in-session Install action stops it), `chvt 1` to bring the greeter forward, restore the installer's network (`systemctl start systemd-networkd.socket systemd-networkd.service iwd.service`, stop NetworkManager), and return 0. Optionally `pacman -Rns` the try set to give the RAM back; the installer is disk-bound so this is not required and is left out of the first cut.

### 2. In-session affordances (shipped inside the same script, written at try-time)

- `/etc/xdg/autostart`-style hook or a `hyprctl notify` on session start: "Try session — running from the USB stick, nothing has been written to your disk. Press Super+Shift+I to install." Kept to one notification.
- `/usr/local/bin/omarchy-try-install`: `sudo systemctl stop omarchy-try-session.service`. Bound via the `try` user's `~/.config/hypr/bindings.lua`, so the shipped `default/hypr` is untouched.
- Nothing else. No wallpaper packs, no welcome app.

### 3. `configs/airootfs/root/.automated_script.sh`

- Export `warm_pid` so §1 can stop the prefetch.
- Reorder `warm_offline_mirror` to read the try set's archives first (list from §5), then continue largest-first as today.

That is the whole change here. The greeter owns the Try loop (§4), so the call sequence `./configurator` → dashboard → orchestrator is untouched, and the autoinstall branch (`:97-102`) never sees a greeter.

### 4. `configs/airootfs/root/configurator`

`greeter()` (`:102-176`): replace the single Return hint with a two-item `gum choose` — `Install Omarchy` (default) / `Try Omarchy first`. Return selects the default, so the muscle memory of every existing user and the OCR waits in the harness are preserved. On "try", `greeter()` calls `/usr/local/bin/omarchy-try` and, when it returns, redraws itself; the function only returns to the configurator's main flow once "Install Omarchy" is chosen. Esc keeps its meaning. The `ttfx colorshift` animation and `wait_for_stable_terminal` are unchanged.

While here: the tagline changed to "Beautiful, Fun & Agentic" in `2673c61` but `bin/omarchy-iso-test:617,734,809` and `test/integration.d/factory-reset-test.sh:168,178` still `wait_for_screen "Opinionated"`. Fix in the same series (own commit) or the `--try` scenario cannot pass either.

### 5. `builder/build-iso.sh`

One addition next to `expected-packages` (`:292-344`): resolve the try set against the same offline DB and write the resulting **archive filenames** to `airootfs/usr/share/omarchy-iso/try-packages`. The build already resolves the mirror this way; this makes the try set a build-time fact (so a package leaving the mirror fails the build, not the user) and gives §3 its prefetch list. No change to `arch_packages`, `packages.x86_64`, or the mirror.

### 6. `configs/profiledef.sh`

`["/usr/local/bin/omarchy-try"]="0:0:755"` and `["/usr/local/bin/omarchy-try-install"]="0:0:755"` in `file_permissions`, or `omarchy-iso-make` refuses to build.

### 7. `bin/omarchy-iso-test`

`--try`: boot the ISO, `wait_for_screen` for the greeter, `press down; press ret`, wait for the desktop, then `press` the install binding and continue into the **existing** install assertions. The try path is exercised in front of the install test rather than beside it, so it cannot regress silently.

Desktop assertion: the harness talks to guests over SSH after a typed console bootstrap (`:874-926`); in the try session use the same bootstrap on tty3 and reuse `session_started()`, or have `omarchy-try` echo `OMARCHY_TRY_SESSION_UP` to `/dev/ttyS0` when `/run/user/$(id -u try)/hypr` appears and grep the serial log. The serial marker is simpler and needs no key material in a live root.

The harness runs `-device virtio-vga` without GL (`:220`), so Hyprland renders on llvmpipe. Expect it to start; expect it to be slow. `WLR_RENDERER_ALLOW_SOFTWARE=1` may be needed in the try user's environment — a spike item.

### Not changed

`configs/grub/*`, `configs/syslinux/*`, `configs/efiboot/*` (no boot entry, no timeout), `orchestrator/*` (no installer change), `arch_packages`, the mirror, `manifests/`.

## Testing

- `test/all` gains a unit test for the try-set resolution in §5 (same shape as `test_offline_mirror_pruning.py`).
- `bin/omarchy-iso-test --try` (§7) in QEMU.
- Real hardware, before the PR: an Intel iGPU laptop, an AMD laptop, a hybrid NVIDIA laptop, and a desktop with a discrete NVIDIA card as its only output. Record time-to-desktop from the Try keypress and `MemAvailable` after the session is up. Land those numbers in the PR body.

## Spike results (stock omarchy-4.0.2 ISO, QEMU, virtio-vga/llvmpipe, 8 GiB)

Run against the shipped ISO with the exact sequence this design uses:

1. **Overlay resize** — `mount -o remount,size=50% /run/archiso/cowspace` took the upper from 256M to 3.9G live. Works.
2. **Install** — `pacman -Sy --needed --assume-installed {limine,limine-mkinitcpio-hook,limine-snapper-sync,snapper} omarchy mesa vulkan-radeon vulkan-intel networkmanager noto-fonts noto-fonts-emoji foot` resolved 146 packages, 1126 MiB installed, in **3.5 s** on this host. All 17 post-transaction hooks ran (ldconfig, sysusers, tmpfiles, fontconfig, gio, gsettings, gtk3 im, icon caches, desktop/mime) and **no `limine`/`mkinitcpio` hook fired** — the five `/dev/null` masks held. Overlay used 1.6 GiB after.
3. **Network** — stopping iwd/networkd and starting NetworkManager left `nmcli device` reporting the wired link `connected`.
4. **User + theme** — `useradd` + `omarchy-theme-set "Tokyo Night"` (headless) succeeded; `/home/try/.local/state/omarchy/current/` was populated and the Quickshell bar rendered the theme. Two harmless warnings under `runuser`: the theme-set flock lives at `${XDG_RUNTIME_DIR}/…` which is root's under `runuser` (the lock is best-effort; theme still applied), and `xdg-user-dirs-update` needs a real user session (skipped, `|| true`). omarchy-try runs both with `env HOME=…` and tolerates their failure.
5. **Session / VT handoff — the design-changing result.** SDDM autologin brought the desktop up in ~1 s, **but SDDM claims VT1**: starting it deallocated the getty there and killed the configurator that had launched the try session, and stopping SDDM left VT1 blank — the greeter never came back. Relaunching needed `systemctl start getty@tty1`, which re-runs the whole `.automated_script.sh` (prefetch included), not the waiting configurator. Switching to a transient logind session — `systemd-run --unit=omarchy-try-session --uid=try -p PAMName=login -p TTYPath=/dev/tty7 … uwsm start … Hyprland` — brought Hyprland + Quickshell up in ~2 s on **VT7** and left the configurator alive on VT1 the entire time (`ps -t tty1` still showed it). This is why the design starts the session as a unit rather than through SDDM. `uwsm` found the `omarchy.desktop` session and started Hyprland with no extra environment beyond `XDG_SESSION_TYPE`/`XDG_SESSION_CLASS`.
6. **Apps on demand** — `pacman -Sy chromium` from inside the live root pulled from `[offline]` in **0.66 s** (already in page cache). Confirms in-session installs are offline and instant.
7. **llvmpipe** — Hyprland and Quickshell rendered under plain `virtio-vga` (software GL) without extra environment; no `WLR_RENDERER_ALLOW_SOFTWARE` needed on this QEMU. Real hardware with a GPU will be faster.

## Out of scope

Persistence, a persistent home, portable installs, rescue tooling (declined in omacom/omarchy#1355), proprietary NVIDIA in the session, online repos in the session, a Try boot-menu entry, changes to the deferred-provisioning or cidata paths.

## Framing for the PR

"Try Omarchy" — a taste of Omarchy on the hardware you are about to install it on, the way the Mac app is a taste of it on a Mac. No rebuild, no extra boot entry, no extra bytes: the ISO already carries every package; Try installs 167 of them into RAM when asked, and ends in Install. One change per PR: the greeter choice, the script, the harness flag, the tagline OCR fix.
