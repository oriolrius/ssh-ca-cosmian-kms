---
name: Bug report
about: Report a defect in the docs, the PoC, the KRL service, the Ansible role, or the tooling
title: "[Bug]: "
labels: [bug, triage]
---

<!--
Do NOT report security vulnerabilities here. Report them privately via the
Security tab (Report a vulnerability). See SECURITY.md.
All keys, fingerprints, hostnames and IPs in this repo are disposable lab
values — please keep any real secrets out of this issue.
-->

## What happened

A clear and concise description of the bug.

## Where

Which part of the project is affected?

- [ ] Documentation (`docs/`)
- [ ] Proof of concept (`poc/`)
- [ ] KRL distribution service
- [ ] Ansible role (`ansible/`)
- [ ] CI / build tooling (`.github/`, `docs/pdf/`)
- [ ] Other (describe below)

Affected file(s) or path(s):

## Steps to reproduce

1. ...
2. ...
3. ...

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened. Include relevant `sshd` log lines, command output, or
error messages (redact anything that is not a disposable lab value).

```text
<logs / output here>
```

## Environment

- OS / distro:
- Docker version (for PoC issues):
- `cosmian --version`:
- OpenSSH version (`ssh -V`):
- Commit / ref:

## Additional context

Anything else that helps us understand the problem.
