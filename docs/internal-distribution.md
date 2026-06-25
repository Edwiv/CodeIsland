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

## Signing Invariant

Every local daily install and every MacDist release must preserve the same
designated requirement:

```text
identifier "com.codeisland.app" and certificate root = H"6d114892a54dd84512174a66844b83775152a0c9"
```

That requirement comes from `Edwiv Personal App Distribution`. It is a product
contract, not just a packaging detail: macOS TCC permissions such as Bluetooth,
folder access, Automation, and local network are tied to the app's designated
requirement. If a replacement app is signed with `Apple Development`, Developer
ID, or ad-hoc, macOS treats it as a different app even though the bundle id is
still `com.codeisland.app`, and users will be asked to grant permissions again.

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
codesign -dvvv --entitlements :- /Applications/CodeIsland.app
codesign -dr - /Applications/CodeIsland.app
```

The feed URL should be:

```text
https://edwiv.byted.org/macapps/apps/codeisland/appcast.xml
```

The signing output must include:

```text
Authority=Edwiv Personal App Distribution
```

The designated requirement must include:

```text
certificate root = H"6d114892a54dd84512174a66844b83775152a0c9"
```

## Local Daily Deploy

For local development builds that replace the user's running app, use:

```bash
scripts/deploy-local-app.sh
```

The script intentionally checks that the staged app is signed with the stable
internal identity before it replaces `/Applications/CodeIsland.app`. If the
identity is missing or the build falls back to another valid keychain identity,
deployment should fail rather than silently resetting TCC permissions.

Explicit overrides are allowed only when the identity change is intentional:

```bash
SIGN_ID="Edwiv Personal App Distribution" scripts/deploy-local-app.sh
CODEISLAND_EXPECTED_SIGN_ID="Some Other Identity" SIGN_ID="Some Other Identity" scripts/deploy-local-app.sh
```

## Publish A New Version

Publish from the MacDist checkout on the publishing Mac:

```bash
cd "/Users/bytedance/Library/Mobile Documents/com~apple~CloudDocs/Softwares/MacDist"
./macdist publish codeisland 1.0.31
```

Always bump the version. Sparkle ignores non-increasing versions.

## Troubleshooting

If Bluetooth, folder access, Automation, or local-network prompts reappear after
an update, compare the current app with the previous backup in `/tmp`:

```bash
codesign -dr - /Applications/CodeIsland.app
codesign -dr - /tmp/CodeIsland.app.backup.<timestamp>
codesign -dvvv /Applications/CodeIsland.app 2>&1 | sed -n '/^Authority=/p;/^TeamIdentifier=/p'
```

If the current app does not show `Authority=Edwiv Personal App Distribution`,
rebuild and redeploy with the stable identity:

```bash
SIGN_ID="Edwiv Personal App Distribution" scripts/deploy-local-app.sh
```

If macOS says the app is damaged, incompatible, or from an unidentified
developer, trust the certificate again and reinstall:

```bash
curl -fsSL https://edwiv.byted.org/macapps/certs/install-trust.sh | bash
curl -fsSL https://edwiv.byted.org/macapps/apps/codeisland/install.sh | bash
```

CodeIsland embeds Sparkle and is signed with hardened runtime plus
`com.apple.security.cs.disable-library-validation` so the self-signed app can
load the bundled self-signed Sparkle framework.
