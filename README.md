# Omarchy ISO

The Omarchy ISO streamlines [the installation of Omarchy](https://learn.omacom.io/2/the-omarchy-manual/50/getting-started). It includes the Omarchy Configurator as a front-end to archinstall and automatically launches the [Omarchy Installer](https://github.com/basecamp/omarchy) after base arch has been setup.

## Downloading the latest ISO

See the ISO link on [omarchy.org](https://omarchy.org).

## Creating the ISO

Run `./bin/omarchy-iso-make` and the output goes into `./release`. You can build from your local $OMARCHY_PATH for testing by using `--local-source` or from a checkout of the dev branch (instead of master) by using `--dev`.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `OMARCHY_INSTALLER_REPO` - GitHub repository for the installer (default: `basecamp/omarchy`)
- `OMARCHY_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `master`)

Example usage:
```bash
OMARCHY_INSTALLER_REPO="myuser/omarchy-fork" OMARCHY_INSTALLER_REF="some-feature" ./bin/omarchy-iso-make
```

## Autoinstall

Autoinstall skips the interactive configurator by reading config files from a cloud-init drive (`cidata`). This works with the standard Omarchy ISO — no rebuild needed.

### How it works

1. Create config files (same format the interactive configurator generates)
2. Put them on a small drive labeled `cidata`
3. Attach both the Omarchy ISO and the cidata drive to your VM
4. Set boot order to disk first, ISO as fallback
5. Boot — the installer finds the config, installs automatically, and reboots into the installed system

### Config files

| File | Required | Purpose |
|------|----------|---------|
| `user_configuration.json` | Yes | archinstall config (disk, hostname, timezone, keyboard, etc.) |
| `user_credentials.json` | Yes | Username and password hash |
| `user_full_name.txt` | Yes | Git full name |
| `user_email_address.txt` | Yes | Git email |
| `ssh.json` | No | JSON array of SSH public keys — triggers SSH and networking setup |

### Creating a cidata drive

```bash
# Put your config files in a directory
mkdir -p cidata
cp user_configuration.json user_credentials.json ssh.json cidata/

# Create the ISO
genisoimage -output cidata.iso -volid cidata -joliet -rock cidata/
```

### Generating a password hash

```bash
openssl passwd -6 "yourpassword"
```

Use the output as the `enc_password` value in `user_credentials.json`.

### SSH keys

Create `ssh.json` with a JSON array of public keys:

```json
["ssh-ed25519 AAAA... user@host"]
```

When `ssh.json` is present, the installer enables `sshd`, configures DHCP networking, and populates `~/.ssh/authorized_keys`.

### Proxmox example

```bash
# Create VM with disk-first boot order
qm create 101 --name my-omarchy \
  --bios ovmf --machine q35 --cpu host --cores 4 --memory 8192 \
  --ostype l26 --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 local-lvm:40,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 --vga virtio --serial0 socket \
  --ide2 local:iso/omarchy.iso,media=cdrom \
  --ide3 local:iso/cidata.iso,media=cdrom \
  --boot order='scsi0;ide2'

qm start 101
```

Empty disk falls through to the ISO on first boot. After install, the system boots from disk.

## Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

## Signing the ISO

Run `./bin/omarchy-iso-sign [gpg-user] [release/omarchy.iso]`.

## Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `./bin/omarchy-iso-release` to create, test, sign, and upload the ISO in one flow.
