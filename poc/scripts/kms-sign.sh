#!/usr/bin/env bash
# kms-sign.sh — the production signing path: the CA private keys live inside
# Cosmian KMS and are used via the PKCS#11 provider; they never exist as files.
# This implements UC1 (CA lifecycle in KMS) + the dual-CA + KMS variant of the
# host/user certificate signing shown in docs/technical-reference.md §9-§10.5.
#
# Requirements (NOT needed for the file-backed `poc.sh all` path):
#   - cosmian CLI configured for your KMS (~/.cosmian/cosmian.toml; TLS/mTLS)
#   - libcosmian_pkcs11.so installed (default /usr/local/lib/libcosmian_pkcs11.so)
#   - a running KMS (see `make kms-up`)
#
# Usage: kms-sign.sh init     # create the dual CA inside the KMS
#        kms-sign.sh load     # load the PKCS#11 provider into ssh-agent
#        kms-sign.sh host <host_pubkey> <principals>   # sign a host cert via KMS
#        kms-sign.sh user <user_pubkey> <principals>   # sign a user cert via KMS
set -euo pipefail

PROVIDER="${PKCS11_PROVIDER:-/usr/local/lib/libcosmian_pkcs11.so}"
OUT="${KMS_OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run/kms}"
USER_CA_TAG="ssh-user-ca"
HOST_CA_TAG="ssh-host-ca"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

preflight() {
  need cosmian; need ssh-keygen; need ssh-add
  [[ -f "$PROVIDER" ]] || die "PKCS#11 provider not found: $PROVIDER (install from the Cosmian release; see README)"
  cosmian kms server-version >/dev/null 2>&1 || die "KMS not reachable — check ~/.cosmian/cosmian.toml"
  mkdir -p "$OUT"
}

# Create two non-exportable ECDSA nistp256 CA keys inside the KMS (dual-CA).
init() {
  preflight
  for tag in "$USER_CA_TAG" "$HOST_CA_TAG"; do
    if [[ -z "$(cosmian kms locate --tag "$tag" 2>/dev/null)" ]]; then
      cosmian kms ec keys create --curve nist-p256 --tag "$tag" --sensitive true "$tag"
      printf '  created KMS CA key: %s\n' "$tag"
    else
      printf '  KMS CA key already exists: %s\n' "$tag"
    fi
  done
}

# Load the provider into ssh-agent and capture the CA public keys in OpenSSH
# format (for TrustedUserCAKeys and @cert-authority). With the key in the agent,
# ssh-keygen -Us signs without the private key ever leaving the KMS.
load() {
  preflight
  [[ -n "${SSH_AUTH_SOCK:-}" ]] || die "no ssh-agent — run: eval \"\$(ssh-agent -s)\""
  ssh-add -s "$PROVIDER"
  ssh-add -L | tee "$OUT/agent-keys.pub"
  printf '  CA public keys captured in %s/agent-keys.pub\n' "$OUT"
  printf '  (split into %s/ssh-user-ca.pub and %s/ssh-host-ca.pub as appropriate)\n' "$OUT" "$OUT"
}

# Sign a host certificate using the Host CA held in the agent (KMS-backed).
host() {
  preflight
  local pub="$1" principals="$2"
  ssh-keygen -Us "$OUT/ssh-host-ca.pub" -h -I "$(hostname -f 2>/dev/null || hostname)" \
    -n "$principals" -V '-5m:+52w' -z "$(date +%s)" "$pub"
  printf '  signed host cert: %s-cert.pub (CA private key stayed in the KMS)\n' "${pub%.pub}"
}

# Sign a user certificate using the User CA held in the agent (KMS-backed).
user() {
  preflight
  local pub="$1" principals="$2"
  ssh-keygen -Us "$OUT/ssh-user-ca.pub" -I 'kms-signed' -n "$principals" \
    -V '+1w' -z "$(date +%s)" "$pub"
  printf '  signed user cert: %s-cert.pub (CA private key stayed in the KMS)\n' "${pub%.pub}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init) init ;;
  load) load ;;
  host) [[ $# -eq 2 ]] || die "usage: kms-sign.sh host <pubkey> <principals>"; host "$@" ;;
  user) [[ $# -eq 2 ]] || die "usage: kms-sign.sh user <pubkey> <principals>"; user "$@" ;;
  *) die "usage: kms-sign.sh {init|load|host <pub> <principals>|user <pub> <principals>}" ;;
esac
