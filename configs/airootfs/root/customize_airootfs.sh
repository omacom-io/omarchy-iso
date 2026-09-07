#!/usr/bin/env bash
#
# Post-pacstrap live-ISO customization (archiso customize_airootfs.sh).
#
# The omarchy runtime hard-depends on limine-mkinitcpio-hook, whose
# 90-mkinitcpio-install.hook lands in the chroot's /etc/pacman.d/hooks/ -- the
# exact directory archiso points pacman's HookDir at. That hook therefore
# replaces the standard mkinitcpio preset run with a Limine/UKI install into an
# EFI system partition. The ISO boots grub/syslinux and has no ESP, so the hook
# aborts during pacstrap and leaves /boot without the initramfs (nor the copied
# vmlinuz) that mkarchiso expects (install: cannot stat '/boot/initramfs-*.img').
#
# Fix: drop the Limine hook and wrapper, place each kernel's vmlinuz where its
# preset names (ALL_kver=/boot/vmlinuz-<pkgbase>), and rebuild the initramfs
# through the real /usr/bin/mkinitcpio -- the Limine wrapper at
# /usr/local/bin/mkinitcpio shadows it and aborts looking for an ESP.
#
# Every installed kernel is built, so the live medium ships both stock linux
# (the installer-greeter default and the Try/install kernel) and linux-t2 (the
# kernel of last resort for T2/Mac keyboards and trackpads). Each kernel package
# installs /usr/lib/modules/<kver>/vmlinuz, records its pkgbase in
# /usr/lib/modules/<kver>/pkgbase, and ships the matching
# /etc/mkinitcpio.d/<pkgbase>.preset. We write the archiso presets ourselves so
# a kernel package's default preset cannot diverge from the archiso initramfs
# the boot loaders reference, then build one per kernel.
#
# Limine is the installer's bootloader on an installed system, not the ISO's.
set -euo pipefail

# 1. Remove the Limine kernel hook + wrapper so they can neither block mkinitcpio
#    nor persist into the live image. Tolerate a version that ships no such file.
rm -f \
  /etc/pacman.d/hooks/90-mkinitcpio-install.hook \
  /usr/local/bin/mkinitcpio \
  /usr/share/libalpm/hooks/60-limine-mkinitcpio-remove-pre.hook \
  /usr/share/libalpm/hooks/80-limine-efi-deploy.hook \
  /usr/share/libalpm/hooks/90-limine-mkinitcpio-remove-post.hook \
  /usr/share/libalpm/hooks/10-limine-snapper-lock.hook

# 2. Write the canonical archiso presets for every kernel we boot, so the build
#    is deterministic regardless of what a kernel package shipped. Both stock
#    linux and linux-t2 use the plain archiso.conf, i.e. a generic initramfs —
#    deliberately nothing graphics is baked into it. The grub entries blacklist
#    nouveau on the UEFI-only boots (the live desktop then renders on the
#    firmware framebuffer instead of dead-looping on an NVIDIA panel it cannot
#    modeset), and the proprietary driver is installed on demand inside a
#    Try/install session only when an NVIDIA panel is actually detected.
mkdir -p /etc/mkinitcpio.d

cat > /etc/mkinitcpio.d/linux.preset <<'EOF'
# mkinitcpio preset for the stock 'linux' kernel on the Omarchy live medium.
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image="/boot/initramfs-linux.img"
EOF

cat > /etc/mkinitcpio.d/linux-t2.preset <<'EOF'
# mkinitcpio preset for the 'linux-t2' kernel on the Omarchy live medium.
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux-t2'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image="/boot/initramfs-linux-t2.img"
EOF

# 3. Stage each kernel's vmlinuz where its preset names, then build the live
#    initramfs (/boot/initramfs-<pkgbase>.img) through the real mkinitcpio.
built=0
for kver in /usr/lib/modules/*/; do
  kver="${kver%/}"
  [[ -f "$kver/pkgbase" && -f "$kver/vmlinuz" ]] || continue
  pkgbase="$(cat "$kver/pkgbase")"
  [[ -n $pkgbase && -f "/etc/mkinitcpio.d/$pkgbase.preset" ]] || continue
  install -D -m 0644 "$kver/vmlinuz" "/boot/vmlinuz-$pkgbase"
  /usr/bin/mkinitcpio --preset "$pkgbase"
  built=1
done

if ((built == 0)); then
  echo "customize_airootfs.sh: no kernel found under /usr/lib/modules" >&2
  exit 1
fi
