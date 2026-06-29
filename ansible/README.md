# Ansible: SSH host certificates (dual-CA + Cosmian KMS)

A runnable, production-ready Ansible automation of the **host-certificate
workflow** described in
[`../docs/technical-reference.md` section 10 ("Automation")](../docs/technical-reference.md).
It implements Jan-Piet Mens' pattern and extends it for this repository's
**dual-CA** ([User CA / Host CA](../docs/technical-reference.md) with separate
keys) and **Cosmian KMS** (CA key held in the KMS, used over PKCS#11) setup.

## What it does

For every host in the `[sshservers]` inventory group, the `ssh_host_cert` role:

1. **Generates an Ed25519 host key _on the node_** with
   `community.crypto.openssh_keypair` (`backend: opensshbin`). The **private key
   never leaves the node** — not even to the controller (technical-reference
   §10.3.1).
2. In a `block`/`always` with a controller tempdir:
   - copies **only the public key** to the controller,
   - **signs it on the controller** with `community.crypto.openssh_cert`
     (`type: host`, `use_agent: true`) — the **Host CA in ssh-agent** does the
     signing, so the CA private key never touches disk (§10.3.2, §10.5.2),
   - pushes the signed certificate back to the node (`mode: 0444`),
   - the `always` block removes the tempdir even if signing fails (§10.3.3).
3. Configures `sshd` via `blockinfile` — `HostKey`, `HostCertificate`, and
   `TrustedUserCAKeys` (the **User CA** public key) — validated with `sshd -t`
   before any change is accepted, and restarts `sshd` via a handler only when
   something changed (§10.4).

The principals on the host certificate are
`{{ [ansible_fqdn] + ansible_all_ipv4_addresses }}`, so clients match whether
they connect by name or by IP (§10.3.4).

## Prerequisites

### On the controller

1. **Ansible + the `community.crypto` collection**

   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```

2. **Load the Host CA into ssh-agent from Cosmian KMS.** The role signs with
   `use_agent: true`, so the Host CA private key must be reachable through the
   agent. Load it via the Cosmian PKCS#11 provider — the key never leaves the
   KMS and never lands on disk:

   ```bash
   # start an agent if you don't already have one
   eval "$(ssh-agent -s)"

   # load all KMS-held keys into the agent via the PKCS#11 provider
   ssh-add -s /usr/local/lib/libcosmian_pkcs11.so

   # verify the Host CA key is present (ECDSA nistp256)
   ssh-add -l
   #   256 SHA256:A5ZB... Cosmian-KMS (ECDSA)
   ```

   The KMS connection is configured in `~/.cosmian/cosmian.toml`:

   ```toml
   [kms_config.http_config]
   server_url = "https://10.222.9.10:9998"
   ssl_client_pkcs12_path = "./certificates/controller.p12"
   ssl_client_pkcs12_password = "p12_password"
   ```

   The Host CA object is tagged `ssh-host-ca` in the KMS (the User CA is tagged
   `ssh-user-ca`).

3. **Stage the public keys** referenced by the role defaults:
   - `files/ssh-host-ca.pub` — the Host CA **public** key, passed to
     `openssh_cert` as `signing_key` while `use_agent: true` supplies the
     matching private half from the agent. Export it once from the KMS, e.g.:

     ```bash
     mkdir -p files
     ssh-add -L | grep 'Cosmian' > files/ssh-host-ca.pub   # or export from KMS
     ```

   - the **User CA** public key on each node at the path
     `ssh_host_cert_user_ca_pub` (default `/etc/ssh/ssh-user-ca.pub`), so
     `TrustedUserCAKeys` can point at it.

### On the nodes

- An account the controller can reach (`ansible_user`) that can `become: true`
  (sudo) to write `/etc/ssh` and restart `sshd`.
- Python 3.11+ (Ubuntu 24.04 ships it).

## Usage

```bash
# 1. install the collection
ansible-galaxy collection install -r requirements.yml

# 2. create your inventory from the example
cp inventory.ini.example inventory.ini
$EDITOR inventory.ini

# 3. load the Host CA from Cosmian KMS into ssh-agent (see Prerequisites)
ssh-add -s /usr/local/lib/libcosmian_pkcs11.so

# 4. syntax-check, then run
ansible-playbook -i inventory.ini site.yml --syntax-check
ansible-playbook -i inventory.ini site.yml
```

Useful overrides (per host/group in inventory or `group_vars/`):

| Variable | Default | Purpose |
|---|---|---|
| `ssh_host_cert_serial` | `10` | Monotonic serial for audit / KRL ranges |
| `ssh_host_cert_valid_to` | `+53w` | Certificate validity window |
| `ssh_host_cert_ca_signing_key` | `{{ playbook_dir }}/files/ssh-host-ca.pub` | Host CA public key (signer via agent) |
| `ssh_host_cert_user_ca_pub` | `/etc/ssh/ssh-user-ca.pub` | User CA pub on the node (`TrustedUserCAKeys`) |
| `ssh_host_cert_pkcs11_provider` | `/usr/local/lib/libcosmian_pkcs11.so` | Cosmian PKCS#11 provider (for `ssh-add -s`) |
| `ssh_host_cert_sshd_service` | `ssh` | sshd service unit name |

## Mapping to the technical reference

| Reference (§) | Where it is implemented |
|---|---|
| §10.3.1 key generated on the node | `tasks/main.yml` Phase 1 (`openssh_keypair`, `opensshbin`) |
| §10.3.2 `use_agent: true` | `openssh_cert` task + `ssh_host_cert_use_agent` |
| §10.3.3 `block`/`always` tempdir cleanup | `tasks/main.yml` Phase 2-4 block / always |
| §10.3.4 principals = FQDN + IPv4s | `ssh_host_cert_principals` default |
| §10.4 sshd config + restart handler | `blockinfile` (with `sshd -t` validate) + `handlers/main.yml` |
| §10.5.2 CA in KMS via ssh-agent | `ssh-add -s libcosmian_pkcs11.so` (Prerequisites) |

## Quality gates

This automation is kept green against:

```bash
ansible-playbook -i inventory.ini.example site.yml --syntax-check
ansible-lint
```

## License

[MIT](../LICENSE) © 2026 Oriol Rius.
