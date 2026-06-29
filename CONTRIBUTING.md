# Contributing

Thanks for your interest in improving **ssh-ca-cosmian-kms**. This repository is
a practitioner reference plus a reproducible proof of concept for an OpenSSH
Certificate Authority backed by Cosmian KMS over PKCS#11. Contributions to the
documentation, the PoC, the KRL service, the Ansible role, and the tooling are
all welcome.

Please read this guide before opening an issue or pull request.

## Repository layout

```text
.
├── README.md                          Project overview
├── LICENSE                            MIT
├── PLAN.md                            Roadmap / suggested improvements
├── CLAUDE.md                          Guidance for working in this repo
├── SECURITY.md                        Security policy & private reporting
├── CONTRIBUTING.md                    This file
├── CHANGELOG.md                       Keep a Changelog history
├── .github/                           Issue/PR templates and CI workflows
├── docs/
│   ├── technical-reference.md         Canonical Markdown source (no .docx)
│   ├── poc-validation.md              Docker PoC narrative (UC1–UC9)
│   ├── krl-distribution.md            KRL distribution service design
│   ├── media/                         Figures used by the docs and the PDF
│   ├── diagrams/                      Editable diagram sources (rendered in CI)
│   └── pdf/                           PDF build pipeline (pandoc + xelatex)
├── poc/                               One-command reproducible PoC (Makefile)
├── ansible/                           Ansible role for keygen → sign → deploy
└── examples/                          Sanitized sshd_config / auth_principals / cosmian.toml
```

## Documentation is Markdown-canonical

`docs/technical-reference.md` is the **single source of truth**. Edit the
Markdown directly — there is **no `.docx`** anymore.

The polished PDF is a build artifact, not something you edit or commit. It is
built from the Markdown by `docs/pdf/build.sh` (pandoc + xelatex), and CI
publishes it to the `latest` GitHub release. To build the PDF locally:

```bash
docs/pdf/build.sh            # writes docs/technical-reference.pdf
```

This needs `pandoc`, `xelatex` (`texlive-xetex` plus
`texlive-latex-extra`/`-recommended`), and the Liberation and DejaVu fonts. The
styling lives in `docs/pdf/` (`template.tex`, `preamble.tex`, and the
`table-widths.lua` / `center-figures.lua` filters). Do not commit
`*.pdf` — it is git-ignored.

Diagrams: commit the editable source under `docs/diagrams/` (mermaid / draw.io /
PlantUML); CI renders them to PNG under `docs/media/`. Do not hand-edit the
generated PNGs.

## Running the proof of concept

The PoC runs three Docker containers on the `ssh-ca-lab` bridge network
(subnet `10.222.9.0/24`): Cosmian KMS (`10.222.9.10`, port `9998`), an `sshd`
server (`10.222.9.20`), and a client that doubles as the CA operator
(`10.222.9.30`).

From the `poc/` directory:

```bash
cd poc
make up       # build images and start the lab network
make test     # run the UC1–UC9 assertions against the running lab
make clean    # tear everything down and remove runtime state
```

`make test` is what CI runs. It asserts on exit codes and on the captured
`sshd` log lines that prove each use case (for example
`Accepted publickey ... ID ...`, `Certificate invalid: expired`,
`revoked by file`, `PTY allocation request failed`). `docs/poc-validation.md`
is the narrated companion to the automated scripts.

Generate fresh keys for every run — all runtime state lands under the
git-ignored `poc-data/` directory and must never be committed.

### KRL distribution service

The stateless, encrypted KRL REST service (FastAPI + uvicorn, Python 3.11
managed with `uv`) delegates all cryptography to KMS. Its design is in
`docs/krl-distribution.md`. Run and test it through its own targets/scripts; it
holds no secrets of its own.

### Ansible role

The role in `ansible/` implements the Jan-Piet Mens pattern: the private key is
generated **on the node** (never traverses the network) and the public key is
signed **on the controller** via `ssh-agent` (`use_agent: true`), parameterized
for the dual-CA + KMS setup.

## Coding conventions

- **Bash:** start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
  Keep them small, idempotent, and well commented.
- **Python:** target 3.11, managed with `uv` (`uv run`, `uv pip`, `uv sync`).
  Use FastAPI + uvicorn for services. Never invoke raw `pip` / `python3`.
- **Markdown:** must pass `markdownlint` — sensible heading hierarchy, fenced
  code blocks with a language, no trailing whitespace. Internal and external
  links must pass the link checker.
- **CA vs. end-entity keys:** CA keys are ECDSA nistp256 (PKCS#11 v2.40);
  host/user keys are Ed25519. Keep KMS object tags `ssh-user-ca` /
  `ssh-host-ca` consistent.
- **No secrets, ever.** Use the disposable lab values described in
  `SECURITY.md`. `gitleaks` runs in pre-commit and CI.

## Pre-commit

Install the hooks once so checks run before each commit:

```bash
uv run pre-commit install
```

Pre-commit runs `gitleaks` (secret scanning) along with the Markdown and
whitespace checks. You can run everything on demand with
`uv run pre-commit run --all-files`.

## Pull request process

1. Fork and branch from `main`.
2. Make focused changes; update the docs and `CHANGELOG.md` (Unreleased
   section) when behavior or structure changes.
3. Ensure pre-commit passes locally and **no secrets** are staged.
4. Open a PR using the template and fill in the checklist.

All PRs must pass these CI checks before they can merge:

- **build-pdf** — the PDF builds from the Markdown (pandoc + xelatex).
- **docs lint + linkcheck** — `markdownlint` and the link checker pass.
- **gitleaks** — no secrets detected.
- **poc test** — `make test` (the UC1–UC9 assertions) passes.

Report security issues privately — see [SECURITY.md](SECURITY.md). Do not file a
public issue for a vulnerability.
