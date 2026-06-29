# PLAN — suggested improvements

This roadmap turns the repository from "excellent reference + manual PoC" into a
reproducible, production-credible project. Items are grouped by priority. Each
has a **why** and **concrete next steps**.

The two themes that run through everything:

1. **Close the doc↔reality gaps.** The written architecture (dual CA, KMS-only
   signing, TLS to KMS) is more rigorous than what the PoC actually ran (single
   CA, plaintext CA key on disk, plaintext HTTP to KMS). Make the PoC match the
   docs.
2. **Make it run with one command.** The PoC is currently a manual, copy-paste
   walkthrough. Automating it makes it testable, teachable, and trustworthy.

---

## P0 — Security & publication hygiene (do first)

### 0.1 Rotate/destroy the lab CA key that was exposed on disk
- **Why:** the PoC generated a **plaintext** ECDSA CA private key
  (`poc-data/ssh-client/tmp/ssh-ca`). It is git-ignored and never published, but
  it still sits unencrypted in the working tree. Treat any key that has touched
  disk unencrypted as burned.
- **Steps:** delete `poc-data/` (`rm -rf poc-data/`) once you no longer need the
  captured state; regenerate fresh material from `docs/poc-validation.md`. Never
  reuse the demo CA.

### 0.2 Add a secret-leak guard to the workflow
- **Why:** a public repo with key material in its history is unrecoverable.
  Belt-and-suspenders on top of `.gitignore`.
- **Steps:** add a [`gitleaks`](https://github.com/gitleaks/gitleaks) or
  `trufflehog` pre-commit hook **and** a CI job; add a `SECURITY.md` with a
  responsible-disclosure contact and the "all keys here are disposable lab
  values" statement.

### 0.3 Provider/version drift note
- **Why:** `CLAUDE.md` references `/usr/local/lib/libcosmian_pkcs11.so`, but only
  the `cosmian` CLI is currently installed on the host — the PKCS#11 `.so` is
  missing. README's install snippet fixes this, but the gap is worth a one-line
  caveat so readers aren't surprised.

---

## P1 — Make the PoC real and reproducible

### 1.1 Implement the PKCS#11 signing path (the headline gap)
- **Why:** the whole value proposition is "the CA key never exists as a file."
  The PoC took a shortcut and signed with a local key file. Demonstrating the
  real path is the single most important upgrade.
- **Steps:** add a UC1b that generates the CA key **inside** Cosmian KMS, loads
  the provider with `ssh-add -s /usr/local/lib/libcosmian_pkcs11.so` (or
  `ssh-keygen -D <module>`), and signs host + user certs without the private key
  ever leaving the KMS. Capture the `ssh-keygen -s` output as proof.

### 1.2 Split into dual CAs (User CA + Host CA)
- **Why:** the docs prescribe separate CAs to limit blast radius; the runtime
  used one shared CA. Align the PoC with the documented architecture.
- **Steps:** generate two KMS keys (`ssh-user-ca`, `ssh-host-ca`); point
  `TrustedUserCAKeys` at the user CA and `@cert-authority` / host-cert signing at
  the host CA.

### 1.3 One-command reproducible environment
- **Why:** the PoC is a long manual walkthrough. Friction kills reproducibility.
- **Steps:** add a `poc/` directory with either a `Makefile`
  (`make up`, `make uc1` … `make uc9`, `make clean`) or a `docker-compose.yml`
  plus small shell scripts. Keep the manual doc as the narrated companion; have
  the scripts be the thing CI runs.

### 1.4 Build a reference KRL distribution service
- **Why:** `docs/krl-distribution.md` is a strong design but only a design.
- **Steps:** implement the stateless service (Python/Rust) that does
  `locate → export → ec sign → ec encrypt` against KMS, the `POST /krl` endpoint
  with `ETag`/`If-None-Match` (304/200), and a host-side puller (systemd timer +
  `install -m 444`). Add the mermaid sequence diagram from the doc as a rendered
  image.

### 1.5 TLS/mTLS to the KMS
- **Why:** the PoC talks to KMS over plaintext HTTP (`http://…:9998`).
- **Steps:** front KMS with TLS and use `ssl_client_pkcs12_path` for client auth;
  update `cosmian.toml` and the docs accordingly.

### 1.6 Turn UC1–UC9 into automated assertions
- **Why:** the doc shows "captured output" that a human eyeballs. Make a machine
  assert it.
- **Steps:** a test harness (bats / pytest) that runs each use case and asserts
  on exit codes and `sshd` log lines (`Accepted publickey … ID …`,
  `Certificate invalid: expired`, `revoked by file`, `PTY allocation request
  failed`). Wire it into CI.

### 1.7 Productionize the Ansible automation
- **Why:** the docs reproduce Mens' playbook inline; shipping it as a runnable
  role makes it usable.
- **Steps:** add `ansible/` with the host-keygen → controller-sign
  (`use_agent: true`) → deploy role, parameterized for the dual-CA + KMS setup.

---

## P2 — Documentation & repo quality

### 2.1 Keep the `.docx` and `.md` in sync automatically
- **Why:** two sources drift. Right now the `.md` is a manual pandoc render.
- **Steps:** a GitHub Action that regenerates `docs/technical-reference.md` (and
  `docs/media/`) from the `.docx` on push and fails if the committed `.md` is
  stale — or, alternatively, promote Markdown to the canonical source and drop
  the `.docx`.

### 2.2 Diagram sources, not just PNGs
- **Why:** the four figures are embedded PNGs with no editable source.
- **Steps:** commit the diagram sources (mermaid / draw.io / PlantUML) under
  `docs/diagrams/` and render to PNG in CI so they stay editable.

### 2.3 Docs CI: markdown lint + link check
- **Steps:** add `markdownlint` and a link checker (e.g. `lychee`) in CI to catch
  broken internal/external links and style drift.

### 2.4 Add the standard community files
- **Steps:** `CONTRIBUTING.md` (the pandoc regen workflow lives here),
  `SECURITY.md`, an issue/PR template, and a `CHANGELOG.md`.

### 2.5 Sanitized example configs
- **Why:** the most reusable artifacts (the `sshd_config` CA block,
  `auth_principals/*`, `cosmian.toml`) are buried in the ignored `poc-data/`.
- **Steps:** add an `examples/` directory with redacted, commented copies so
  readers can lift them without running the whole PoC.

---

## P3 — Nice-to-haves

- **Comparison matrix** rendered in the README (keys vs. certificates) so the
  headline benefit is visible without opening the reference.
- **GitHub Pages / mkdocs site** built from `docs/` for nicer browsing.
- **HSM backing demo** (Nitrokey HSM 2 / SoftHSM) behind the same PKCS#11
  interface, to show the KMS is swappable.
- **Metrics/audit dashboard** sketch: parse `sshd` logs into a per-Key-ID
  (human) access trail, which is one of certificates' biggest wins.
- **NTP prerequisite call-out** wherever validity windows are discussed — clock
  skew is a silent failure mode.

---

### Suggested sequencing

1. P0 (hygiene) → safe to publish and keep clean.
2. P1.1 + P1.3 (real KMS signing + one-command PoC) → biggest credibility jump.
3. P1.6 (automated assertions) + P2.3 (docs CI) → keeps it honest over time.
4. Everything else as interest and time allow.
