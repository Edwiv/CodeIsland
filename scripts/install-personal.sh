#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="__CODEISLAND_BASE_URL__"
DEFAULT_CERT_URL="__CODEISLAND_CERT_URL__"
BASE_URL="${CODEISLAND_BASE_URL:-$DEFAULT_BASE_URL}"
CERT_URL="${CODEISLAND_CODESIGN_CERT_URL:-$DEFAULT_CERT_URL}"
APP_NAME="CodeIsland"
APP_BUNDLE="$APP_NAME.app"
INSTALL_APP="/Applications/$APP_BUNDLE"

if [[ -z "$BASE_URL" || "$BASE_URL" == "__CODEISLAND_BASE_URL__" ]]; then
    echo "Usage: CODEISLAND_BASE_URL=https://host/codeisland $0" >&2
    exit 1
fi

BASE_URL="${BASE_URL%/}"
APPCAST_URL="$BASE_URL/appcast.xml"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codeisland-install.XXXXXX")
DMG_PATH="$WORK_DIR/CodeIsland.dmg"
MOUNT_DIR="$WORK_DIR/mount"
CERT_PATH="$WORK_DIR/CodeIslandPersonalCodeSigning.cer"

cleanup() {
    if mount | grep -q "$MOUNT_DIR"; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Reading $APPCAST_URL"
DMG_URL="$(curl -fsSL "$APPCAST_URL" | /usr/bin/perl -ne '
    if (/<enclosure\b/ .. /\/>/) {
        if (/url="([^"]+)"/) {
            print $1;
            exit;
        }
    }
')"

if [[ -z "$DMG_URL" ]]; then
    echo "ERROR: Could not find a DMG enclosure in $APPCAST_URL" >&2
    exit 1
fi

echo "==> Downloading $DMG_URL"
curl -fL "$DMG_URL" -o "$DMG_PATH"

if [[ -n "$CERT_URL" && "$CERT_URL" != "__CODEISLAND_CERT_URL__" ]]; then
    echo "==> Trusting personal code-signing certificate"
    curl -fsSL "$CERT_URL" -o "$CERT_PATH"
    security add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$HOME/Library/Keychains/login.keychain-db" \
        "$CERT_PATH"
fi

mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

if [[ ! -d "$MOUNT_DIR/$APP_BUNDLE" ]]; then
    echo "ERROR: $APP_BUNDLE not found in downloaded DMG." >&2
    exit 1
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    osascript -e 'tell application id "com.codeisland.app" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

if [[ -d "$INSTALL_APP" ]]; then
    BACKUP="/tmp/$APP_BUNDLE.backup.$(date +%Y%m%d%H%M%S)"
    ditto --norsrc --noextattr "$INSTALL_APP" "$BACKUP"
    echo "==> Backed up existing app: $BACKUP"
fi

echo "==> Installing to $INSTALL_APP"
rm -rf "$INSTALL_APP"
ditto --norsrc --noextattr "$MOUNT_DIR/$APP_BUNDLE" "$INSTALL_APP"
xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
xattr -cr "$INSTALL_APP" 2>/dev/null || true
open "$INSTALL_APP"

echo "==> Done"
