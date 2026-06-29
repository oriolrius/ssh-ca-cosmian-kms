#!/usr/bin/env bash
# poc.sh — drive the SSH Certificate Authority proof of concept.
#
# The host acts as the CA operator and SSH client (it uses the host's
# ssh-keygen / ssh); the ssh-server container runs sshd. Each `uc<N>` subcommand
# performs a use case AND asserts its outcome, exiting non-zero on failure so it
# can be wired into tests (see ../test/uc.bats).
#
#   ./poc.sh up        build + start ssh-server
#   ./poc.sh all       run UC1-UC9 (idempotent; sets up CA + host cert first)
#   ./poc.sh uc5       run a single use case
#   ./poc.sh down      stop + remove
#
# CA backend: file-based dual CA (User CA + Host CA), ECDSA nistp256. The
# KMS/PKCS#11 signing path is in kms-sign.sh (see docs/technical-reference.md 10.5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$POC_DIR/.." && pwd)"
RUN="$POC_DIR/run"
PORT="${SSH_PORT:-2222}"
HOSTADDR="127.0.0.1"
COMPOSE=(docker compose -f "$POC_DIR/docker-compose.yml")

# shellcheck disable=SC2034
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

ssh_base=(ssh -n -F /dev/null -p "$PORT"
  -o UserKnownHostsFile="$RUN/known_hosts"
  -o GlobalKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=yes
  -o PasswordAuthentication=no
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=8
  -i "$RUN/user/id_ed25519")

server_log() { docker logs ssh-server 2>&1; }

# ---- environment --------------------------------------------------------------
up() {
  log "Building and starting ssh-server"
  "${COMPOSE[@]}" up -d --build
  log "Waiting for sshd on $HOSTADDR:$PORT"
  for _ in $(seq 1 60); do
    if banner="$(timeout 3 bash -c "exec 3<>/dev/tcp/$HOSTADDR/$PORT && head -c 4 <&3" 2>/dev/null)" \
       && [[ "$banner" == SSH-* ]]; then
      ok "sshd is up"; return 0
    fi
    sleep 1
  done
  die "sshd did not come up"
}

down()  { "${COMPOSE[@]}" down -v --remove-orphans 2>/dev/null || true; }
clean() { down; rm -rf "$RUN"; ok "cleaned"; }

# ---- CA + host cert -----------------------------------------------------------
ca() {
  mkdir -p "$RUN/ca"
  if [[ ! -f "$RUN/ca/ssh-user-ca" ]]; then
    ssh-keygen -q -t ecdsa -b 256 -f "$RUN/ca/ssh-user-ca" -N '' -C 'User CA'
  fi
  if [[ ! -f "$RUN/ca/ssh-host-ca" ]]; then
    ssh-keygen -q -t ecdsa -b 256 -f "$RUN/ca/ssh-host-ca" -N '' -C 'Host CA'
  fi
}

