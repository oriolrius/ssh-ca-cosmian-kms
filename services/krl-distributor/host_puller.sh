#!/usr/bin/env bash
#
# host_puller.sh — host-side pull client for the KRL Distribution Service.
#
# Implements the host side of docs/krl-distribution.md:
#   1. POST /krl with {"host_id": <this host>} and If-None-Match: <local KRL hash>
#   2. On 304 -> nothing changed, exit cleanly (no file write, no sshd restart).
#   3. On 200 -> ECIES-decrypt the body with the host private key (via the KMS,
#      using the host's own key id), verify the CA signature over the KRL bytes,
#      check the valid_until freshness window, then atomically install the new
#      KRL to /etc/ssh/revoked_keys with mode 444.
#
# sshd re-reads RevokedKeys on every authentication attempt, so no restart is
# needed once the file is replaced.
#
# This script holds no secrets: decryption is delegated to Cosmian KMS using the
# host's *own* private-key id; the CA *public* key verifies the signature.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration (override via environment / EnvironmentFile in the unit).
# --------------------------------------------------------------------------- #
KRL_API_URL="${KRL_API_URL:-https://krl.internal:8088/krl}"
HOST_ID="${HOST_ID:-$(hostname -f)}"
REVOKED_KEYS="${REVOKED_KEYS:-/etc/ssh/revoked_keys}"

# Cosmian CLI + KMS object identifiers.
COSMIAN_BIN="${COSMIAN_BIN:-cosmian}"
# KMS key id of THIS host's private key (the matching ECIES decrypt key).
HOST_PRIV_KEY_ID="${HOST_PRIV_KEY_ID:-${HOST_ID}}"
# KMS key id of the CA *public* key used to verify the KRL signature.
CA_PUBLIC_KEY_ID="${CA_PUBLIC_KEY_ID:-ssh-host-ca_pk}"
CA_CURVE="${CA_CURVE:-nist-p256}"

# curl knobs.
CURL_OPTS=(--fail-with-body --silent --show-error --max-time 30)

log() { printf '%s krl-puller: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for bin in curl jq base64 install sha256sum "${COSMIAN_BIN}"; do
    command -v "${bin}" >/dev/null 2>&1 || die "required command not found: ${bin}"
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# --------------------------------------------------------------------------- #
# 1. Compute the local KRL version (sha256:<hex>) for If-None-Match.
# --------------------------------------------------------------------------- #
if [[ -f "${REVOKED_KEYS}" ]]; then
    LOCAL_HASH="sha256:$(sha256sum "${REVOKED_KEYS}" | awk '{print $1}')"
else
    LOCAL_HASH="sha256:none"
fi
log "local KRL version: ${LOCAL_HASH}"

# --------------------------------------------------------------------------- #
# 2. POST /krl. host_id goes in the BODY (never the URL). Capture status code.
# --------------------------------------------------------------------------- #
CIPHERTEXT="${WORKDIR}/krl.enc"
HTTP_CODE="$(
    curl "${CURL_OPTS[@]}" \
        -o "${CIPHERTEXT}" \
        -w '%{http_code}' \
        -X POST "${KRL_API_URL}" \
        -H 'Content-Type: application/json' \
        -H "If-None-Match: ${LOCAL_HASH}" \
        --data "$(jq -nc --arg h "${HOST_ID}" '{host_id: $h}')" \
    || true
)"

case "${HTTP_CODE}" in
    304)
        log "KRL unchanged (304); nothing to do"
        exit 0
        ;;
    200)
        log "new KRL available (200); processing"
        ;;
    404)
        die "host not registered with KRL service (404): ${HOST_ID}"
        ;;
    *)
        die "unexpected HTTP status ${HTTP_CODE} from ${KRL_API_URL}"
        ;;
esac

# --------------------------------------------------------------------------- #
# 3a. Decrypt the ECIES ciphertext with THIS host's private key (inside KMS).
#     The host private key never leaves the KMS boundary.
# --------------------------------------------------------------------------- #
PLAINTEXT="${WORKDIR}/payload.json"
"${COSMIAN_BIN}" kms ec decrypt \
    --key-id "${HOST_PRIV_KEY_ID}" \
    --output-file "${PLAINTEXT}" \
    "${CIPHERTEXT}" \
    || die "ECIES decrypt failed — wrong key or corrupt payload (not this host?)"

# --------------------------------------------------------------------------- #
# 3b. Parse the inner payload.
# --------------------------------------------------------------------------- #
KRL_B64="$(jq -r '.krl' "${PLAINTEXT}")"
SIG_B64="$(jq -r '.ca_signature' "${PLAINTEXT}")"
KRL_VERSION="$(jq -r '.krl_version' "${PLAINTEXT}")"
VALID_UNTIL="$(jq -r '.valid_until' "${PLAINTEXT}")"
PAYLOAD_HOST="$(jq -r '.host_id' "${PLAINTEXT}")"

[[ -n "${KRL_B64}" && "${KRL_B64}" != "null" ]] || die "payload missing krl"
[[ -n "${SIG_B64}" && "${SIG_B64}" != "null" ]] || die "payload missing ca_signature"

# host_id binding: detect misdirected payloads (see design doc).
if [[ "${PAYLOAD_HOST}" != "${HOST_ID}" ]]; then
    die "payload host_id mismatch: got '${PAYLOAD_HOST}', expected '${HOST_ID}'"
fi

# --------------------------------------------------------------------------- #
# 3c. Freshness — reject expired/replayed payloads.
# --------------------------------------------------------------------------- #
NOW="$(date +%s)"
if (( VALID_UNTIL <= NOW )); then
    die "payload expired (valid_until=${VALID_UNTIL}, now=${NOW})"
fi

# --------------------------------------------------------------------------- #
# 3d. Materialise KRL bytes + signature, then verify the CA signature.
# --------------------------------------------------------------------------- #
KRL_NEW="${WORKDIR}/revoked_keys.new"
SIG_BIN="${WORKDIR}/krl.sig"
printf '%s' "${KRL_B64}" | base64 -d > "${KRL_NEW}"
printf '%s' "${SIG_B64}" | base64 -d > "${SIG_BIN}"

"${COSMIAN_BIN}" kms ec sign-verify \
    --key-id "${CA_PUBLIC_KEY_ID}" \
    --curve "${CA_CURVE}" \
    "${KRL_NEW}" "${SIG_BIN}" \
    || die "CA signature verification FAILED — refusing to install KRL"

# Sanity: the advertised version must match the bytes we received.
ACTUAL_VERSION="sha256:$(sha256sum "${KRL_NEW}" | awk '{print $1}')"
if [[ "${ACTUAL_VERSION}" != "${KRL_VERSION}" ]]; then
    die "KRL version mismatch: bytes=${ACTUAL_VERSION}, advertised=${KRL_VERSION}"
fi

# --------------------------------------------------------------------------- #
# 3e. Atomic install. install(1) writes to a temp file and renames into place,
#     so sshd never sees a half-written RevokedKeys file. No restart needed.
# --------------------------------------------------------------------------- #
install -m 444 -o root -g root "${KRL_NEW}" "${REVOKED_KEYS}"
log "installed KRL ${KRL_VERSION} -> ${REVOKED_KEYS} (sshd needs no restart)"
