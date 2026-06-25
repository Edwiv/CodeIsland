#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/publish-personal.sh <version> <base-url> [publish-destination]

Examples:
  ./scripts/publish-personal.sh 1.0.29 https://macmini.local/codeisland /Library/WebServer/Documents/codeisland
  ./scripts/publish-personal.sh 1.0.29 https://codeisland.tailnet.example/codeisland user@host:/srv/codeisland

Environment:
  BUILD_ARCH=arm64|universal              Defaults to arm64 for personal distribution.
  SPARKLE_ED_ACCOUNT=codeisland-personal  Keychain account for Sparkle signing.
  CODEISLAND_SPARKLE_PUBLIC_KEY=...       Public key embedded in the app build.
  CODEISLAND_PERSONAL_SIGN_IDENTITY=...   Defaults to "CodeIsland Personal Code Signing".
  CODEISLAND_REQUIRE_PERSONAL_SIGNING=0   Disable the default signing requirement only with CODEISLAND_ALLOW_ADHOC_SIGNING=1.
  CODEISLAND_ALLOW_ADHOC_SIGNING=1        Explicitly allow ad-hoc output for throwaway testing only.
  CODEISLAND_CODESIGN_CERT_PATH=...       Public .cer copied to the published site.
  SPARKLE_ED_PRIVATE_KEY=...              Optional private key instead of Keychain.
  SPARKLE_ED_PRIVATE_KEY_FILE=...         Optional private key file instead of Keychain.
  CODEISLAND_PUBLISH_DEST=...             Destination if not passed as an argument.
EOF
}

VERSION="${1:-}"
BASE_URL="${2:-${CODEISLAND_BASE_URL:-}}"
PUBLISH_DEST="${3:-${CODEISLAND_PUBLISH_DEST:-}}"

if [[ -z "$VERSION" || -z "$BASE_URL" ]]; then
    usage >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BASE_URL="${BASE_URL%/}"
APPCAST_URL="$BASE_URL/appcast.xml"
DOWNLOAD_URL="$BASE_URL/releases/v${VERSION}/CodeIsland.dmg"
RELEASE_URL="$BASE_URL/releases/v${VERSION}/"
SITE_DIR="$REPO_ROOT/.build/personal-site"
SITE_RELEASE_DIR="$SITE_DIR/releases/v${VERSION}"
SITE_APPCAST="$SITE_DIR/appcast.xml"
DMG_PATH="$REPO_ROOT/.build/CodeIsland.dmg"
ARCH="${BUILD_ARCH:-arm64}"
ACCOUNT="${SPARKLE_ED_ACCOUNT:-codeisland-personal}"
SIGN_IDENTITY_TO_USE="${CODEISLAND_PERSONAL_SIGN_IDENTITY:-CodeIsland Personal Code Signing}"
REQUIRE_PERSONAL_SIGNING="${CODEISLAND_REQUIRE_PERSONAL_SIGNING:-1}"
ALLOW_ADHOC_SIGNING="${CODEISLAND_ALLOW_ADHOC_SIGNING:-0}"
DEFAULT_CERT_PATH="$REPO_ROOT/.build/personal-codesign/CodeIslandPersonalCodeSigning.cer"
CERT_PATH="${CODEISLAND_CODESIGN_CERT_PATH:-}"
if [[ -z "$CERT_PATH" && -f "$DEFAULT_CERT_PATH" ]]; then
    CERT_PATH="$DEFAULT_CERT_PATH"
fi

cd "$REPO_ROOT"

if [[ -z "${CODEISLAND_SPARKLE_PUBLIC_KEY:-}" ]]; then
    cat >&2 <<EOF
ERROR: CODEISLAND_SPARKLE_PUBLIC_KEY is required for personal distribution.

Run:
  ./scripts/setup-personal-sparkle-key.sh

Then re-run this command with the CODEISLAND_SPARKLE_PUBLIC_KEY value it prints.
EOF
    exit 1
fi

rm -rf "$SITE_DIR"
mkdir -p "$SITE_RELEASE_DIR"

if [[ -n "$PUBLISH_DEST" && "$PUBLISH_DEST" != *:* && -f "$PUBLISH_DEST/appcast.xml" ]]; then
    cp "$PUBLISH_DEST/appcast.xml" "$SITE_APPCAST"
fi

