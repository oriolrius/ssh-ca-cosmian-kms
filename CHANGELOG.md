# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Reproducible Docker proof of concept under `poc/` (`make up` / `make test` /
  `make clean`): dual-CA architecture (separate `ssh-user-ca` and
  `ssh-host-ca` keys), the KMS PKCS#11 signing path
  (`/usr/local/lib/libcosmian_pkcs11.so`, CA key never on disk), and TLS to the
  KMS.
- Automated UC1–UC9 assertions wired into CI, asserting on exit codes and the
  captured `sshd` log lines that prove each use case.
- Stateless, encrypted **KRL distribution service** (FastAPI + uvicorn) that
  delegates all cryptography (ECIES encryption, ECDSA signing) to Cosmian KMS
  and holds no secrets of its own.
- **Ansible role** (`ansible/`) implementing the Jan-Piet Mens pattern: private
  key generated on the node, public key signed on the controller via
  `ssh-agent` (`use_agent: true`), parameterized for the dual-CA + KMS setup.
- Security tooling: `gitleaks` secret scanning via a pre-commit hook and a CI
  job.
- Docs CI: `markdownlint` plus a link checker on every change to `docs/`.
- Sanitized, commented `examples/` (the `sshd_config` CA block,
  `auth_principals/*`, and `cosmian.toml`) so the reusable artifacts are not
  buried in the git-ignored `poc-data/`.
- Editable diagram sources under `docs/diagrams/`, rendered to PNG in CI.
- Community and health files: `SECURITY.md`, `CONTRIBUTING.md`, this
  `CHANGELOG.md`, issue/PR templates.

### Changed

- Restructured into a public-facing repository layout (`docs/`, `poc/`,
  `ansible/`, `examples/`, `.github/`).
- Documentation is now **Markdown-canonical**: `docs/technical-reference.md` is
  the single source of truth and the `.docx` has been removed. The styled PDF
  is built from the Markdown by CI (pandoc + xelatex) and published to the
  `latest` GitHub release.

[Unreleased]: https://github.com/oriolrius/ssh-ca-cosmian-kms/commits/main