host_install() {
  ca
  mkdir -p "$RUN"
  # The server's host key was created by `ssh-keygen -A`; sign its public part.
  docker exec ssh-server cat /etc/ssh/ssh_host_ed25519_key.pub > "$RUN/host_ed25519.pub"
  ssh-keygen -q -s "$RUN/ca/ssh-host-ca" -h -I 'server.lab.local' \
    -n 'server.lab.local,127.0.0.1,localhost,ssh-server,10.222.9.20' \
    -V '-5m:+52w' -z 1001 "$RUN/host_ed25519.pub"

  docker cp "$RUN/host_ed25519-cert.pub" ssh-server:/etc/ssh/ssh_host_ed25519_key-cert.pub
  docker cp "$RUN/ca/ssh-user-ca.pub"    ssh-server:/etc/ssh/ssh-user-ca.pub

  # sshd drop-in.
  cat > "$RUN/10-ssh-ca.conf" <<'CONF'
HostKey /etc/ssh/ssh_host_ed25519_key
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
TrustedUserCAKeys /etc/ssh/ssh-user-ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin yes
CONF
  docker cp "$RUN/10-ssh-ca.conf" ssh-server:/etc/ssh/sshd_config.d/10-ssh-ca.conf

  # Principal -> account maps (reuse the repo's example files).
  docker exec ssh-server mkdir -p /etc/ssh/auth_principals
  for u in root developer deployer; do
    docker cp "$REPO_DIR/examples/auth_principals/$u" "ssh-server:/etc/ssh/auth_principals/$u"
  done
  docker exec ssh-server chown -R root:root /etc/ssh
  docker exec ssh-server chmod 644 /etc/ssh/ssh_host_ed25519_key-cert.pub /etc/ssh/ssh-user-ca.pub

  reload

  # Client trust: @cert-authority for the Host CA (note the [host]:port form).
  printf '@cert-authority [%s]:%s,[localhost]:%s %s\n' \
    "$HOSTADDR" "$PORT" "$PORT" "$(cat "$RUN/ca/ssh-host-ca.pub")" > "$RUN/known_hosts"
}

reload() { docker exec ssh-server kill -HUP 1; sleep 1; }

# ---- user certs + connections -------------------------------------------------
# sign_user <principals> <validity> <serial> [extra ssh-keygen opts...]
sign_user() {
  local principals="$1" validity="$2" serial="$3"; shift 3
  mkdir -p "$RUN/user"
  [[ -f "$RUN/user/id_ed25519" ]] || ssh-keygen -q -t ed25519 -f "$RUN/user/id_ed25519" -N '' -C 'jane@lab'
  ssh-keygen -q -s "$RUN/ca/ssh-user-ca" -I 'Jane Jolie' -n "$principals" \
    -V "$validity" -z "$serial" "$@" "$RUN/user/id_ed25519.pub"
}

# connect <user> <remote-cmd> [extra ssh opts...]
connect() {
  local user="$1" cmd="$2"; shift 2
  "${ssh_base[@]}" "$@" "${user}@${HOSTADDR}" "$cmd"
}

# ---- use cases ----------------------------------------------------------------
uc1() {
  log "UC1  Dual CA lifecycle (ECDSA nistp256)"
  ca
  grep -q '^ecdsa-sha2-nistp256 ' "$RUN/ca/ssh-user-ca.pub" || die "User CA is not ECDSA nistp256"
  grep -q '^ecdsa-sha2-nistp256 ' "$RUN/ca/ssh-host-ca.pub" || die "Host CA is not ECDSA nistp256"
  [[ "$(cat "$RUN/ca/ssh-user-ca.pub")" != "$(cat "$RUN/ca/ssh-host-ca.pub")" ]] || die "User and Host CA are identical"
  ok "Separate User CA + Host CA (ECDSA nistp256) created (KMS/PKCS#11 path: kms-sign.sh)"
}

uc2() {
  log "UC2  Host certificate signing + deployment"
  host_install
  ssh-keygen -L -f "$RUN/host_ed25519-cert.pub" | grep -q 'Type: ssh-ed25519-cert-v01@openssh.com host certificate' \
    || die "Not a host certificate"
  ssh-keygen -L -f "$RUN/host_ed25519-cert.pub" | grep -q 'server.lab.local' || die "Missing host principal"
  ok "Host certificate signed by Host CA and installed"
}

uc4() {
  log "UC4  User certificate signing"
  sign_user 'admin,developer' '+1w' 4
  ssh-keygen -L -f "$RUN/user/id_ed25519-cert.pub" | grep -q 'Type: ssh-ed25519-cert-v01@openssh.com user certificate' \
    || die "Not a user certificate"
  ssh-keygen -L -f "$RUN/user/id_ed25519-cert.pub" | grep -q 'permit-pty' || die "Missing default extensions"
  ok "User certificate signed by User CA with default extensions"
}