BUILD_SIGN_ENV=(SKIP_SIGN=1)
if security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY_TO_USE\""; then
    echo "==> Using personal signing identity: $SIGN_IDENTITY_TO_USE"
    BUILD_SIGN_ENV=(SIGN_IDENTITY="$SIGN_IDENTITY_TO_USE")
elif [[ "$REQUIRE_PERSONAL_SIGNING" = "1" || "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    cat >&2 <<EOF
ERROR: Personal signing identity not found: $SIGN_IDENTITY_TO_USE

Run:
  ./scripts/create-personal-codesign-cert.sh

For a throwaway ad-hoc build only:
  CODEISLAND_ALLOW_ADHOC_SIGNING=1 CODEISLAND_REQUIRE_PERSONAL_SIGNING=0 $0 $VERSION $BASE_URL
EOF
    exit 1
else
    echo "==> Personal signing identity not found; falling back to ad-hoc signing"
fi

echo "==> Building personal DMG"
env \
    CODEISLAND_APPCAST_URL="$APPCAST_URL" \
    CODEISLAND_SPARKLE_PUBLIC_KEY="$CODEISLAND_SPARKLE_PUBLIC_KEY" \
    BUILD_ARCH="$ARCH" \
    SKIP_NOTARIZE=1 \
    "${BUILD_SIGN_ENV[@]}" \
    "$SCRIPT_DIR/build-dmg.sh" "$VERSION"

cp "$DMG_PATH" "$SITE_RELEASE_DIR/CodeIsland.dmg"

echo "==> Generating personal appcast"
CODEISLAND_APPCAST_PATH="$SITE_APPCAST" \
CODEISLAND_APPCAST_URL="$APPCAST_URL" \
CODEISLAND_DOWNLOAD_URL="$DOWNLOAD_URL" \
CODEISLAND_RELEASE_URL="$RELEASE_URL" \
SPARKLE_ED_ACCOUNT="$ACCOUNT" \
"$SCRIPT_DIR/update-appcast.sh" "$VERSION" "$SITE_RELEASE_DIR/CodeIsland.dmg"

CERT_URL=""
if [[ -n "$CERT_PATH" ]]; then
    if [[ ! -f "$CERT_PATH" ]]; then
        echo "ERROR: CODEISLAND_CODESIGN_CERT_PATH does not exist: $CERT_PATH" >&2
        exit 1
    fi
    cp "$CERT_PATH" "$SITE_DIR/CodeIslandPersonalCodeSigning.cer"
    CERT_URL="$BASE_URL/CodeIslandPersonalCodeSigning.cer"
    sed "s#__CODEISLAND_CERT_URL__#$CERT_URL#g" "$SCRIPT_DIR/install-personal-codesign-cert.sh" > "$SITE_DIR/install-certificate.sh"
    chmod +x "$SITE_DIR/install-certificate.sh"
fi

sed \
    -e "s#__CODEISLAND_BASE_URL__#$BASE_URL#g" \
    -e "s#__CODEISLAND_CERT_URL__#$CERT_URL#g" \
    "$SCRIPT_DIR/install-personal.sh" > "$SITE_DIR/install.sh"
chmod +x "$SITE_DIR/install.sh"

cat > "$SITE_DIR/README.txt" <<EOF
CodeIsland personal distribution

Install:
  curl -fsSL $BASE_URL/install.sh | bash

Feed:
  $APPCAST_URL

Latest DMG:
  $DOWNLOAD_URL
EOF

if [[ -n "$CERT_URL" ]]; then
    cat >> "$SITE_DIR/README.txt" <<EOF

Trust the personal signing certificate only:
  curl -fsSL $BASE_URL/install-certificate.sh | bash
EOF
fi

if [[ -n "$PUBLISH_DEST" ]]; then
    echo "==> Publishing to $PUBLISH_DEST"
    if [[ "$PUBLISH_DEST" == *:* ]]; then
        rsync -av --delete "$SITE_DIR/" "$PUBLISH_DEST/"
    else
        mkdir -p "$PUBLISH_DEST"
        rsync -av --delete "$SITE_DIR/" "$PUBLISH_DEST/"
    fi
else
    echo "==> No publish destination provided; staged site only."
fi

cat <<EOF

Personal release ready:
  Site: $SITE_DIR
  Feed: $APPCAST_URL
  DMG:  $DOWNLOAD_URL

First install command:
  curl -fsSL $BASE_URL/install.sh | bash
EOF
