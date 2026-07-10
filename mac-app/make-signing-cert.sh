#!/bin/zsh
# Create a local self-signed code-signing identity named "AIClock Self Signed"
# and import it into the login keychain, so package-app.sh can sign with a STABLE
# identity. That keeps the app's designated requirement constant across rebuilds,
# which means macOS Keychain "Always Allow" grants (e.g. reading the Claude Code
# credential for quota) survive re-signing instead of being revoked every build.
#
# Run once per machine. Signing does NOT require the cert to be trusted (the
# "NOT_TRUSTED" note only affects Gatekeeper verification of downloaded apps).
set -e
IDENTITY="AIClock Self Signed"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "identity '$IDENTITY' already exists — nothing to do"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg.cnf"
# Legacy PKCS12 algorithms so macOS's `security` can import it (OpenSSL 3 defaults
# to newer algorithms the Security framework rejects).
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:aiclock -name "$IDENTITY" \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
       -passout pass:aiclock -name "$IDENTITY"
# -A lets codesign use the private key without a per-signing password prompt.
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P aiclock -A -T /usr/bin/codesign

echo "created code-signing identity '$IDENTITY'."
echo "next: run ./package-app.sh, then on first launch click \"Always Allow\" on the"
echo "Keychain prompt — it will now persist across future rebuilds."
