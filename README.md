# SSH Certificate Authority with Cosmian KMS

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-technical%20reference-blue.svg)](docs/technical-reference.md)
[![Build PDF](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/build-pdf.yml/badge.svg)](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/build-pdf.yml)
[![CI](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/ci.yml/badge.svg)](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/ci.yml)
[![Docs](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/docs.yml/badge.svg)](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/docs.yml)
[![Security](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/security.yml/badge.svg)](https://github.com/oriolrius/ssh-ca-cosmian-kms/actions/workflows/security.yml)
[![Download PDF](https://img.shields.io/badge/download-PDF-red.svg)](https://github.com/oriolrius/ssh-ca-cosmian-kms/releases/download/latest/ssh-ca-technical-reference.pdf)

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

```text
.
├── README.md / LICENSE / PLAN.md / CLAUDE.md
├── CONTRIBUTING.md / SECURITY.md / CHANGELOG.md
├── .github/workflows/      build-pdf · ci · docs · security
├── docs/
│   ├── technical-reference.md   Canonical source for the technical reference
│   ├── media/                   Figures used by the reference (and the PDF)
│   ├── diagrams/                Editable Mermaid sources for the figures
│   ├── poc-validation.md        Narrated UC1–UC9 walkthrough
│   ├── krl-distribution.md      Encrypted, stateless KRL distribution design
│   └── pdf/                     PDF build pipeline (pandoc + xelatex)
├── poc/                    One-command Docker PoC (make up && make test)
├── services/krl-distributor/   FastAPI KRL distribution service (KMS-backed)
├── ansible/                Role automating host-cert issuance (dual-CA + KMS)
└── examples/               Sanitized sshd_config, auth_principals, cosmian.toml…
```

## Documentation

- **[Technical reference](docs/technical-reference.md)** — the full architecture,
  cryptographic internals, configuration, and automation guide. This Markdown
  file is the **canonical source**; a polished PDF (same look and feel, with the
  diagrams inline) is built from it by CI —
  **[download the latest PDF](https://github.com/oriolrius/ssh-ca-cosmian-kms/releases/download/latest/ssh-ca-technical-reference.pdf)**.
- **[PoC validation](docs/poc-validation.md)** — a reproducible, Docker-based
  proof of concept that validates nine use cases (UC1–UC9) end to end, with the
  captured `sshd` log lines that prove each one.
- **[KRL distribution design](docs/krl-distribution.md)** — a stateless,
  encrypted REST service that distributes per-host revocation lists using KMS for
  all crypto (ECIES encryption + ECDSA signing), holding no secrets itself.

## Quick start

**Run the whole PoC with one command** (needs Docker and the host's `ssh` /
`ssh-keygen`):

```bash
cd poc
make up        # build + start the sshd server
make test      # run UC1-UC9, each step self-asserting
make clean     # tear down
```

UC1–UC9 exercise the dual CA, host/user certificate signing, TOFU elimination,
principal-based RBAC, PTY denial, force-command, expiry, and KRL revocation. The
default file-based dual-CA path needs **no KMS**. For the production path — CA
keys held in Cosmian KMS and used via PKCS#11 so they never touch disk — see
[`poc/README.md`](poc/README.md) and `poc/scripts/kms-sign.sh`. A narrated,
step-by-step version lives in [docs/poc-validation.md](docs/poc-validation.md).

### Installing the Cosmian CLI (for the KMS path)

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

> [!NOTE]
> The PKCS#11 provider (`libcosmian_pkcs11.so`) ships in that **zip, not the
> `.deb`**. If `cosmian --version` works but KMS signing fails, the provider is
> missing — install it from the zip as shown above.

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

- **No secrets are committed.** Generated keys and certificates live only under
  the git-ignored `poc/run/`. The `.gitignore` blocks key/secret patterns, and
  **gitleaks** runs both as a pre-commit hook and in CI
  ([`security.yml`](.github/workflows/security.yml)) over the full history.
- All identifiers in the docs (CA fingerprints, `server.lab.local`, the
  `10.222.9.0/24` lab subnet, `192.0.2.x` example addresses) are **disposable lab
  values**, safe to publish.
- See [`SECURITY.md`](SECURITY.md) for the project's security posture and how to
  report a vulnerability. Always generate fresh keys; never reuse demo material.

## Contributing

`docs/technical-reference.md` is the single source of truth — edit the Markdown
directly. The PDF is regenerated by CI on every push to `main` and attached to
the [`latest` release](https://github.com/oriolrius/ssh-ca-cosmian-kms/releases/tag/latest).

To build the PDF locally you need `pandoc`, `xelatex`
(`texlive-xetex` + `texlive-latex-extra`/`-recommended`), and the Liberation
and DejaVu fonts:

```bash
docs/pdf/build.sh            # writes docs/technical-reference.pdf
```

The PDF styling lives in `docs/pdf/` (`template.tex`, `preamble.tex`, and two
Lua filters for table widths and figure centering).

See [PLAN.md](PLAN.md) for the suggested roadmap.

## License

[MIT](LICENSE) © 2026 Oriol Rius. Built on the work of
[Jan-Piet Mens](https://jpmens.net/) and the OpenSSH and Cosmian projects.
