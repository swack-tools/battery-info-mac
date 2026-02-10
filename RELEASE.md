# Release Process

This document describes how to create a new release of Battery Monitor.

## Prerequisites

- Push access to the GitHub repository
- All changes committed and pushed to `main` branch
- Version number decided (semantic versioning: MAJOR.MINOR.PATCH)

## Creating a Release

### Automatic Release (Recommended)

The GitHub Actions workflow automatically builds and releases when you
push a version tag:

```bash
# 1. Make sure you're on main and up to date
git checkout main
git pull

# 2. Create and push a version tag
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0
```

The workflow will automatically:

1. Build the release binary (BatteryMonitor and BatteryMonitorCLI)
2. Create the .app bundle with proper Info.plist
3. Generate the DMG installer
4. Create checksums for all artifacts
5. Create a GitHub release with the tag
6. Upload all artifacts to the release

### What Gets Released

The GitHub release will include:

1. **BatteryMonitor.dmg** - The installer package
   - Contains the .app bundle
   - Ready for distribution
   - Compressed disk image format

2. **BatteryMonitor.dmg.sha256** - Checksum for verification
   - Users can verify download integrity

3. **BatteryMonitorCLI.tar.gz** - Command-line tool
   - Standalone CLI binary
   - For users who prefer terminal usage

4. **BatteryMonitorCLI.tar.gz.sha256** - CLI checksum

### Manual Trigger

You can also trigger the workflow manually from GitHub:

1. Go to Actions tab in GitHub
2. Select "Build and Release" workflow
3. Click "Run workflow"
4. Choose the branch (usually main)

This creates a development release without a version tag.

## Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR** (1.0.0 → 2.0.0): Breaking changes, major UI
  overhaul
- **MINOR** (1.0.0 → 1.1.0): New features, backwards compatible
- **PATCH** (1.0.0 → 1.0.1): Bug fixes, minor improvements

### Examples

```bash
# Bug fix release
git tag -a v1.0.1 -m "Fix battery percentage calculation"

# New feature release
git tag -a v1.1.0 -m "Add temperature alerts feature"

# Major version release
git tag -a v2.0.0 -m "Complete UI redesign"
```

## Local Testing Before Release

Test the build locally before creating a release:

```bash
# Build release version
swift build -c release --product BatteryMonitor

# Create .app bundle
mkdir -p BatteryMonitor.app/Contents/MacOS
cp .build/arm64-apple-macosx/release/BatteryMonitor \\
   BatteryMonitor.app/Contents/MacOS/BatteryMonitor

# Create DMG
mkdir -p dmg_staging
cp -R BatteryMonitor.app dmg_staging/
hdiutil create -volname "Battery Monitor" \\
  -srcfolder dmg_staging -ov -format UDZO BatteryMonitor.dmg

# Test the DMG
open BatteryMonitor.dmg
```

## Troubleshooting

### Build fails in GitHub Actions

1. Check the Actions tab for detailed logs
2. Ensure all Swift source files compile locally
3. Verify Package.swift is correct
4. Check that macOS version is compatible

### Release not created

1. Ensure tag starts with 'v' (e.g., v1.0.0, not 1.0.0)
2. Check GITHUB_TOKEN has proper permissions
3. Verify workflow file syntax (`.github/workflows/release.yml`)

### DMG verification fails

Users can verify the download:

```bash
# Download both the DMG and .sha256 file
shasum -a 256 -c BatteryMonitor.dmg.sha256
# Should output: BatteryMonitor.dmg: OK
```

## Release Checklist

Before creating a release:

- [ ] All features tested on macOS
- [ ] README.md updated with new features
- [ ] Version number chosen following semver
- [ ] CHANGELOG.md updated (if you maintain one)
- [ ] All commits pushed to main branch
- [ ] Local build tested successfully

After creating release:

- [ ] Verify GitHub release created successfully
- [ ] Download and test the DMG
- [ ] Verify checksums match
- [ ] Test installation on clean macOS system (if possible)
- [ ] Announce release (if applicable)

## Workflow Details

The `.github/workflows/release.yml` workflow:

- **Trigger**: Push of tags matching `v*` pattern
- **Runner**: `macos-latest` (GitHub-hosted)
- **Build time**: ~1-2 minutes
- **Artifacts**: DMG (~200KB), CLI (~50KB compressed)
- **Swift version**: Latest stable Xcode on runner

### Workflow Steps

1. Checkout code
2. Setup Xcode (latest stable)
3. Build release binaries
4. Extract version from tag
5. Create .app bundle with Info.plist
6. Create DMG installer
7. Generate checksums
8. Create GitHub release
9. Upload all artifacts

## Notes

- The workflow runs on macOS runners (required for Swift/Xcode)
- Binary is built for Apple Silicon (arm64-apple-macosx)
- Info.plist version is automatically set from git tag
- Build number is set from GitHub Actions run number
- Release notes are auto-generated from template

---

For more details on the build process, see the workflow file:
`.github/workflows/release.yml`
