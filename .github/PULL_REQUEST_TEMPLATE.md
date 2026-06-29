<!--
Thanks for contributing! Please read CONTRIBUTING.md first.
Do not commit secrets — all keys/fingerprints/hostnames/IPs must be disposable
lab values. Report security issues privately via the Security tab, not in a PR.
-->

## Summary

What does this PR change and why? Link any related issue (e.g. `Closes #123`).

## Type of change

- [ ] Documentation (`docs/`)
- [ ] Proof of concept (`poc/`)
- [ ] KRL distribution service
- [ ] Ansible role (`ansible/`)
- [ ] CI / build tooling (`.github/`, `docs/pdf/`)
- [ ] Other

## Checklist

- [ ] Docs updated (`docs/technical-reference.md` is the canonical Markdown
      source; no `.docx`) and `CHANGELOG.md` Unreleased section updated.
- [ ] PoC / tests pass locally (`cd poc && make test`).
- [ ] No secrets committed; only disposable lab values used; `gitleaks` clean.
- [ ] PDF builds locally (`docs/pdf/build.sh`) when docs changed.
- [ ] Markdown passes `markdownlint` and the link checker.
- [ ] Bash scripts use `#!/usr/bin/env bash` + `set -euo pipefail`; Python
      targets 3.11 and is managed with `uv`.

## CI checks that must pass

- [ ] **build-pdf**
- [ ] **docs lint + linkcheck**
- [ ] **gitleaks**
- [ ] **poc test**

## Notes for reviewers

Anything that needs special attention, or follow-ups left for later.
