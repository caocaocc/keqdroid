#!/usr/bin/env bash
#
# Sign a release SHA256SUMS with the update signing key (Ed25519):
#
#   bash tool/sign_sums.sh release/<ver>/SHA256SUMS path/to/key.pem
#
# Writes SHA256SUMS.sig next to it: base64 of the raw 64-byte signature over
# the file exactly as published. The app (lib/services/release_signature.dart)
# refuses an update or geo base whose SHA256SUMS does not verify against one
# of its public keys. The signature is checked here against the public key
# the app knows before the script returns, so a key that is not in the app
# fails the release instead of every user's update.
#
# The key may also come in UPDATE_SIGNING_KEY (PEM text) with "-" as the path.
set +x
set -euo pipefail
umask 077

SUMS="${1:?usage: sign_sums.sh SHA256SUMS key.pem|-}"
KEY="${2:?usage: sign_sums.sh SHA256SUMS key.pem|-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SIGNING_STAGE=resolve_openssl
finish_signing() {
  local result=$?
  if [ "$result" -ne 0 ]; then
    printf 'keqdroid-signing-stage=%s\n' "$SIGNING_STAGE" >&2
  fi
  rm -rf "$WORK"
  return "$result"
}
trap finish_signing EXIT

# The Python release collector pins its selected executable. Resolve only once
# for standalone use too: a child shell can have a different PATH on macOS.
KEQDROID_SIGNING_OPENSSL="${KEQDROID_SIGNING_OPENSSL:-$(command -v openssl)}"
case "$KEQDROID_SIGNING_OPENSSL" in
  /*) [ -x "$KEQDROID_SIGNING_OPENSSL" ] || exit 1 ;;
  *) exit 1 ;;
esac
readonly KEQDROID_SIGNING_OPENSSL

SIGNING_STAGE=read_key
if [ "$KEY" = "-" ]; then
  [ -n "${UPDATE_SIGNING_KEY:-}" ] || { echo "UPDATE_SIGNING_KEY is empty"; exit 1; }
  printf '%s\n' "$UPDATE_SIGNING_KEY" > "$WORK/key.pem"
  KEY="$WORK/key.pem"
fi

rm -f "$SUMS.sig"
SIGNING_STAGE=sign
"$KEQDROID_SIGNING_OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin -in "$SUMS" -out "$WORK/sig.bin"
SIGNING_STAGE=signature_size
[ "$(wc -c < "$WORK/sig.bin")" -eq 64 ] || { echo "not an Ed25519 signature"; exit 1; }
SIGNING_STAGE=encode_signature
base64 < "$WORK/sig.bin" | tr -d '\r\n' > "$WORK/signature"
printf '\n' >> "$WORK/signature"

SIGNING_STAGE=export_public_key
PUB="$("$KEQDROID_SIGNING_OPENSSL" pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64 | tr -d '\r\n')"
SIGNING_STAGE=match_public_key
if ! grep -qF "'$PUB'" "$REPO_DIR/lib/services/release_signature.dart"; then
  echo "the key is not one of the public keys in lib/services/release_signature.dart"
  rm -f "$SUMS.sig"
  exit 1
fi
SIGNING_STAGE=export_public_key
"$KEQDROID_SIGNING_OPENSSL" pkey -in "$KEY" -pubout -out "$WORK/pub.pem"
SIGNING_STAGE=verify_signature
"$KEQDROID_SIGNING_OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin -in "$SUMS" -sigfile "$WORK/sig.bin" >/dev/null
SIGNING_STAGE=publish_signature
cp "$WORK/signature" "$SUMS.sig"
echo "signed $(basename "$SUMS") with key $PUB"
