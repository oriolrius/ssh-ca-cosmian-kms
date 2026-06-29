# SSH CA proof of concept — one command

A reproducible version of the manual walkthrough in
[`../docs/poc-validation.md`](../docs/poc-validation.md). The host acts as the
**CA operator** and **SSH client** (using your `ssh` / `ssh-keygen`); a container
runs `sshd`. Every use case asserts its own outcome, so the whole thing is a test.

## Quick start

```bash
cd poc
make up        # build + start the ssh-server container
make all       # run UC1-UC9 (sets up the dual CA + host cert first)
make test      # same, via bats if installed
make clean     # tear down + delete run/
```

Need a different local port? `SSH_PORT=22022 make all` (or copy `.env.example`
to `.env`).

## What it proves

| UC | Demonstrates |
|----|--------------|
| UC1 | **Dual CA** lifecycle — separate User CA + Host CA, ECDSA nistp256 |
| UC2 | Host certificate signed by the Host CA and deployed |
| UC3 | Host-cert trust eliminates **TOFU** (`StrictHostKeyChecking=yes` via `@cert-authority`) |
| UC4 | User certificate signed by the User CA |
| UC5 | **RBAC** — same key, different principals → different accounts |
| UC6 | **PTY denial** via `-O clear` (run commands, no interactive shell) |
| UC7 | **force-command** critical option overrides the client's request |
| UC8 | **Expiry** — an expired certificate is rejected |
| UC9 | **KRL revocation** — revoked key denied; `sshd` logs `revoked by file` |

## Two CA backends

- **File backend (default).** `make all` generates the dual CA as local files and
  signs with `ssh-keygen`. No KMS required — this is what CI runs.
- **KMS / PKCS#11 backend (production).** The CA private keys live in Cosmian KMS
  and are used via `libcosmian_pkcs11.so`; they never exist as files. Bring up the
  KMS and use [`scripts/kms-sign.sh`](scripts/kms-sign.sh):

  ```bash
  make kms-up                       # Cosmian KMS + KRL distributor overlay
  scripts/kms-sign.sh init          # create the dual CA inside the KMS
  eval "$(ssh-agent -s)"
  scripts/kms-sign.sh load          # load the PKCS#11 provider into ssh-agent
  scripts/kms-sign.sh host id_ed25519.pub server.lab.local,10.222.9.20
  ```

  See [`../docs/technical-reference.md`](../docs/technical-reference.md) §9–§10.5.

## TLS / mTLS to the KMS

The PoC overlay talks to the KMS over the lab network. For production, front the
KMS with TLS and point the client at it via
[`../examples/cosmian.toml`](../examples/cosmian.toml)
(`server_url = "https://…"` + `ssl_client_pkcs12_path`). The signing flow is
unchanged — only the transport.

## Layout

```text
poc/
├── docker-compose.yml        ssh-server (published on 127.0.0.1:${SSH_PORT})
├── docker-compose.kms.yml    optional: Cosmian KMS + KRL distributor
├── ssh-server/               minimal Ubuntu + sshd image
├── scripts/poc.sh            the engine (up, ucN, all, clean)
├── scripts/kms-sign.sh       KMS / PKCS#11 production signing path
├── test/uc.bats              UC1-UC9 as a bats suite (run in CI)
└── run/                      generated keys/certs (git-ignored)
```
