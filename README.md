# Omarchy ISO

The Omarchy ISO is intended to provide a completely offline-capable installation of Omarchy. It therefore includes packages for everything that the Omarchy web installer requires. It also uses a custom front-end for archinstall that lives in the https://github.com/omacom-io/omarchy-configurator repository, which is cloned at ISO build time. (It's kept seperate so it's easier to work on for folks who don't need to know everything about arch ISO building.)

## Creating the ISO

Run `./bin/omarchy-iso-make` and the output goes into `./release`.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `OMARCHY_CONFIGURATOR_REPO` - GitHub repository for the configurator (default: `omacom-io/omarchy-configurator`)
- `OMARCHY_CONFIGURATOR_REF` - Git ref (branch/tag) for the configurator (default: `master`)
- `OMARCHY_INSTALLER_REPO` - GitHub repository for the installer (default: `basecamp/omarchy`)
- `OMARCHY_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `master`)

Example usage:
```bash
OMARCHY_INSTALLER_REPO="myuser/omarchy-fork" OMARCHY_INSTALLER_REF="some-feature" ./bin/omarchy-iso-make
```

## Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

## Signing the ISO

Run `./bin/omarchy-iso-sign [gpg-user] [release/omarchy.iso]`.

## Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `./bin/omarchy-iso-make` to create, test, sign, and upload the ISO in one flow.
