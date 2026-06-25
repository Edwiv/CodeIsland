# GitHub Release Distribution

CodeIsland uses Sparkle for in-app updates and GitHub Releases for hosting the
signed DMG. The release workflow builds a universal macOS app, signs it with a
Developer ID Application certificate, notarizes and staples the DMG, updates the
Sparkle appcast, commits release metadata, and creates a GitHub Release.

## One-time setup

Add these repository secrets in GitHub:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the `.p12` export |
| `MACOS_KEYCHAIN_PASSWORD` | Any strong temporary keychain password for CI |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `APPLE_ID` |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key matching `SUPublicEDKey` |

Export a `.p12` certificate from Keychain Access, then encode it:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Export the Sparkle private key from a Mac that already owns it:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
pbcopy < sparkle_private_key.txt
rm sparkle_private_key.txt
```

The `SPARKLE_ED_PRIVATE_KEY` secret must match the public key embedded in
`Info.plist` as `SUPublicEDKey`. If that private key is unavailable, generate a
new Sparkle key, update `SUPublicEDKey`, and ship one manual migration build.
Existing installations cannot accept Sparkle updates signed by a different key
until they have installed a build containing the new public key.

## Release flow

1. Bump `CHANGELOG.md` for the version if you want curated release notes.
2. Open **Actions -> Publish GitHub Release**.
3. Run the workflow with a version such as `1.0.29`.
4. The workflow writes the version into `Info.plist`, builds `.build/CodeIsland.dmg`,
   signs and notarizes it, updates `appcast.xml`, pushes `release: v<version>`,
   and creates `https://github.com/Edwiv/CodeIsland/releases/tag/v<version>`.

This workflow publishes stable updates only. If you need beta releases, add a
separate Sparkle feed instead of marking a GitHub Release as a prerelease in the
same appcast.

The app's `SUFeedURL` points at:

```text
https://raw.githubusercontent.com/Edwiv/CodeIsland/main/appcast.xml
```

That URL must be publicly reachable by installed apps. If the repository is
private, host `appcast.xml` and `CodeIsland.dmg` on a public HTTPS endpoint and
override `CODEISLAND_APPCAST_URL` / `CODEISLAND_DOWNLOAD_URL` in the release
workflow.

Once a user has installed a build with that feed URL, future GitHub Releases are
discovered by Sparkle automatically.

## Local dry run

Without signing credentials, you can still make sure the bundle assembles:

```bash
BUILD_ARCH=arm64 SKIP_SIGN=1 SKIP_NOTARIZE=1 ./scripts/build-dmg.sh 1.0.29
```

For a local signed release dry run on a machine with the Developer ID certificate
and notarytool profile:

```bash
REQUIRE_DEVELOPER_ID=1 REQUIRE_NOTARIZATION=1 ./scripts/build-dmg.sh 1.0.29
./scripts/update-appcast.sh 1.0.29 .build/CodeIsland.dmg
```

For a no-Developer-ID personal distribution flow, see
`docs/personal-distribution.md`.
