#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CERT_URL="__CODEISLAND_CERT_URL__"
CERT_INPUT="${1:-${CODEISLAND_CODESIGN_CERT_URL:-$DEFAULT_CERT_URL}}"
KEYCHAIN="${CODEISLAND_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codeisland-cert.XXXXXX")
CERT_PATH="$WORK_DIR/CodeIslandPersonalCodeSigning.cer"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -z "$CERT_INPUT" || "$CERT_INPUT" == "__CODEISLAND_CERT_URL__" ]]; then
    echo "Usage: $0 <path-or-https-url-to-CodeIslandPersonalCodeSigning.cer>" >&2
    exit 1
fi

case "$CERT_INPUT" in
    http://*|https://*)
        echo "==> Downloading certificate from $CERT_INPUT"
        curl -fsSL "$CERT_INPUT" -o "$CERT_PATH"
        ;;
    *)
        if [[ ! -f "$CERT_INPUT" ]]; then
            echo "ERROR: Certificate not found: $CERT_INPUT" >&2
            exit 1
        fi
        cp "$CERT_INPUT" "$CERT_PATH"
        ;;
esac

echo "==> Trusting certificate for code signing in $KEYCHAIN"
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$CERT_PATH"

echo "==> Certificate fingerprints"
openssl x509 -inform der -in "$CERT_PATH" -noout -subject -fingerprint -sha256

echo "==> Done"

