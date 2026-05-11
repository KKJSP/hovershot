#!/usr/bin/env bash
# One-time creation of a self-signed code-signing certificate so that the rebuilt
# app keeps the same Designated Requirement across builds. macOS's TCC database
# (Accessibility / Screen Recording / etc.) keys persisted permissions on this
# Designated Requirement — with ad-hoc signing it includes the binary's cdhash
# and changes every build, forcing re-prompts. Signing with a stable identity
# fixes that.
#
# Idempotent: running it again is a no-op.
set -euo pipefail

CERT_CN="hovershot-cert"
LEGACY_CERT_CNS=("hovershot-certificate" "HoverShot Local Code Signing" "HoverShot_Dev_ID")
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

cleanup_legacy() {
    for legacy in "${LEGACY_CERT_CNS[@]}"; do
        while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            echo "==> Removing legacy identity '$legacy' (SHA1: $sha)"
            security delete-identity -Z "$sha" "$KEYCHAIN" >/dev/null 2>&1 || true
        done < <(
            security find-identity -p codesigning "$KEYCHAIN" \
                | awk -v name="\"$legacy\"" '$0 ~ name { print $2 }'
        )
    done
}

cleanup_legacy

# Repair stale state: an identity may already exist whose certificate is
# labelled "$CERT_CN" but whose paired private key has a different (often
# generic "cert") label baked in from an earlier import. macOS's "codesign
# wants to access key …" dialog shows the *key's* label, not the cert's, so a
# mismatched key produces a confusing popup. If the identity is there but no
# private key with label "$CERT_CN" exists, delete the identity so the rest
# of this script reimports it cleanly with the correct labels.
if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$CERT_CN\""; then
    if ! security find-key -l "$CERT_CN" "$KEYCHAIN" 2>/dev/null | grep -q "class:"; then
        echo "==> Existing '$CERT_CN' identity has a mislabeled private key — recreating."
        while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            security delete-identity -Z "$sha" "$KEYCHAIN" >/dev/null 2>&1 || true
        done < <(
            security find-identity -p codesigning "$KEYCHAIN" \
                | awk -v name="\"$CERT_CN\"" '$0 ~ name { print $2 }'
        )
    fi
fi

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$CERT_CN"; then
    if codesign --dryrun -s "$CERT_CN" /usr/bin/true 2>/dev/null; then
        echo "Code-signing identity '$CERT_CN' is already set up — nothing to do."
        exit 0
    fi
    echo "Identity exists but is not yet trusted for code signing — fixing trust only."
    SKIP_KEYGEN=1
fi

echo
echo "This script will create a self-signed code-signing certificate named"
echo "'$CERT_CN' in your login keychain so that rebuilds of HoverShot keep"
echo "the same Designated Requirement, allowing macOS to remember the"
echo "permissions you grant. The certificate stays on your machine and is"
echo "never used to sign anything other than this app."
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "${SKIP_KEYGEN:-}" ]; then
    echo "==> Creating self-signed code-signing certificate '$CERT_CN'"

    cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign
[dn]
CN = $CERT_CN
[v3_codesign]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 \
        -config "$TMP/openssl.cnf" \
        >/dev/null 2>&1

    # Force the legacy PKCS12 encoding that macOS's Security framework can
    # read. OpenSSL 3 defaults to AES-256-CBC + PBKDF2 + HMAC-SHA-256, which
    # `security import` rejects with the misleading "MAC verification failed
    # (wrong password?)" error. Spelling out PBE-SHA1-3DES + SHA1 MAC keeps
    # the export compatible with both OpenSSL 3 and the LibreSSL build that
    # macOS ships at /usr/bin/openssl, with no `-legacy` flag needed.
    # Name the PKCS#12 after the certificate so anything that falls back to the
    # filename (older `security import` versions, third-party keychain tools)
    # still shows "$CERT_CN" rather than a generic "cert".
    openssl pkcs12 -export \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/$CERT_CN.p12" \
        -name "$CERT_CN" \
        -macalg sha1 \
        -keypbe PBE-SHA1-3DES \
        -certpbe PBE-SHA1-3DES \
        -password pass:hovershot

    echo "==> Importing into login keychain"
    security import "$TMP/$CERT_CN.p12" \
        -k "$KEYCHAIN" \
        -T /usr/bin/codesign \
        -T /usr/bin/security \
        -P hovershot
else
    security find-certificate -c "$CERT_CN" -p "$KEYCHAIN" > "$TMP/cert.pem"
fi

echo "==> Marking certificate as trusted for code signing (user-level)"
echo "    macOS may prompt you for your login password to update trust settings."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || {
    echo
    echo "Trust update failed. The build will fall back to ad-hoc signing,"
    echo "which means macOS will re-prompt for permissions on every rebuild."
    exit 1
}

echo
echo "Done. Future builds will sign with '$CERT_CN' silently."
