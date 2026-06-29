#!/usr/bin/env bats
# Automated assertions for UC1-UC9. Requires Docker and the host's
# ssh / ssh-keygen. Run with:  bats poc/test/uc.bats   (or: make test)
#
# Each test delegates to scripts/poc.sh <ucN>, which performs the use case and
# asserts its own outcome (non-zero exit on failure).

setup_file() {
  export SSH_PORT="${SSH_PORT:-22022}"
  cd "$BATS_TEST_DIRNAME/.."
  bash scripts/poc.sh up
  bash scripts/poc.sh uc2   # brings up the CA + host certificate once
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME/.."
  bash scripts/poc.sh down || true
}

run_uc() { cd "$BATS_TEST_DIRNAME/.."; SSH_PORT="${SSH_PORT:-22022}" bash scripts/poc.sh "$1"; }

@test "UC1  dual CA lifecycle (ECDSA nistp256)" { run run_uc uc1; [ "$status" -eq 0 ]; }
@test "UC2  host certificate signing + deployment" { run run_uc uc2; [ "$status" -eq 0 ]; }
@test "UC4  user certificate signing" { run run_uc uc4; [ "$status" -eq 0 ]; }
@test "UC3  host-cert trust eliminates TOFU" { run run_uc uc3; [ "$status" -eq 0 ]; }
@test "UC5  RBAC via AuthorizedPrincipalsFile" { run run_uc uc5; [ "$status" -eq 0 ]; }
@test "UC6  PTY denial via -O clear" { run run_uc uc6; [ "$status" -eq 0 ]; }
@test "UC7  force-command critical option" { run run_uc uc7; [ "$status" -eq 0 ]; }
@test "UC8  certificate expiry" { run run_uc uc8; [ "$status" -eq 0 ]; }
@test "UC9  KRL revocation" { run run_uc uc9; [ "$status" -eq 0 ]; }
