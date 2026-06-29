# Example configuration

Sanitized, ready-to-adapt configuration lifted from the PoC. Every value here is
a **disposable lab example** — replace hostnames, IPs, and keys with your own.

| File | Where it goes | Purpose |
|---|---|---|
| `sshd_config.d/10-ssh-ca.conf` | `/etc/ssh/sshd_config.d/` on each server | Present a host certificate, trust the User CA, map principals to accounts, load the KRL |
| `auth_principals/{root,developer,deployer}` | `/etc/ssh/auth_principals/` on each server | Which certificate principals may log in as which local account (RBAC) |
| `ssh_config.d/10-ssh-ca.conf` | `~/.ssh/config` or `/etc/ssh/ssh_config.d/` | Client-side certificate usage |
| `known_hosts` | `~/.ssh/known_hosts` or `/etc/ssh/ssh_known_hosts` | `@cert-authority` line so clients trust the Host CA (eliminates TOFU) |
| `cosmian.toml` | `~/.cosmian/cosmian.toml` | Cosmian KMS client config (TLS/mTLS) for the CA operator |

See [`docs/technical-reference.md`](../docs/technical-reference.md) for the full
explanation of each directive, and [`poc/`](../poc/) for a one-command
environment that generates working versions of all of these.
