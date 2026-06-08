# Developer Guide

## Requirements

- macOS 14+
- Swift 6 (Xcode 16 or Command Line Tools)

## Running from source

```bash
swift run
```

## Running tests

```bash
swift test
```

## Building a local .app + DMG

```bash
./scripts/build-app.sh 1.0.0
```

This produces `Questrade-Menu-v1.0.0.dmg` in the repo root. Open it and drag **Questrade Menu** to Applications.

The script:
1. Compiles a release binary for arm64
2. Generates `AppIcon.icns` from `icon.png`
3. Assembles a proper `.app` bundle with `Info.plist`
4. Ad-hoc signs the bundle
5. Packages it into a DMG

## CI / Releases

Releases are built via GitHub Actions (`Actions → Build`). Enter a version number to trigger a build. A signed DMG is attached to the GitHub Release automatically.

The workflow runs tests, builds the app, signs and notarizes it (if Apple secrets are configured), and creates a GitHub Release with the DMG attached.

### Optional signing secrets

Set these in repo **Settings → Secrets and variables → Actions** to produce a Developer ID–signed and notarized build that passes Gatekeeper without a warning:

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application .p12 (`openssl base64 -in cert.p12 \| pbcopy`) |
| `APPLE_CERTIFICATE_PASSWORD` | Password set when exporting the .p12 |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email (for notarization) |
| `APPLE_PASSWORD` | App-specific password from appleid.apple.com |
| `APPLE_TEAM_ID` | 10-character Team ID from developer.apple.com |

Without these the DMG still builds and runs, but Gatekeeper will show a warning on other machines (right-click → Open to bypass it).

## Project structure

```
Sources/questrade-mac-menu/   # All app code (single file)
Tests/questrade-mac-menuTests/  # Unit tests (swift-testing)
scripts/build-app.sh          # Local .app + DMG build script
entitlements.plist            # Hardened Runtime entitlements
.github/workflows/
  ci.yml                      # Runs tests on push/PR
  build.yml                   # Builds and releases a versioned DMG
```
