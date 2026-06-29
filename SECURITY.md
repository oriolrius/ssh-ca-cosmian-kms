# Security Policy

This repository is **documentation and a proof of concept** for running an
OpenSSH Certificate Authority whose private keys live inside
[Cosmian KMS](https://github.com/Cosmian/kms) and are used for signing over
PKCS#11. It is not a turnkey product, but we take the security of the design,
the example code, and the supply chain seriously.

## No real secrets in this repository

> [!IMPORTANT]
> **All keys, fingerprints, hostnames and IPs in this repository are
> disposable lab values, not real secrets.**

Everything that looks like sensitive material is throwaway lab data, safe to
publish:

- CA and host/user certificate fingerprints shown in the docs come from a
  scratch lab that no longer exists.
- Hostnames such as `server.lab.local` and `example.com`, the
  `10.222.9.0/24` lab subnet, and `192.0.2.x` / `198.51.100.x` example
  addresses are reserved-for-documentation or private-range values.
- All runtime key material (CA keys, host keys, the KMS database, generated
  certificates, `cosmian.toml` with credentials) lives only under the
  git-ignored `poc-data/` directory and is **never** committed.
- `gitleaks` runs both as a pre-commit hook and as a CI job as defense in
  depth against an accidental secret commit.

If you reproduce the proof of concept, generate **fresh** keys by following
`docs/poc-validation.md`. Never reuse the demo material in a real environment.

## Supported scope

Because this is a reference project rather than released software, security
fixes are applied to the `main` branch only. There are no maintained release
branches.

| Component | In scope |
|---|---|
| Documentation (`docs/`) | Yes — factual/cryptographic errors that could lead a reader to an insecure deployment |
| Proof-of-concept code (`poc/`) | Yes — issues in the Docker PoC, scripts, and test harness |
| KRL distribution service | Yes — issues in the stateless KRL REST service |
| Ansible role (`ansible/`) | Yes — issues in the automation role |
| CI / build tooling (`.github/`, `docs/pdf/`) | Yes — supply-chain or workflow issues |
| Third-party software (OpenSSH, Cosmian KMS, pandoc, TeX Live) | No — report upstream |

## Reporting a vulnerability

**Please report security issues privately. Do not open a public issue for a
vulnerability.**

Report privately through **GitHub Security Advisories**:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** (Private vulnerability reporting).
3. Describe the issue, the affected files, and steps to reproduce.

This keeps the report confidential between you and the maintainers until a fix
is available. We do not publish a security contact email — use the Security tab
so the conversation stays private and tracked.

Please include, where applicable:

- the affected file(s) or component,
- a clear description of the impact and how to reproduce it,
- any suggested remediation.

We aim to acknowledge a report within a few business days, agree on a
disclosure timeline with you, and credit you in the advisory and `CHANGELOG.md`
unless you prefer to remain anonymous.

## Project security posture

The architecture this repository documents is built around a few deliberate
security properties:

- **CA key never on disk.** Both the User CA and the Host CA private keys are
  generated and stored inside Cosmian KMS. Signing happens through the PKCS#11
  provider `/usr/local/lib/libcosmian_pkcs11.so` (via `ssh-add -s <module>` or
  `ssh-keygen -D <module>`), so the CA private key never exists as a file.
- **Dual CA.** Separate User CA (`ssh-user-ca`) and Host CA (`ssh-host-ca`)
  keys limit blast radius: a compromised user CA cannot forge host identities,
  and vice versa.
- **ECDSA nistp256 for CA keys** for PKCS#11 v2.40 compatibility with HSMs/KMS;
  Ed25519 for end-entity host and user keys.
- **Short certificate TTLs** are the primary revocation mechanism, with **Key
  Revocation Lists (KRL)** as the emergency path. The KRL distribution service
  is stateless and holds no secrets — it delegates all crypto (ECIES
  encryption, ECDSA signing) to KMS.
- **Least privilege in the certificate.** Principal-to-account RBAC via
  `AuthorizedPrincipalsFile`, plus `force-command`, `source-address`, and PTY
  denial enforced cryptographically by `sshd`.
- **TLS to KMS.** The PoC and examples talk to the KMS over TLS with optional
  client-certificate authentication (`ssl_client_pkcs12_path`).
