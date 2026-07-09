# Release Process

This document describes how to create a new release of Battery Monitor.

## Prerequisites

- Push access to the GitHub repository
- All changes committed and pushed to `main`
- Version number decided with semantic versioning
- Apple Developer ID, notarization, and GitHub Actions secrets configured

## Creating a Release

### Automatic Release

The GitHub Actions workflow automatically builds and releases when you push a
version tag:

```bash
git checkout main
git pull
git tag -s v1.1.0 -m "Release version v1.1.0"
git push origin v1.1.0
```

The workflow will automatically:

1. Build `BatteryMonitor` and `BatteryMonitorPrivilegedHelper`.
2. Create `BatteryMonitor.app` with the helper executable and LaunchDaemon plist.
3. Sign the helper, main executable, and app bundle.
4. Create `BatteryMonitor.dmg`.
5. Notarize, staple, and validate the DMG.
6. Create `BatteryMonitor.dmg.sha256`.
7. Create or update the GitHub release for the tag.
8. Upload the DMG assets, replacing existing assets when rebuilding a release.

### What Gets Released

The GitHub release includes:

1. **BatteryMonitor.dmg**
   - Signed and notarized installer package
   - Contains `BatteryMonitor.app`
   - Contains the bundled privileged helper and LaunchDaemon plist
   - Includes an Applications symlink for drag-and-drop installation

2. **BatteryMonitor.dmg.sha256**
   - Checksum for download verification

### Manual Trigger

You can also trigger the workflow manually from GitHub:

1. Go to the Actions tab
2. Select the "Build and Release" workflow
3. Click "Run workflow"
4. Choose the branch
5. Enter the release tag to create or update, for example `v1.1.0`

Manual runs build from the selected branch and create or update the release
identified by the tag input. Existing DMG assets are replaced with `gh release
upload --clobber`.

## Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: breaking changes or a major UI overhaul
- **MINOR**: new backwards-compatible features
- **PATCH**: bug fixes and minor improvements

## Local Testing Before Release

Run local verification:

```bash
just test
just lint
VERSION=dev just build-dmg
swift build -c release --product BatteryMonitor
swift build -c release --product BatteryMonitorPrivilegedHelper
```

Verify the local app bundle produced by `just build-dmg`:

```bash
plutil -p .build/artifacts/BatteryMonitor.app/Contents/Info.plist
test -x .build/artifacts/BatteryMonitor.app/Contents/MacOS/BatteryMonitorPrivilegedHelper
test -f .build/artifacts/BatteryMonitor.app/Contents/Library/LaunchDaemons/com.swacktools.batterymonitor.helper.plist
```

## Troubleshooting

### Build Fails In GitHub Actions

1. Check the Actions logs.
2. Ensure both Swift products compile locally.
3. Verify `Package.swift` and `project.yml` match the source layout.
4. Check that the selected Xcode path exists on the runner.

### Release Exists But Assets Are Missing

Use the manual workflow trigger with the same tag. The workflow edits the
existing release and uploads `BatteryMonitor.dmg` and `BatteryMonitor.dmg.sha256`
with clobber semantics.

### Notarization Fails

1. Verify the Developer ID certificate secrets are valid.
2. Verify `APPLE_ID`, `APPLE_APP_PASSWORD`, and `APPLE_TEAM_ID`.
3. Check the `notarytool submit` output for Apple validation messages.
4. Confirm the helper and app bundle are signed before creating the DMG.

### DMG Verification Fails

Users can verify the download:

```bash
shasum -a 256 -c BatteryMonitor.dmg.sha256
```

Expected output:

```text
BatteryMonitor.dmg: OK
```

## Release Checklist

Before creating a release:

- [ ] All tests pass locally
- [ ] README.md is accurate for current features
- [ ] Version number chosen following semver
- [ ] All commits pushed to `main`
- [ ] Local DMG build tested

After creating release:

- [ ] Verify GitHub release exists
- [ ] Verify `BatteryMonitor.dmg` and `BatteryMonitor.dmg.sha256` are uploaded
- [ ] Download and mount the DMG
- [ ] Install the app into `/Applications`
- [ ] Launch the menu bar app
- [ ] Register or approve the privileged helper if testing thermal telemetry
- [ ] Verify Gatekeeper accepts the app

## Workflow Details

The `.github/workflows/release.yml` workflow:

- **Trigger**: tags matching `v*`, or manual dispatch with a `tag` input
- **Runner**: `macos-26`
- **Artifacts**: signed and notarized DMG plus checksum
- **Swift version**: selected Xcode on the macOS runner

### Workflow Steps

1. Checkout code
2. Select Xcode
3. Import the Developer ID certificate
4. Build release binaries
5. Extract version from tag or manual input
6. Create the app bundle
7. Sign helper, executable, and app bundle
8. Create DMG installer
9. Notarize, staple, and validate DMG
10. Generate checksum
11. Write release notes
12. Create or update GitHub release

## Notes

- The menu bar app remains a user-session GUI process.
- The root LaunchDaemon helper is bundled in the app and registered with
  ServiceManagement.
- The helper writes telemetry to `/Library/Application Support/BatteryMonitor`.
- Build number is set from the GitHub Actions run number.
- Release notes are generated by the workflow template.
