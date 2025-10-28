# Omarchy ISO

The Omarchy ISO streamlines [the installation of Omarchy](https://learn.omacom.io/2/the-omarchy-manual/50/getting-started). It includes the Omarchy Configurator as a front-end to archinstall and automatically launches the [Omarchy Installer](https://github.com/basecamp/omarchy) after base arch has been setup.

## Setup

Add the bin folder to your PATH to use the Omarchy ISO tools:

```bash
# Temporary (current session only)
export PATH="$PATH:$(pwd)/bin"

# Permanent (add to your ~/.bashrc or ~/.zshrc)
echo 'export PATH="$PATH:'$(pwd)'/bin"' >> ~/.bashrc
source ~/.bashrc
```

After adding to PATH, you can run commands directly: `omarchy-iso-make` instead of `./bin/omarchy-iso-make`

## Downloading the latest ISO

See the ISO link on [omarchy.org](https://omarchy.org).

## Creating the ISO

Run `omarchy-iso-make` and the output goes into `./release`.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `OMARCHY_INSTALLER_REPO` - GitHub repository for the installer (default: `basecamp/omarchy`)
- `OMARCHY_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `master`)

**Example usage:**

```bash
OMARCHY_INSTALLER_REPO="myuser/omarchy-fork" OMARCHY_INSTALLER_REF="some-feature" omarchy-iso-make
```

## Testing the ISO

Run `omarchy-iso-boot [release/omarchy.iso]`.

## Signing the ISO

Run `omarchy-iso-sign [gpg-user] [release/omarchy.iso]`.

## Uploading the ISO

Run `omarchy-iso-upload [release/omarchy.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `omarchy-iso-release` to create, test, sign, and upload the ISO in one flow.
