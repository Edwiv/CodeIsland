#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ACCOUNT="${SPARKLE_ED_ACCOUNT:-codeisland-personal}"
GENERATE_KEYS="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

cd "$REPO_ROOT"

if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "==> Resolving Sparkle tools"
    swift build -c release >/dev/null
fi

if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "ERROR: Sparkle generate_keys tool not found at $GENERATE_KEYS" >&2
    exit 1
fi

echo "==> Sparkle EdDSA account: $ACCOUNT"
echo "    You may see a Keychain prompt. Allow access so Sparkle can create or read the key."

OUTPUT="$("$GENERATE_KEYS" --account "$ACCOUNT" -p 2>/dev/null || "$GENERATE_KEYS" --account "$ACCOUNT")"
printf '%s\n' "$OUTPUT"

PUBLIC_KEY="$(printf '%s\n' "$OUTPUT" | /usr/bin/perl -ne 'print $1 if /<string>([^<]+)<\/string>/; print $1 if /^([A-Za-z0-9+\/=]{40,})$/')"
if [[ -z "$PUBLIC_KEY" ]]; then
    echo "ERROR: Could not parse SUPublicEDKey from generate_keys output." >&2
    exit 1
fi

cat <<EOF

Use these values when publishing personal builds:

  SPARKLE_ED_ACCOUNT=$ACCOUNT
  CODEISLAND_SPARKLE_PUBLIC_KEY=$PUBLIC_KEY

Example:

  SPARKLE_ED_ACCOUNT=$ACCOUNT \\
  CODEISLAND_SPARKLE_PUBLIC_KEY=$PUBLIC_KEY \\
  ./scripts/publish-personal.sh 1.0.29 https://codeisland.local/codeisland /path/to/webroot/codeisland
EOF