uc3() {
  log "UC3  Host-cert trust eliminates TOFU"
  sign_user 'admin' '+1h' 30
  local out
  out="$(connect root whoami -v 2>&1)" || die "cert-based login failed: $out"
  grep -q '^root$' <<<"$out" || die "did not log in as root"
  grep -qiE 'matches the .*host certificate|Server host certificate' <<<"$out" \
    || die "host certificate was not used for host verification"
  ok "Connected with StrictHostKeyChecking=yes via @cert-authority (no TOFU)"
}

uc5() {
  log "UC5  RBAC via AuthorizedPrincipalsFile"
  sign_user 'admin' '+1h' 31
  [[ "$(connect root whoami 2>/dev/null)" == 'root' ]] || die "principal 'admin' should log in as root"
  if connect developer whoami >/dev/null 2>&1; then die "principal 'admin' must NOT log in as developer"; fi
  sign_user 'developer' '+1h' 32
  [[ "$(connect developer whoami 2>/dev/null)" == 'developer' ]] || die "principal 'developer' should log in as developer"
  ok "Same key, different principals -> different access"
}

uc6() {
  log "UC6  PTY denial via -O clear (no permit-pty)"
  sign_user 'admin' '+1h' 33 -O clear -O extension:permit-agent-forwarding
  [[ "$(connect root uname 2>/dev/null)" == 'Linux' ]] || die "command execution should still work"
  local out
  out="$(connect root true -tt 2>&1 || true)"
  grep -q 'PTY allocation request failed' <<<"$out" || die "interactive shell should be denied"
  ok "Commands run, but interactive PTY is denied by the certificate"
}

uc7() {
  log "UC7  force-command critical option"
  sign_user 'admin' '+1h' 34 -O force-command=/bin/date
  local out; out="$(connect root id 2>/dev/null || true)"
  grep -qiE '[0-9]{4}|UTC' <<<"$out" || die "force-command did not override the requested command (got: $out)"
  grep -qi 'uid=' <<<"$out" && die "client command 'id' was NOT overridden"
  ok "Server ran the forced command, not the client's request"
}

uc8() {
  log "UC8  Certificate expiry"
  sign_user 'admin' '20200101000000:20200101000010' 35
  if connect root whoami >/dev/null 2>&1; then die "expired certificate must not authenticate"; fi
  ok "Expired certificate is rejected"
}

uc9() {
  log "UC9  KRL revocation"
  sign_user 'admin' '+1h' 36
  [[ "$(connect root whoami 2>/dev/null)" == 'root' ]] || die "pre-revocation login should work"
  ssh-keygen -k -f "$RUN/revoked_keys" "$RUN/user/id_ed25519.pub"
  docker cp "$RUN/revoked_keys" ssh-server:/etc/ssh/revoked_keys
  printf 'RevokedKeys /etc/ssh/revoked_keys\n' > "$RUN/20-revoked.conf"
  docker cp "$RUN/20-revoked.conf" ssh-server:/etc/ssh/sshd_config.d/20-revoked.conf
  docker exec ssh-server chown root:root /etc/ssh/revoked_keys /etc/ssh/sshd_config.d/20-revoked.conf
  reload
  if connect root whoami >/dev/null 2>&1; then die "revoked key must not authenticate"; fi
  server_log | grep -qi 'revoked by file' || die "sshd did not log a KRL revocation"
  ok "Revoked key denied; sshd logged 'revoked by file'"
}

all() { up; uc1; uc2; uc4; uc3; uc5; uc6; uc7; uc8; uc9; log "All use cases passed"; }

cmd="${1:-all}"; shift || true
case "$cmd" in
  up|down|clean|ca|host_install|reload|all|uc1|uc2|uc3|uc4|uc5|uc6|uc7|uc8|uc9) "$cmd" "$@" ;;
  logs) server_log ;;
  *) die "unknown command: $cmd" ;;
esac
