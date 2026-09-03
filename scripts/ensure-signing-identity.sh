#!/bin/bash
# Ensures a stable local code-signing identity exists in the login keychain.
#
# Ad-hoc signing (`codesign -s -`) ties TCC's Accessibility grant to the raw
# binary hash, which changes on every rebuild -> permission resets every time.
# A self-signed "Code Signing" certificate gives codesign a stable identity
# (anchored to the cert, not the hash), so TCC grants survive rebuilds as
# long as we keep signing with this same identity.
#
# Scope of what this trusts: the cert is CA:false with EKU = Code Signing only,
# and trust is added for the "Code Signing" policy in the *user* domain only
# (no sudo, no System keychain, no TLS/root trust). Gatekeeper treatment of
# downloaded apps is unaffected. Valid for 10 years; when it expires, rerun
# this script (delete the old identity first) and re-approve Accessibility once.
#
# This script is idempotent: if the identity already exists, it does nothing.
set -euo pipefail

CERT_NAME="CodexUsageOverlay Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "signing identity already present: $CERT_NAME"
  exit 0
fi

echo "no local signing identity found — creating one (one-time setup)..."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/codesign.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
  -days 3650 -nodes -config "$TMPDIR/codesign.cnf" >/dev/null 2>&1

openssl pkcs12 -export -out "$TMPDIR/cert.p12" \
  -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout pass:temp -legacy 2>/dev/null || \
openssl pkcs12 -export -out "$TMPDIR/cert.p12" \
  -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout pass:temp

security import "$TMPDIR/cert.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign -T /usr/bin/security

echo "trusting the certificate for code signing (this keychain only) — macOS may ask you to confirm..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMPDIR/cert.pem"

echo "created and trusted signing identity: $CERT_NAME"
