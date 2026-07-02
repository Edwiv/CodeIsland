#!/bin/bash
set -euo pipefail

select_full_xcode_if_available() {
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        return
    fi

    local xcode_app
    xcode_app=$(find /Applications -maxdepth 1 -name 'Xcode_26*.app' -type d 2>/dev/null | sort | tail -n 1)
    if [ -n "$xcode_app" ]; then
        export DEVELOPER_DIR="$xcode_app/Contents/Developer"
    fi
}

select_full_xcode_if_available

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
APP_NAME="CodeIsland"
APP_BUNDLE="$REPO_ROOT/.build/release/$APP_NAME.app"
STAGED_APP="/tmp/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
EXPECTED_SIGN_ID="${CODEISLAND_EXPECTED_SIGN_ID:-${SIGN_ID:-${SIGN_IDENTITY:-${CODEISLAND_PERSONAL_SIGN_IDENTITY:-Edwiv Personal App Distribution}}}}"

cd "$REPO_ROOT"

./build.sh

version_key='Print :CFBundleShortVersionString'
candidate_version=$(/usr/libexec/PlistBuddy -c "$version_key" "$APP_BUNDLE/Contents/Info.plist")
if [ -d "$INSTALL_APP" ] && [ "${CODEISLAND_ALLOW_VERSION_DOWNGRADE:-}" != "1" ]; then
    installed_version=$(/usr/libexec/PlistBuddy -c "$version_key" "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || true)
    if [ -n "$installed_version" ]; then
        newest_version=$(printf '%s\n%s\n' "$candidate_version" "$installed_version" | sort -V | tail -n 1)
        if [ "$newest_version" = "$installed_version" ] && [ "$candidate_version" != "$installed_version" ]; then
            echo "ERROR: refusing to deploy older CodeIsland $candidate_version over installed $installed_version." >&2
            echo "       Bump Info.plist or set CODEISLAND_ALLOW_VERSION_DOWNGRADE=1 intentionally." >&2
            exit 1
        fi
    fi
fi

rm -rf "$STAGED_APP"
ditto --norsrc --noextattr "$APP_BUNDLE" "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
SIGN_DETAILS=$(codesign -dvvv "$STAGED_APP" 2>&1)
if ! grep -q '^Authority=' <<<"$SIGN_DETAILS"; then
    echo "ERROR: $STAGED_APP is ad-hoc signed. Install a codesigning identity or set SIGN_ID." >&2
    exit 1
fi
if [ -n "$EXPECTED_SIGN_ID" ] && [ "$EXPECTED_SIGN_ID" != "-" ] \
    && ! grep -Fq "Authority=$EXPECTED_SIGN_ID" <<<"$SIGN_DETAILS"; then
    echo "ERROR: $STAGED_APP was not signed with the expected stable identity: $EXPECTED_SIGN_ID" >&2
    echo "$SIGN_DETAILS" | sed -n '/^Authority=/p;/^TeamIdentifier=/p' >&2
    exit 1
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    osascript -e 'tell application id "com.codeisland.app" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

BACKUP="/tmp/$APP_NAME.app.backup.$(date +%Y%m%d%H%M%S)"
if [ -d "$INSTALL_APP" ]; then
    ditto --norsrc --noextattr "$INSTALL_APP" "$BACKUP"
    echo "Backed up existing app: $BACKUP"
fi

rm -rf "$INSTALL_APP"
ditto --norsrc --noextattr "$STAGED_APP" "$INSTALL_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"

open "$INSTALL_APP"
sleep 2
pgrep -x "$APP_NAME" >/dev/null
echo "$APP_NAME deployed and running from $INSTALL_APP"
