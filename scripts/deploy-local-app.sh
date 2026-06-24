#!/bin/bash
set -euo pipefail

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
APP_NAME="CodeIsland"
APP_BUNDLE="$REPO_ROOT/.build/release/$APP_NAME.app"
STAGED_APP="/tmp/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"

cd "$REPO_ROOT"

./build.sh

rm -rf "$STAGED_APP"
ditto --norsrc --noextattr "$APP_BUNDLE" "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
SIGN_DETAILS=$(codesign -dvvv "$STAGED_APP" 2>&1)
if ! grep -q '^Authority=' <<<"$SIGN_DETAILS"; then
    echo "ERROR: $STAGED_APP is ad-hoc signed. Install a codesigning identity or set SIGN_ID." >&2
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
