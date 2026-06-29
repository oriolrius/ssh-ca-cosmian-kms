# PLAN — roadmap and status

This roadmap turned the repository from "excellent reference + manual PoC" into a
reproducible, production-credible project. **P0, P1 and P2 are complete**; P3
remains as optional nice-to-haves.

Two themes drove the work:

1. **Close the doc↔reality gaps** — the written architecture (dual CA, KMS-only
   signing, TLS to KMS) is now matched by runnable automation.
2. **Make it run with one command** — `cd poc && make up && make test`.

---

## P0 — Security & publication hygiene — ✅ Done

### 0.1 Rotate/destroy the exposed lab CA key — ✅

The plaintext `poc-data/` (which held an unencrypted CA key) was deleted. The new
PoC generates fresh, disposable material under the git-ignored `poc/run/` on every
run; nothing persists in the tree.

### 0.2 Secret-leak guard — ✅

- `.pre-commit-config.yaml` runs **gitleaks** (plus `detect-private-key`,
  large-file and whitespace hooks) on every commit.
- `.github/workflows/security.yml` runs gitleaks on push/PR over full history.
- `.gitleaks.toml` allowlists known non-secrets (SSH public-key *fingerprints*,
  the documented `p12_password` placeholder). gitleaks is clean on files + history.
- `SECURITY.md` documents disclosure and the "all values are disposable lab" note.

### 0.3 Provider/version drift note — ✅

The README and `poc/README.md` call out that the PKCS#11 provider
(`libcosmian_pkcs11.so`) ships in the Cosmian release zip (not the `.deb`); the
KMS signing path checks for it and fails with a clear message if absent.

---

## P1 — Make the PoC real and reproducible — ✅ Done

### 1.1 PKCS#11 signing path — ✅

`poc/scripts/kms-sign.sh` creates the CA keys **inside** Cosmian KMS
(`ec keys create --sensitive`), loads the provider into `ssh-agent`
(`ssh-add -s libcosmian_pkcs11.so`), and signs host/user certs via the agent
(`ssh-keygen -Us`) — the CA private key never becomes a file. Documented in
`poc/README.md` and the technical reference §10.5.

### 1.2 Dual CAs (User CA + Host CA) — ✅

Both the file backend (`poc/scripts/poc.sh`) and the KMS backend create two
separate ECDSA nistp256 CAs; UC1 asserts they are distinct. `TrustedUserCAKeys`
trusts the User CA; host certificates are signed by the Host CA.

### 1.3 One-command reproducible environment — ✅

`poc/` provides `docker-compose.yml`, a `Makefile`, and `scripts/poc.sh`.
`make up && make test` builds the server and runs UC1–UC9. **Verified passing
end to end.**

### 1.4 Reference KRL distribution service — ✅

`services/krl-distributor/` is a FastAPI implementation of
`docs/krl-distribution.md` (locate → export → `ec sign` → ECIES `ec encrypt`,
`POST /krl` with `If-None-Match` → 304/200, stateless, all crypto delegated to
KMS), with a host-side puller + systemd units and **10 passing pytest tests**
(KMS mocked, runs offline).

### 1.5 TLS/mTLS to the KMS — ✅

`examples/cosmian.toml` and the compose overlay show TLS (`server_url=https://…`,
`ssl_client_pkcs12_path`); documented in `poc/README.md`.

### 1.6 UC1–UC9 as automated assertions — ✅

`poc/test/uc.bats` asserts every use case (exit codes + sshd log lines like
`revoked by file`, `PTY allocation request failed`, expiry). Wired into CI
(`.github/workflows/ci.yml`). **All 9 pass.**

### 1.7 Ansible automation — ✅

`ansible/` ships the `ssh_host_cert` role (key generated on the node, signed on
the controller via `ssh-agent`/KMS, deployed; sshd configured) — passes
`ansible-lint --profile production` and `--syntax-check`.

---

## P2 — Documentation & repo quality — ✅ Done

### 2.1 Single-source Markdown + CI-built PDF — ✅

Markdown is canonical; the `.docx` was removed; CI builds the PDF and publishes
it to the `latest` release (see `docs/pdf/`, `.github/workflows/build-pdf.yml`).

### 2.2 Diagram sources — ✅

`docs/diagrams/*.mmd` are editable Mermaid sources for the four figures;
`.github/workflows/docs.yml` renders them to PNG (validated locally).

### 2.3 Docs CI: markdown lint + link check — ✅

`.github/workflows/docs.yml` runs `markdownlint-cli2` (config in
`.markdownlint-cli2.yaml`) and `lychee` (config in `lychee.toml`).

### 2.4 Community/health files — ✅

`CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, issue templates, and a PR
template were added.

### 2.5 Sanitized example configs — ✅

`examples/` carries redacted `sshd_config.d`, `auth_principals`, `ssh_config.d`,
`known_hosts`, and `cosmian.toml`.

---

## P3 — Nice-to-haves (not in scope)

- Comparison matrix rendered directly in the README.
- GitHub Pages / mkdocs site built from `docs/`.
- HSM backing demo (Nitrokey HSM 2 / SoftHSM) behind the same PKCS#11 interface.
- Metrics/audit dashboard parsing `sshd` logs into a per-Key-ID access trail.
- NTP prerequisite call-outs wherever validity windows are discussed.
