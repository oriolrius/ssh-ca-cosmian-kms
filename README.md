# SSH Certificate Authority with Cosmian KMS

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-technical%20reference-blue.svg)](docs/technical-reference.md)

A practitioner-grade reference for replacing per-host SSH keys with **OpenSSH
certificates**, where the Certificate Authority private key lives inside
[Cosmian KMS](https://github.com/Cosmian/kms) and is used for signing over
**PKCS#11** — so the CA key never exists as a file on disk.

SSH certificates turn trust management from **O(N×M)** (every user × every host)
into **O(N+M)**, while adding expiry, principal-based RBAC, least-privilege
restrictions, and a human-attributable audit trail.

> [!IMPORTANT]
> This repository is **documentation and a proof-of-concept**, not a turnkey
> product. All keys, fingerprints, hostnames and IPs that appear in the docs are
> from a disposable lab. No private keys or secrets are committed — see
> [Security & privacy](#security--privacy).

## What's inside

| Topic | What it covers |
|---|---|
| **Certificate internals** | OpenSSH cert wire format, the 6-step `sshd` verification chain, host vs. user certificates |
| **Eliminating TOFU & `authorized_keys`** | Host certificates remove `known_hosts` churn; user certificates remove per-host `authorized_keys` |
| **RBAC via principals** | `AuthorizedPrincipalsFile` maps role-principals to local accounts |
| **Least privilege in the cert** | `-O clear`, `force-command`, `source-address`, PTY denial — enforced cryptographically by `sshd` |
| **Revocation** | Key Revocation Lists (KRL), plus short-TTL certs as the primary mechanism |
| **KMS-backed CA** | Cosmian KMS + PKCS#11 (`libcosmian_pkcs11.so`); CA key never written to disk |
| **Automation** | Jan-Piet Mens' Ansible pattern (key generated on the node, signed on the controller via `ssh-agent`) |

## Repository structure

```
.
├── README.md                       This file
├── LICENSE                         MIT
├── PLAN.md                         Suggested improvements / roadmap
├── CLAUDE.md                       Guidance for working in this repo with Claude Code
└── docs/
    ├── technical-reference.docx    Authoritative, editable source (Word)
    ├── technical-reference.md      Browsable Markdown rendering (read this on GitHub)
    ├── media/                      Figures extracted from the .docx
    ├── poc-validation.md           Docker PoC validating use cases UC1–UC9
    └── krl-distribution.md         Design for an encrypted, stateless KRL distribution API
```

## Documentation

- **[Technical reference](docs/technical-reference.md)** — the full architecture,
  cryptographic internals, configuration, and automation guide. (The
  [`.docx`](docs/technical-reference.docx) is the editable source; the `.md` is the
  rendered, GitHub-browsable copy.)
- **[PoC validation](docs/poc-validation.md)** — a reproducible, Docker-based
  proof of concept that validates nine use cases (UC1–UC9) end to end, with the
  captured `sshd` log lines that prove each one.
- **[KRL distribution design](docs/krl-distribution.md)** — a stateless,
  encrypted REST service that distributes per-host revocation lists using KMS for
  all crypto (ECIES encryption + ECDSA signing), holding no secrets itself.

## Quick start (proof of concept)

The PoC runs three Docker containers on a dedicated bridge network — Cosmian KMS,
an `sshd` server, and an SSH client that doubles as the CA operator — and walks
through CA creation, host/user certificate signing, RBAC, restrictions, expiry,
and revocation. Follow it step by step in **[docs/poc-validation.md](docs/poc-validation.md)**.

It deliberately avoids `docker-compose` so every step is an explicit, auditable
`docker` / `ssh-keygen` command.

### Installing the Cosmian CLI

Use the Ubuntu 22.04 release — the `.deb` and the Ubuntu 24.04 zip require
`GLIBC_2.38` and won't run on 22.04.

```bash
wget 'https://github.com/Cosmian/cli/releases/download/1.9.0/ubuntu_22_04-release.zip'
unzip ubuntu_22_04-release.zip

BASE="ubuntu_22_04-release/home/runner/work/cli/cli/target/x86_64-unknown-linux-gnu/release"
sudo install -m 755 "$BASE/cosmian" /usr/local/bin/
sudo install -m 755 "$BASE/libcosmian_pkcs11.so" /usr/local/lib/

cosmian --version   # cosmian_cli 1.9.0
```

## Key design decisions

- **ECDSA nistp256 for the CA key** (not Ed25519): PKCS#11 v2.40 — the version
  most HSMs and KMSs implement — does not define Ed25519 (`CKM_EDDSA` arrived only
  in PKCS#11 v3.0). ECDSA nistp256 keeps the KMS/HSM door open at 128-bit security.
  Ed25519 remains the recommended choice for end-entity host/user keys.
- **Dual-CA architecture**: separate User CA and Host CA to limit blast radius —
  a compromised user CA cannot forge host identities, and vice versa.
- **CA key never on disk**: signing goes through `libcosmian_pkcs11.so`, either via
  `ssh-add -s <module>` (so `ssh-keygen` and Ansible's `openssh_cert` work
  unmodified) or `ssh-keygen -D <module>`.
- **Short certificate TTLs** as the primary revocation mechanism, with KRLs as the
  emergency path.

## Security & privacy

- **No secrets are committed.** Private keys, host keys, the KMS database, and
  other runtime state live only under `poc-data/`, which is git-ignored. The
  `.gitignore` also blocks common key/secret patterns as defense in depth.
- All identifiers in the docs (CA fingerprints, `server.lab.local`, the
  `10.222.9.0/24` lab subnet, `192.0.2.x` example addresses) are **disposable lab
  values**, safe to publish.
- To reproduce the environment, generate fresh keys by following
  [docs/poc-validation.md](docs/poc-validation.md) — never reuse the demo material.

## Contributing

The Word document is the editable source of truth for the technical reference;
regenerate the Markdown rendering after substantive edits:

```bash
pandoc docs/technical-reference.docx -o docs/technical-reference.md \
  --track-changes=accept --extract-media=docs --wrap=none
sed -i 's#](docs/media/#](media/#g' docs/technical-reference.md
```

See [PLAN.md](PLAN.md) for the suggested roadmap.

## License

[MIT](LICENSE) © 2026 Oriol Rius. Built on the work of
[Jan-Piet Mens](https://jpmens.net/) and the OpenSSH and Cosmian projects.
