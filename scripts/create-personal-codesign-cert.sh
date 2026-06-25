#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
IDENTITY="${CODEISLAND_PERSONAL_SIGN_IDENTITY:-CodeIsland Personal Code Signing}"
OUT_DIR="${CODEISLAND_CODESIGN_OUT_DIR:-$REPO_ROOT/.build/personal-codesign}"
KEYCHAIN="${CODEISLAND_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
VALID_DAYS="${CODEISLAND_CODESIGN_DAYS:-3650}"

if security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
    echo "==> Signing identity already exists: $IDENTITY"
    security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" || true
    echo "==> Public certificate, if previously exported, should be in: $OUT_DIR"
    exit 0
fi

mkdir -p "$OUT_DIR/private"
chmod 700 "$OUT_DIR/private"

KEY_PEM="$OUT_DIR/private/CodeIslandPersonalCodeSigning.key.pem"
CERT_PEM="$OUT_DIR/private/CodeIslandPersonalCodeSigning.cert.pem"
P12_PATH="$OUT_DIR/private/CodeIslandPersonalCodeSigning.p12"
CERT_CER="$OUT_DIR/CodeIslandPersonalCodeSigning.cer"
OPENSSL_CONFIG="$OUT_DIR/private/openssl-codesign.cnf"

if [[ -z "${CODEISLAND_CODESIGN_PASSWORD:-}" ]]; then
    printf "Password to protect the exported signing identity (.p12): " >&2
    IFS= read -r -s CODEISLAND_CODESIGN_PASSWORD
    printf "\n" >&2
fi

if [[ -z "$CODEISLAND_CODESIGN_PASSWORD" ]]; then
    echo "ERROR: A non-empty .p12 password is required." >&2
    exit 1
fi

cat > "$OPENSSL_CONFIG" <<EOF
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = codesign_ext

[ dn ]
CN = $IDENTITY
O = CodeIsland Personal
OU = Personal Distribution

[ codesign_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req \
    -new \
    -newkey rsa:3072 \
    -nodes \
    -x509 \
    -days "$VALID_DAYS" \
    -keyout "$KEY_PEM" \
    -out "$CERT_PEM" \
    -config "$OPENSSL_CONFIG" \
    -extensions codesign_ext \
    >/dev/null 2>&1

openssl x509 -in "$CERT_PEM" -outform der -out "$CERT_CER"
openssl pkcs12 \
    -export \
    -inkey "$KEY_PEM" \
    -in "$CERT_PEM" \
    -name "$IDENTITY" \
    -out "$P12_PATH" \
    -passout "pass:$CODEISLAND_CODESIGN_PASSWORD" \
    >/dev/null 2>&1

echo "==> Importing signing identity into $KEYCHAIN"
security import "$P12_PATH" \
    -k "$KEYCHAIN" \
    -P "$CODEISLAND_CODESIGN_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "==> Trusting certificate for code signing in the login keychain"
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$CERT_CER"

echo "==> Verifying signing identity"
security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" || {
    echo "ERROR: Imported certificate is not visible as a valid code-signing identity." >&2
    exit 1
}

cat <<EOF

Personal code-signing identity is ready:
  Identity: $IDENTITY
  Public certificate for other Macs: $CERT_CER
  Private signing identity backup: $P12_PATH

Keep the private .p12 private. Copy only the .cer file to your other Macs or
publish it with the personal distribution site.

Use this when publishing:
  CODEISLAND_PERSONAL_SIGN_IDENTITY="$IDENTITY"
EOF

