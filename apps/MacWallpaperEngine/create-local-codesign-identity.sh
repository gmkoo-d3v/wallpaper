#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${CODESIGN_IDENTITY_NAME:-Mac Wallpaper Engine Local Development}"
KEYCHAIN="${CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
VALID_DAYS="${CODESIGN_IDENTITY_DAYS:-3650}"

if ! command -v security >/dev/null 2>&1; then
  echo "security tool is unavailable; this script must run on macOS." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to create a local development code-signing identity." >&2
  exit 1
fi

if security find-identity -v -p codesigning | grep -F "\"$IDENTITY_NAME\"" >/dev/null; then
  echo "Local code-signing identity already exists: $IDENTITY_NAME"
  echo "Package with: CODESIGN_IDENTITY=auto apps/MacWallpaperEngine/package-app.sh"
  exit 0
fi

CONFIRMED="${CONFIRM_LOCAL_CODESIGN_IDENTITY:-0}"
if [ "${1:-}" = "--yes" ]; then
  CONFIRMED=1
fi

if [ "$CONFIRMED" != "1" ]; then
  cat >&2 <<EOF
This will create a private key and trusted local code-signing root certificate
in the login keychain:

  identity: $IDENTITY_NAME
  keychain: $KEYCHAIN

Use this only on a development Mac you control. Rerun with --yes after you
accept that persistent keychain change:

  apps/MacWallpaperEngine/create-local-codesign-identity.sh --yes
EOF
  exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
p12_password="$(openssl rand -base64 32)"

cat > "$tmpdir/openssl.cnf" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = codesign_cert

[ dn ]
CN = $IDENTITY_NAME

[ codesign_cert ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

openssl req \
  -newkey rsa:2048 \
  -nodes \
  -keyout "$tmpdir/identity.key" \
  -x509 \
  -days "$VALID_DAYS" \
  -out "$tmpdir/identity.crt" \
  -config "$tmpdir/openssl.cnf" \
  -extensions codesign_cert >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -legacy \
  -inkey "$tmpdir/identity.key" \
  -in "$tmpdir/identity.crt" \
  -out "$tmpdir/identity.p12" \
  -name "$IDENTITY_NAME" \
  -passout "pass:$p12_password" >/dev/null 2>&1

if ! security import "$tmpdir/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$p12_password" \
    -T /usr/bin/codesign >/dev/null; then
  cat >&2 <<EOF
Could not import the local code-signing identity into the login keychain.

This helper exports the identity as a legacy PKCS#12 file for compatibility
with macOS security(1). If this still fails, create an existing signing
identity manually and package with:

  CODESIGN_IDENTITY="Your Signing Identity" apps/MacWallpaperEngine/package-app.sh
EOF
  exit 1
fi

if ! security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$tmpdir/identity.crt" >/dev/null; then
  cat >&2 <<EOF
The identity was generated, but macOS did not grant certificate trust.

If you canceled the authorization dialog, rerun this helper and approve the
trust change. Without a trusted stable signing identity, package-app.sh will
fall back to ad-hoc signing and macOS may ask you to re-add Accessibility
permission after rebuilds.
EOF
  exit 1
fi

echo "Created local code-signing identity: $IDENTITY_NAME"
echo "Keychain: $KEYCHAIN"
echo "Package with: CODESIGN_IDENTITY=auto apps/MacWallpaperEngine/package-app.sh"
