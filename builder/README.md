# Omarchy ISO Builder

## Overview

The ISO build system now integrates local package building for development workflows.

## Build Scripts

### build-iso.sh
Main ISO build script that:
1. Sets up Arch Linux build environment
2. Builds omarchy-settings package locally (if omarchy-pkgs mounted)
3. Installs omarchy-settings in the ISO
4. Downloads remaining packages to offline mirror
5. Assembles the final ISO image

### build-omarchy-packages.sh
Builds omarchy-settings package locally from source:
- Runs inside Docker container
- Builds as `nobody` user (makepkg requirement)
- Outputs package to `/tmp/omarchy-pkg-build/`
- Exports `OMARCHY_SETTINGS_PKG` variable for build-iso.sh

## Package Integration

### omarchy-settings
**Installed in ISO** - Provides EVERYTHING needed:
- User skeleton files (`/etc/skel/`)
- System configurations (`/etc/`)
- Plymouth boot theme
- Essential binaries (`omarchy-debug`, `omarchy-upload-log`)
- Install scripts (`/usr/share/omarchy/install/`)
- Default configs and migrations

**Size**: ~5-10MB  
**Purpose**: Complete self-contained package for ISO - no git clone needed!

### omarchy (future)
**In offline mirror** - Full desktop environment:
- All omarchy-* binaries
- Install scripts and migrations
- Themes and assets
- Heavy dependencies (Hyprland, Waybar, etc.)

**Installed during**: Post-install phase in chroot

## Development Workflow

### Quick Build
```bash
# From omarchy-iso directory (uses default paths)
omarchy-iso-make-dev

# Or with custom paths
export OMARCHY_PKGS_PATH=/path/to/pkgs
export OMARCHY_INSTALLER_PATH=/path/to/installer
omarchy-iso-make-dev
```

This will:
1. Mount omarchy-pkgs into Docker container
2. Mount omarchy-installer (if OMARCHY_INSTALLER_PATH set)
3. Build omarchy-settings from local source
4. Install it in the ISO
5. Create bootable ISO with latest changes

See [ENV_VARS.md](../ENV_VARS.md) for all configuration options.

### Without Package Build
If `omarchy-pkgs` directory is not mounted:
- **Build will fail** with helpful error message
- The ISO build now requires omarchy-settings package
- No fallback to git clone (removed for simplicity)
- Set `OMARCHY_PKGS_PATH` to enable builds

## Directory Structure

```
omarchy-iso/
├── bin/
│   └── omarchy-iso-make         # Main entry point (updated to mount omarchy-pkgs)
├── builder/
│   ├── build-iso.sh             # Main ISO build (updated for package integration)
│   ├── build-omarchy-packages.sh # New: Local package builder
│   └── README.md                # This file
├── configs/
│   ├── profiledef.sh            # ISO profile (updated to remove manual file perms)
│   └── ...
└── release/
    └── omarchy-*.iso            # Built ISOs
```

## How It Works

1. **omarchy-iso-make** detects `../omarchy-pkgs` directory
2. Mounts it read-only into Docker container at `/omarchy-pkgs`
3. **build-iso.sh** checks for `/omarchy-pkgs` mount (REQUIRED!)
4. Sources **build-omarchy-packages.sh** to build package
5. Package is built with makepkg as `nobody` user
6. Built package added to `packages.x86_64` list
7. Copied to offline mirror
8. mkarchiso installs it during ISO assembly
9. ISO boots with omarchy-settings pre-installed
10. **Everything works from package** - no git clone, no manual copying!

## Benefits

### For Development
- ✅ No need to publish packages for testing
- ✅ Instant iteration on configs and binaries
- ✅ Test package integration in real ISO environment
- ✅ Single command builds everything

### For Production
- ✅ Same workflow works with published packages
- ✅ Fallback to manual copying if needed
- ✅ Reproducible builds
- ✅ Version-locked packages

## Troubleshooting

### Package build fails
```bash
# Check that omarchy-pkgs is mounted
docker run --rm -v "$PWD/../omarchy-pkgs:/omarchy-pkgs:ro" archlinux ls -la /omarchy-pkgs
```

### Manual file copying used instead of package
- Ensure omarchy-pkgs directory exists at `../omarchy-pkgs`
- Check Docker mount in omarchy-iso-make
- Look for "Mounting omarchy-pkgs" message during build

### Permission errors
- build-omarchy-packages.sh runs makepkg as `nobody` user
- Temporary sudo access granted for pacman operations
- Cleaned up after build

## Future Enhancements

1. Build full `omarchy` package locally
2. Remove git clone of omarchy-installer entirely
3. Use only packages for all file installation
4. Support building other omarchy-* packages
