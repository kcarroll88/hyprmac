#!/bin/bash
# Creates a self-signed code-signing identity so the Accessibility grant survives
# a rebuild.
#
# macOS keys the Accessibility grant to a code signature. Ad-hoc signing produces
# a fresh identity every build, so the grant is revoked each time and the app
# looks broken while System Settings still shows its checkbox on — the row is
# keyed to the bundle id, the authorisation underneath to a code hash that no
# longer exists.
#
# A stable certificate fixes it permanently. An Apple Development certificate from
# Xcode does the same job; this is the route that needs no Apple ID. Run once:
#
#   ./scripts/make-signing-cert.sh
#
# Then rebuild. bundle.sh picks the identity up on its own.
set -euo pipefail

NAME="${1:-Wisp OS Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "==> '$NAME' already exists; nothing to do"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating a 10-year self-signed code-signing certificate"
# extendedKeyUsage=codeSigning is the part that matters: without it the identity
# is created but codesign will not accept it.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME/O=Wisp OS" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 defaults to AES-256 with an SHA-256 MAC, which macOS's Security
# framework cannot read — `security import` fails with "MAC verification failed
# (wrong password?)", which sounds like a typo and is not one. The legacy
# SHA1/3DES algorithms are what it expects.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -name "$NAME" -passout pass:wispos

echo "==> importing into the login keychain"
# -T grants codesign access to the private key without a prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P wispos -T /usr/bin/codesign

echo "==> trusting it for code signing"
echo "    macOS will ask for your login password — that is this step, not the build."
# User trust domain, so no sudo. -p codeSign limits the trust to signing code:
# this certificate can never vouch for a TLS connection or an email.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> done. '$NAME' is ready."
    echo "    Rebuild with ./scripts/bundle.sh, then grant Accessibility once more."
    echo "    That grant now survives every future rebuild."
else
    echo "!! the identity did not register — check the output above" >&2
    exit 1
fi
