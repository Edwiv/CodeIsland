# Personal Distribution

This path is for your own Macs only. It does not require an Apple Developer
Program membership. The update archive is signed with Sparkle EdDSA, and a
private HTTPS endpoint serves `appcast.xml` plus DMGs.

For best results, also create a self-signed personal code-signing certificate,
then trust that public certificate on each of your Macs. This is not public
notarization, but it gives your personal builds a stable code identity across
updates.

## Server Layout

Host this directory on a private HTTPS server:

```text
codeisland/
  appcast.xml
  install.sh
  install-certificate.sh
  CodeIslandPersonalCodeSigning.cer
  README.txt
  releases/
    v1.0.29/
      CodeIsland.dmg
```

The base URL becomes the app's Sparkle feed root:

```text
https://your-host.example/codeisland
```

Use HTTPS. If you use an internal CA, make sure each Mac trusts the root
certificate before relying on automatic updates.

## One-Time Sparkle Key

Create or inspect a personal Sparkle key:

```bash
./scripts/setup-personal-sparkle-key.sh
```

The script prints two values:

```bash
SPARKLE_ED_ACCOUNT=codeisland-personal
CODEISLAND_SPARKLE_PUBLIC_KEY=...
```

Keep the private key in your Keychain. The server only hosts signed outputs; it
must not hold the private key.

## One-Time Code-Signing Certificate

Create a personal code-signing identity on your publishing Mac:

```bash
./scripts/create-personal-codesign-cert.sh
```

This creates:

```text
.build/personal-codesign/CodeIslandPersonalCodeSigning.cer
.build/personal-codesign/private/CodeIslandPersonalCodeSigning.p12
```

The `.cer` file is public and can be trusted on your other Macs. The `.p12`
contains the private signing key; keep it private and use it only as a backup or
to move the publishing identity to another trusted Mac.

Trust the certificate on another Mac manually:

```bash
./scripts/install-personal-codesign-cert.sh CodeIslandPersonalCodeSigning.cer
```

If the certificate is published with your personal distribution site, each Mac
can install it from the server:

```bash
curl -fsSL https://your-host.example/codeisland/install-certificate.sh | bash
```

## Publish

Personal releases must be signed with the configured personal code-signing
identity. The publish script now fails if that identity is missing; an ad-hoc
build changes the app's designated requirement and can reset macOS TCC
permissions. Use `CODEISLAND_ALLOW_ADHOC_SIGNING=1` only for throwaway testing
that will not be installed over a daily app.

Publish to a local webroot:

```bash
SPARKLE_ED_ACCOUNT=codeisland-personal \
CODEISLAND_SPARKLE_PUBLIC_KEY=... \
CODEISLAND_PERSONAL_SIGN_IDENTITY="CodeIsland Personal Code Signing" \
./scripts/publish-personal.sh \
  1.0.29 \
  https://your-host.example/codeisland \
  /Library/WebServer/Documents/codeisland
```

Publish to a remote host over SSH:

```bash
SPARKLE_ED_ACCOUNT=codeisland-personal \
CODEISLAND_SPARKLE_PUBLIC_KEY=... \
CODEISLAND_PERSONAL_SIGN_IDENTITY="CodeIsland Personal Code Signing" \
./scripts/publish-personal.sh \
  1.0.29 \
  https://your-host.example/codeisland \
  user@your-host:/srv/codeisland
```

Without a destination, the script builds a complete site at
`.build/personal-site` for inspection.

## First Install

On each Mac, install once:

```bash
curl -fsSL https://your-host.example/codeisland/install.sh | bash
```

The installer downloads the latest DMG from the appcast, copies
`CodeIsland.app` to `/Applications`, trusts the personal signing certificate if
the site publishes one, removes quarantine, and launches it. After that, Sparkle
checks the private feed and applies future updates.

## Artifact Release Checklist

One-time on the publishing Mac:

```bash
./scripts/setup-personal-sparkle-key.sh
./scripts/create-personal-codesign-cert.sh
```

Copy the printed `SPARKLE_ED_ACCOUNT` and `CODEISLAND_SPARKLE_PUBLIC_KEY`.

For every release:

```bash
SPARKLE_ED_ACCOUNT=codeisland-personal \
CODEISLAND_SPARKLE_PUBLIC_KEY=... \
CODEISLAND_PERSONAL_SIGN_IDENTITY="CodeIsland Personal Code Signing" \
CODEISLAND_REQUIRE_PERSONAL_SIGNING=1 \
./scripts/publish-personal.sh \
  1.0.29 \
  https://your-host.example/codeisland \
  user@your-host:/srv/codeisland
```

On each Mac once:

```bash
curl -fsSL https://your-host.example/codeisland/install.sh | bash
```

## Limits

- This is personal controlled distribution, not public notarized distribution.
- Gatekeeper may still warn if the app is installed manually outside the script
  or before the personal certificate is trusted.
- Keep the app path stable at `/Applications/CodeIsland.app`.
- Bump the version for every release; Sparkle ignores non-increasing versions.
