# Internal Mac Distribution

CodeIsland is distributed to personal Macs through the shared MacDist service:

```text
https://edwiv.byted.org/macapps
```

This is an internal-only distribution path. It uses:

- a trusted self-signed code-signing certificate: `Edwiv Personal App Distribution`
- a per-app Sparkle EdDSA key for update archive verification
- a static appcast and DMG hosted on `devbox_t4`
- Sparkle for in-app checks, downloads, installation, and relaunch

## Install On Another Mac

First confirm the Mac can reach the internal service:

```bash
curl -fsSL https://edwiv.byted.org/macapps/health.txt
```

Expected output:

```text
macdist-ok
```

Trust the code-signing certificate once per Mac user:

```bash
curl -fsSL https://edwiv.byted.org/macapps/certs/install-trust.sh | bash
```

Install CodeIsland:

```bash
curl -fsSL https://edwiv.byted.org/macapps/apps/codeisland/install.sh | bash
```

The installer reads the appcast, downloads the latest DMG, backs up any existing
`/Applications/CodeIsland.app` to `/tmp`, installs the new app, clears quarantine
attributes, and launches it.

## Verify Installation

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/CodeIsland.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' /Applications/CodeIsland.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 /Applications/CodeIsland.app
```

The feed URL should be:

```text
https://edwiv.byted.org/macapps/apps/codeisland/appcast.xml
```

## Publish A New Version

Publish from the MacDist checkout on the publishing Mac:

```bash
cd "/Users/bytedance/Library/Mobile Documents/com~apple~CloudDocs/Softwares/MacDist"
./macdist publish codeisland 1.0.31
```

Always bump the version. Sparkle ignores non-increasing versions.

## Troubleshooting

If macOS says the app is damaged, incompatible, or from an unidentified
developer, trust the certificate again and reinstall:

```bash
curl -fsSL https://edwiv.byted.org/macapps/certs/install-trust.sh | bash
curl -fsSL https://edwiv.byted.org/macapps/apps/codeisland/install.sh | bash
```

CodeIsland embeds Sparkle and is signed with hardened runtime plus
`com.apple.security.cs.disable-library-validation` so the self-signed app can
load the bundled self-signed Sparkle framework.
