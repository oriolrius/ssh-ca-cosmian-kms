# SSH Certificate Authority — Proof of Concept

## Validation of the SSH CA Architecture with Cosmian KMS

**Scope:** This document defines a reproducible proof of concept that validates every component of the SSH Certificate Authority architecture described in the companion technical reference. The PoC uses three Docker containers — Cosmian KMS, an SSH server, and an SSH client/CA operator — on a dedicated network with fixed IPs. No `docker-compose`; every step is an explicit `docker` command with full rationale.

**Date:** April 2026
**Prerequisites:** Docker Engine ≥ 24.0, a Linux/macOS host with `ssh-keygen` available, internet access to pull images and packages.

> **About captured outputs:** throughout this document, blocks labelled _Captured output_ show the actual terminal output from a successful execution of this PoC (April 9 2026). They are included so you can confirm your output matches the expected shape. Key fingerprints, timestamps, and serial numbers will differ from yours — what matters is the structure: key type, certificate fields, log message format.

---

## 1. Use Cases Under Validation

| ID | Use Case | What It Proves |
|----|----------|----------------|
| UC1 | CA key lifecycle in Cosmian KMS | CA private key is generated and stored in the KMS; public key is exported for distribution. The key never exists as a file on the operator's machine. |
| UC2 | Host certificate signing and deployment | A server's Ed25519 host key is signed by the ECDSA CA. The signed certificate is installed on the server and presented during SSH handshake. |
| UC3 | Host certificate verification — TOFU elimination | The client connects to the server without ever seeing the TOFU prompt, because it trusts the Host CA via `@cert-authority` in `known_hosts`. |
| UC4 | User certificate authentication | A user's key is signed by the CA. The server accepts the certificate without any entry in `authorized_keys`, solely based on `TrustedUserCAKeys`. |
| UC5 | Principal-based access control (RBAC) | The server uses `AuthorizedPrincipalsFile` to map certificate principals to local accounts. A certificate with principal `admin` can log in as `root`; one with `developer` cannot. |
| UC6 | Extension restrictions — PTY denial | A certificate signed with `-O clear` (no `permit-pty`) allows command execution but denies interactive shell. Validates least-privilege enforcement baked into the certificate. |
| UC7 | force-command enforcement | A certificate with `-O force-command=/usr/bin/date` ignores the user's requested command and always executes `date`. |
| UC8 | Certificate expiry enforcement | A certificate with a 30-second validity window is accepted during the window and rejected after expiry. |
| UC9 | Key revocation via KRL | A previously valid certificate is revoked. The server rejects subsequent authentication attempts and logs the revocation. |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Docker Network: ssh-ca-lab                       │
│                    Subnet: 10.222.9.0/24                            │
│                                                                     │
│  ┌──────────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│  │  cosmian-kms      │  │  ssh-server  │  │  ssh-client           │  │
│  │  10.222.9.10      │  │  10.222.9.20 │  │  10.222.9.30          │  │
│  │                   │  │              │  │                       │  │
│  │  Cosmian KMS      │  │  Ubuntu 24.04│  │  Ubuntu 24.04         │  │
│  │  Port 9998        │  │  sshd :22    │  │  ssh client           │  │
│  │                   │  │              │  │  cosmian CLI          │  │
│  │  Stores:          │  │  Trusts:     │  │  Trusts:              │  │
│  │  - CA private key │  │  - User CA   │  │  - Host CA            │  │
│  │  - CA public key  │  │              │  │                       │  │
│  └──────────────────┘  │  Presents:   │  │  Presents:            │  │
│                         │  - Host cert │  │  - User cert          │  │
│                         └──────────────┘  └───────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

**Design decisions:**

- **Single CA key pair** for both host and user signing, matching Mens' blog setup. A production deployment would use separate CAs.
- **ECDSA nistp256** for the CA, consistent with Mens' usage and compatible with Cosmian KMS's PKCS#11 module.
- **Ed25519** for host and user end-entity keys (the keys being signed, not the CA).
- **Fixed IPs** so that host certificate principals and `@cert-authority` patterns are deterministic across runs.

---

## 3. Step 0 — Create the Docker Network

The dedicated bridge network provides DNS isolation and fixed IP assignment.

```bash
docker network create \
  --driver bridge \
  --subnet 10.222.9.0/24 \
  --gateway 10.222.9.1 \
  ssh-ca-lab
```

**Why a dedicated network:** default Docker bridge networks assign IPs dynamically. Since host certificates encode principals that include IP addresses, we need deterministic addressing. A user-defined bridge also provides automatic container-name DNS resolution within the network.

**Verify:**

```bash
docker network inspect ssh-ca-lab --format '{{.IPAM.Config}}'
```

_Captured output:_
```
[{10.222.9.0/24  10.222.9.1 map[]}]
```

```bash
```

---

## 4. Step 1 — Deploy Cosmian KMS

Cosmian KMS stores the SSH CA private key. In this PoC it runs in-memory (SQLite inside the container). The CA key is generated and managed exclusively through the KMS.

```bash
docker run -d \
  --name cosmian-kms \
  --network ssh-ca-lab \
  --ip 10.222.9.10 \
  -p 9998:9998 \
  ghcr.io/cosmian/kms
```

**Why we expose port 9998:** the `cosmian` CLI on the client container (and on the host, for initial setup) connects to the KMS API on this port. In production, this would be TLS-protected with client certificate authentication.

**Verify the KMS is running:**

```bash
# From the host, check the server version:
curl -s http://localhost:9998/version
```

_Captured output:_
```
"5.20.0 (OpenSSL 3.6.0 1 Oct 2025-non-FIPS)"
```

---

## 5. Step 2 — Deploy the SSH Server

This container runs `sshd` and will be configured to trust the CA for both host certificate presentation and user certificate validation.

```bash
docker run -d \
  --name ssh-server \
  --network ssh-ca-lab \
  --ip 10.222.9.20 \
  --hostname server.lab.local \
  ubuntu:24.04 \
  sleep infinity
```

**Why `sleep infinity`:** we start with a bare container and install/configure `sshd` manually, step by step, so every configuration change is explicit and auditable. This is deliberate — in a PoC document, a pre-baked image hides the exact configuration being validated.

**Install and configure sshd:**

```bash
docker exec ssh-server bash -c '
  apt-get update -qq && \
  apt-get install -y -qq openssh-server rsyslog > /dev/null 2>&1 && \
  mkdir -p /run/sshd && \
  echo "root:rootpass" | chpasswd && \
  useradd -m -s /bin/bash developer && \
  useradd -m -s /bin/bash deployer
'
```

> **Note on auth logging:** Ubuntu 24.04 containers do not run systemd/journald. Install `rsyslog` so that sshd auth events (with certificate Key ID and serial) are written to `/var/log/auth.log`. The `imklog` error about `/proc/kmsg` is harmless — rsyslog still works for syslog facilities.

**Enable root login and password auth for bootstrapping** — Ubuntu 24.04 defaults to `PermitRootLogin prohibit-password`:

```bash
docker exec ssh-server bash -c '
  cat >> /etc/ssh/sshd_config << EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF
'
```

**Start sshd and rsyslog:**

```bash
docker exec ssh-server bash -c '
  rsyslogd && /usr/sbin/sshd
'
```

**Verify sshd is listening:**

```bash
docker exec ssh-server cat /proc/net/tcp | grep " 0016 "
# 0016 hex = port 22
```

_Captured output (one line per listening socket — you will see 0.0.0.0:22 and [::]:22):_
```
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 ...
```

---

## 6. Step 3 — Deploy the SSH Client / CA Operator

This container acts as both the SSH client and the CA operator (the entity that signs certificates). It needs the `cosmian` CLI to interact with the KMS, and `ssh-keygen` for certificate operations.

```bash
docker run -d \
  --name ssh-client \
  --network ssh-ca-lab \
  --ip 10.222.9.30 \
  --hostname client.lab.local \
  ubuntu:24.04 \
  sleep infinity
```

**Install SSH client and the Cosmian CLI:**

```bash
docker exec ssh-client bash -c '
  apt-get update -qq && \
  apt-get install -y -qq openssh-client wget > /dev/null 2>&1
'
```

Install the Cosmian CLI (`cosmian` binary) — copy from the host where it is already installed:

```bash
docker cp /usr/local/bin/cosmian ssh-client:/usr/local/bin/cosmian
```

> **Note:** The binary (`cosmian_cli 1.9.0`) is a dynamically linked x86-64 ELF that runs on Ubuntu 24.04. It was installed on the host from the ubuntu_22_04-release zip — see README.md for installation details.

**Configure the CLI to connect to the KMS:**

```bash
docker exec ssh-client bash -c '
  mkdir -p /root/.cosmian && \
  cat > /root/.cosmian/cosmian.toml << EOF
[kms_config.http_config]
server_url = "http://10.222.9.10:9998"
EOF
'
```

**Why HTTP, not HTTPS:** this is a PoC on an isolated Docker network. Production deployments must use TLS with client certificate authentication (mTLS) as described in the Cosmian documentation.

**Verify connectivity to the KMS:**

```bash
docker exec ssh-client cosmian kms server-version
```

_Captured output:_
```
5.20.0 (OpenSSL 3.6.0 1 Oct 2025-non-FIPS)
```

---

## 7. UC1 — CA Key Lifecycle in Cosmian KMS

Generate the ECDSA nistp256 CA key pair inside the KMS. The private key never leaves the KMS boundary.

### 7.1 Generate the CA Key Pair

```bash
docker exec ssh-client cosmian kms ec keys create \
  --curve nist-p256 \
  --tag ssh-ca \
  --tag poc \
  ssh-ca-key
```

_Captured output:_
```
The EC key pair has been created.
	  Public key unique identifier: ssh-ca-key_pk
	  Private key unique identifier: ssh-ca-key

  Tags:
    - ssh-ca
    - poc
```

**What happened:** the KMS generated an ECDSA P-256 key pair internally. The private key `ssh-ca-key` exists only inside the KMS database. The public key `ssh-ca-key_pk` can be exported.

### 7.2 Export CA Keys (PoC Only)

The cosmian CLI cannot export EC public keys in a format ssh-keygen understands directly. The working approach is: export the private key as PKCS#8 PEM, convert it to OpenSSH format, then derive the public key from it.

```bash
# Export private key for local signing (PoC ONLY) — correct format is pkcs8-pem
docker exec ssh-client cosmian kms ec keys export \
  --key-id ssh-ca-key \
  --key-format pkcs8-pem \
  /poc/ca_priv.pem

# Convert PKCS#8 PEM → OpenSSH private key format (in-place, no passphrase)
docker exec ssh-client bash -c '
  cp /poc/ca_priv.pem /poc/ssh-ca && \
  chmod 600 /poc/ssh-ca && \
  ssh-keygen -p -N "" -f /poc/ssh-ca
'

# Derive the SSH public key from the private key
docker exec ssh-client bash -c 'ssh-keygen -y -f /poc/ssh-ca > /poc/ssh-ca.pub'
```

_Captured output of the export step:_
```
The key ssh-ca-key of type PrivateKey was exported to "/poc/ca_priv.pem"
	  Unique identifier: ssh-ca-key
```

_Captured output of the ssh-keygen conversion:_
```
Your identification has been saved with the new passphrase.
```

**Verify the key type:**

```bash
docker exec ssh-client cat /poc/ssh-ca.pub
```

_Captured output (your key material will differ):_
```
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMts4gbYPquWDtJg/SvrYl/drWVh8UkpaM0h6sHZadgtm3ZDMplAVP2ECXxv7tgEYIhMhAwalOEfVn8CorxKNE4=
```

> **Production note:** In the production architecture, the CA private key stays inside Cosmian KMS. Signing happens via:
> 1. `ssh-add -s /usr/local/lib/libcosmian_pkcs11.so` (loads KMS key into ssh-agent via PKCS#11)
> 2. `ssh-keygen` or Ansible's `community.crypto.openssh_cert` with `use_agent: true`
>
> The export step above exists solely because configuring the Cosmian PKCS#11 provider inside a Docker container adds complexity that would obscure the SSH CA concepts being validated.

### 7.3 Validation Checkpoint — UC1

```bash
docker exec ssh-client ssh-keygen -l -f /poc/ssh-ca
```

_Captured output:_
```
256 SHA256:WNSimaLM9xA8fiMAf86KxdEgo/5V1TIrwWtxPTrUHq4 /poc/ssh-ca.pub (ECDSA)
```

✅ **UC1 validated:** CA key pair generated in Cosmian KMS, public key exported in SSH format, ready for distribution.

---

## 8. UC2 — Host Certificate Signing and Deployment

Sign the SSH server's host key with the CA. This is the server-side half of TOFU elimination.

### 8.1 Retrieve the Server's Host Public Key

With bind mounts in place, files can be exchanged directly on the host filesystem. The server's `/etc/ssh` is mounted at `poc-data/ssh-server/etc-ssh` and the client's working directory is mounted at `poc-data/ssh-client/tmp`.

```bash
cp poc-data/ssh-server/etc-ssh/ssh_host_ed25519_key.pub poc-data/ssh-client/tmp/host_key.pub
```

**What we're doing:** copying the server's Ed25519 public host key to the client/CA-operator working area for signing. Only the public key is copied — the private key stays on the server.

### 8.2 Sign the Host Key

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "server.lab.local-2026" \
  -h \
  -n server.lab.local,10.222.9.20 \
  -V +52w \
  -z 1001 \
  /poc/host_key.pub
```

**Flag breakdown:**

| Flag | Value | Purpose |
|------|-------|---------|
| `-s` | `/poc/ssh-ca` | CA private key used for signing |
| `-I` | `"server.lab.local-2026"` | Key ID — logged by sshd on every connection for audit |
| `-h` | — | Sign as **host** certificate (type=2), not user |
| `-n` | `server.lab.local,10.222.9.20` | Principals: hostnames/IPs the cert is valid for |
| `-V` | `+52w` | Valid for 52 weeks from now |
| `-z` | `1001` | Serial number for revocation tracking |

_Captured output of signing command:_
```
Signed host key /poc/host_key-cert.pub: id "server.lab.local-2026" serial 1001 for server.lab.local,10.222.9.20 valid from 2026-04-09T11:44:00 to 2027-04-08T11:45:12
```

**Inspect the signed certificate:**

```bash
docker exec ssh-client ssh-keygen -L -f /poc/host_key-cert.pub
```

_Captured output:_
```
/poc/host_key-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com host certificate
        Public key: ED25519-CERT SHA256:qV4FI+pkwGeI4/rVeGYa6HOZL57zhdE4WHosXakpvSY
        Signing CA: ECDSA SHA256:WNSimaLM9xA8fiMAf86KxdEgo/5V1TIrwWtxPTrUHq4 (using ecdsa-sha2-nistp256)
        Key ID: "server.lab.local-2026"
        Serial: 1001
        Valid: from 2026-04-09T11:44:00 to 2027-04-08T11:45:12
        Principals:
                server.lab.local
                10.222.9.20
        Critical Options: (none)
        Extensions: (none)
```

Note `Extensions: (none)` — host certificates intentionally carry no extensions; extensions are a user certificate concept.

### 8.3 Deploy the Certificate to the Server

Via bind mounts on the host:

```bash
# Deploy host certificate
cp poc-data/ssh-client/tmp/host_key-cert.pub \
   poc-data/ssh-server/etc-ssh/ssh_host_ed25519_key-cert.pub

# Deploy CA public key (for TrustedUserCAKeys)
cp poc-data/ssh-client/tmp/ssh-ca.pub \
   poc-data/ssh-server/etc-ssh/ssh-ca.pub
```

### 8.4 Configure sshd to Present the Host Certificate and Trust the User CA

```bash
docker exec ssh-server bash -c '
  chmod 644 /etc/ssh/ssh_host_ed25519_key-cert.pub
  chmod 644 /etc/ssh/ssh-ca.pub

  cat >> /etc/ssh/sshd_config << EOF

# --- SSH CA Configuration ---
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
TrustedUserCAKeys /etc/ssh/ssh-ca.pub
EOF

  # Validate config before restart
  sshd -t && echo "sshd config OK" || echo "sshd config FAILED"
'
```

**Fix `/etc/ssh` ownership** — the bind-mounted directory is owned by the host user, not root. sshd refuses to read `AuthorizedPrincipalsFile` if any directory in the path has bad ownership:

```bash
docker exec ssh-server bash -c 'chown root:root /etc/ssh && chmod 755 /etc/ssh'
```

**Restart sshd:**

```bash
docker exec ssh-server bash -c 'kill $(pgrep -x sshd) && /usr/sbin/sshd'
```

✅ **UC2 validated:** host key signed by CA, certificate deployed, sshd configured to present it.

---

## 9. UC3 — Host Certificate Verification (TOFU Elimination)

### 9.1 Configure the Client to Trust the Host CA

```bash
docker exec ssh-client bash -c '
  mkdir -p /root/.ssh
  echo "@cert-authority *.lab.local,10.222.9.* $(cat /poc/ssh-ca.pub)" \
    > /root/.ssh/known_hosts
  chmod 600 /root/.ssh/known_hosts
'
```

**Why the pattern includes both `*.lab.local` and `10.222.9.*`:** the client might connect by hostname or by IP. The pattern must match both, otherwise the certificate is rejected and the TOFU prompt appears.

### 9.2 Test — Connect by IP (No TOFU)

First, we need a user key to authenticate. For now, use password auth to prove the host cert works:

```bash
docker exec ssh-client bash -c '
  sshpass -p rootpass ssh \
    -o StrictHostKeyChecking=yes \
    -o PasswordAuthentication=yes \
    -l root 10.222.9.20 \
    hostname
'
```

> **Note:** Install `sshpass` first if needed: `docker exec ssh-client apt-get install -y -qq sshpass`

**What to observe:** there is **no TOFU prompt**. With `StrictHostKeyChecking=yes`, the connection would fail if the host certificate were not validated. The fact that it succeeds proves the client verified the host certificate against the `@cert-authority` entry.

_Captured output (connection returns hostname with no prompt):_
```
server.lab.local
```

### 9.3 Test — Verbose Output Shows Certificate Verification

```bash
docker exec ssh-client bash -c '
  sshpass -p rootpass ssh -v \
    -o StrictHostKeyChecking=yes \
    -l root 10.222.9.20 \
    hostname 2>&1 | grep -i cert
'
```

_Captured output (key lines — fingerprints will differ):_
```
debug1: kex: host key algorithm: ssh-ed25519-cert-v01@openssh.com
debug1: Server host certificate: ssh-ed25519-cert-v01@openssh.com SHA256:qV4FI+pkwGeI4/rVeGYa6HOZL57zhdE4WHosXakpvSY, serial 1001 ID "server.lab.local-2026" CA ecdsa-sha2-nistp256 SHA256:WNSimaLM9xA8fiMAf86KxdEgo/5V1TIrwWtxPTrUHq4 valid from 2026-04-09T11:44:00 to 2027-04-08T11:45:12
debug1: Host '10.222.9.20' is known and matches the ED25519-CERT host certificate.
```

The critical line is the last one: `is known and matches the ED25519-CERT host certificate` — this is the SSH client confirming the `@cert-authority` lookup succeeded.

✅ **UC3 validated:** client connected without TOFU prompt, host identity verified via CA-signed certificate.

---

## 10. UC4 — User Certificate Authentication

### 10.1 Generate a User Key Pair on the Client

```bash
docker exec ssh-client bash -c '
  ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "jane@lab"
'
```

_Captured output:_
```
Generating public/private ed25519 key pair.
Your identification has been saved in /root/.ssh/id_ed25519
Your public key has been saved in /root/.ssh/id_ed25519.pub
The key fingerprint is:
SHA256:LPMDuEuPzsTjU25zLbrFgZw/mb3kQbtFQeMKzwK06VU jane@lab
```

### 10.2 Sign the User Key with the CA

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie" \
  -n root \
  -V +1w \
  -z 1 \
  /root/.ssh/id_ed25519.pub
```

_Captured output:_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie" serial 1 for root valid from 2026-04-09T11:45:00 to 2026-04-16T11:46:14
```

**This produces** `/root/.ssh/id_ed25519-cert.pub` — placed adjacent to the private key, so SSH auto-discovers it.

**Inspect:**

```bash
docker exec ssh-client ssh-keygen -L -f /root/.ssh/id_ed25519-cert.pub
```

_Captured output:_
```
/root/.ssh/id_ed25519-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Public key: ED25519-CERT SHA256:LPMDuEuPzsTjU25zLbrFgZw/mb3kQbtFQeMKzwK06VU
        Signing CA: ECDSA SHA256:WNSimaLM9xA8fiMAf86KxdEgo/5V1TIrwWtxPTrUHq4 (using ecdsa-sha2-nistp256)
        Key ID: "Jane Jolie"
        Serial: 1
        Valid: from 2026-04-09T11:45:00 to 2026-04-16T11:46:14
        Principals:
                root
        Critical Options: (none)
        Extensions:
                permit-X11-forwarding
                permit-agent-forwarding
                permit-port-forwarding
                permit-pty
                permit-user-rc
```

Contrast with the host certificate: user certificates carry extensions (capabilities granted to the user). All five default extensions are present here because no `-O clear` was specified.

### 10.3 Connect Using the Certificate (No authorized_keys)

```bash
docker exec ssh-client ssh \
  -o StrictHostKeyChecking=yes \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  hostname
```

_Captured output:_
```
server.lab.local
```

**What to observe:** the connection succeeds using certificate authentication. There is no entry for this user's public key in `/root/.ssh/authorized_keys` on the server. The server accepted the certificate because:
1. It is signed by a CA listed in `TrustedUserCAKeys`
2. The principal `root` matches the login username

**Verify on the server log:**

```bash
docker exec ssh-server grep "Accepted" /var/log/auth.log | tail -1
```

_Captured output:_
```
2026-04-09T11:46:59.775434+00:00 server sshd[4611]: Accepted publickey for root from 10.222.9.30 port 47028 ssh2: ED25519-CERT SHA256:LPMDuEuPzsTjU25zLbrFgZw/mb3kQbtFQeMKzwK06VU ID Jane Jolie (serial 1) CA ECDSA SHA256:WNSimaLM9xA8fiMAf86KxdEgo/5V1TIrwWtxPTrUHq4
```

The audit trail contains: login account (`root`), source IP, certificate fingerprint, **Key ID** (`Jane Jolie`), **serial** (`1`), and CA fingerprint. The Key ID is the forensic anchor — it ties this session to a named human even though they logged in as a shared account.

✅ **UC4 validated:** user authenticated via CA-signed certificate, no authorized_keys entry needed. Audit log shows Key ID and serial.

---

## 11. UC5 — Principal-Based Access Control (RBAC)

### 11.1 Configure AuthorizedPrincipalsFile on the Server

```bash
docker exec ssh-server bash -c '
  # Add AuthorizedPrincipalsFile to sshd_config
  echo "AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u" \
    >> /etc/ssh/sshd_config

  # Create principal mappings
  mkdir -p /etc/ssh/auth_principals

  # root: accessible by "admin", "root-everywhere", and "root" principals
  # "root" is included so that subsequent UCs (UC6–UC9) can sign with -n root
  echo -e "admin\nroot-everywhere\nroot" > /etc/ssh/auth_principals/root

  # developer: accessible by "developer" and "dev-team" principals
  echo -e "developer\ndev-team" > /etc/ssh/auth_principals/developer

  # deployer: accessible by "deployer" principal only
  echo "deployer" > /etc/ssh/auth_principals/deployer

  # Validate and restart sshd
  sshd -t && kill $(pgrep -x sshd) && /usr/sbin/sshd
'
```

### 11.2 Sign a Certificate with the "admin" Principal

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie - Admin" \
  -n admin \
  -V +1w \
  -z 2 \
  /root/.ssh/id_ed25519.pub
```

_Captured output:_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie - Admin" serial 2 for admin valid from 2026-04-09T11:47:00 to 2026-04-16T11:48:34
```

### 11.3 Test — "admin" Can Log In as root

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  whoami
```

_Captured output:_
```
root
```

**Why this works:** the certificate has principal `admin`. The file `/etc/ssh/auth_principals/root` contains `admin`. Therefore, this certificate can log in as `root`.

### 11.4 Test — "admin" Cannot Log In as developer

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -o BatchMode=yes \
  -l developer 10.222.9.20 \
  whoami 2>&1
```

_Captured output:_
```
developer@10.222.9.20: Permission denied (publickey,password).
```

**Why this fails:** `/etc/ssh/auth_principals/developer` contains `developer` and `dev-team`, but not `admin`. The certificate's principal does not match any entry for the `developer` account.

### 11.5 Test — Re-sign with "developer" Principal and Access the Developer Account

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie - Developer" \
  -n developer \
  -V +1w \
  -z 3 \
  /root/.ssh/id_ed25519.pub

docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -l developer 10.222.9.20 \
  whoami
```

_Captured output:_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie - Developer" serial 3 for developer valid from 2026-04-09T11:48:00 to 2026-04-16T11:49:14
developer
```

✅ **UC5 validated:** principal-based access control works. The same key with different principals grants access to different accounts. This is RBAC via certificate metadata.

---

## 12. UC6 — Extension Restrictions (PTY Denial)

### 12.1 Sign with `-O clear` (No Extensions)

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie - Restricted" \
  -n root \
  -V +1w \
  -z 4 \
  -O clear \
  -O extension:permit-agent-forwarding \
  /root/.ssh/id_ed25519.pub
```

**What `-O clear` does:** removes ALL default extensions. Then we add back only `permit-agent-forwarding`. Notably, `permit-pty` is NOT added.

_Captured output of signing command:_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie - Restricted" serial 4 for root valid from 2026-04-09T11:48:00 to 2026-04-16T11:49:28
```

**Inspect the certificate to confirm:**

```bash
docker exec ssh-client ssh-keygen -L -f /root/.ssh/id_ed25519-cert.pub | grep -A5 Extensions
```

_Captured output (only one extension, no permit-pty):_
```
        Extensions:
                permit-agent-forwarding
```

### 12.2 Test — Command Execution Works

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  uname -a
```

_Captured output:_
```
Linux server.lab.local 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun  5 18:30:46 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
```

### 12.3 Test — Interactive Shell Fails

```bash
docker exec -t ssh-client ssh \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  2>&1 | head -1
```

_Captured output:_
```
PTY allocation request failed on channel 0
```

✅ **UC6 validated:** the certificate controls what the user can do. No `permit-pty` = no interactive shell. This is Mens' exact demonstration from his blog.

---

## 13. UC7 — force-command Enforcement

### 13.1 Sign with force-command

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie - Forced Date" \
  -n root \
  -V +1w \
  -z 5 \
  -O force-command=/usr/bin/date \
  /root/.ssh/id_ed25519.pub
```

_Captured output of signing command:_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie - Forced Date" serial 5 for root valid from 2026-04-09T11:49:00 to 2026-04-16T11:50:11
```

### 13.2 Test — User Requests `uname`, Gets `date`

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  uname
```

_Captured output (output of `/usr/bin/date`, not `uname`):_
```
Thu Apr  9 11:50:11 UTC 2026
```

**What happened:** the server ignores the user's requested command (`uname`) and executes the command embedded in the certificate (`/usr/bin/date`). The user has no way to override this — the enforcement is in the certificate's critical options, verified cryptographically by sshd.

✅ **UC7 validated:** force-command is enforced regardless of what the client requests.

---

## 14. UC8 — Certificate Expiry Enforcement

### 14.1 Sign a Certificate That Expires in 30 Seconds

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie - Short-Lived" \
  -n root \
  -V +30s \
  -z 6 \
  /root/.ssh/id_ed25519.pub
```

_Captured output (note the narrow validity window):_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie - Short-Lived" serial 6 for root valid from 2026-04-09T11:49:00 to 2026-04-09T11:50:45
```

### 14.2 Test — Immediate Connection Succeeds

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  echo "Access granted at $(date)"
```

_Captured output:_
```
Access granted at Thu Apr  9 01:50:15 PM CEST 2026
```

### 14.3 Test — After 35 Seconds, Connection Fails

```bash
echo "Waiting 35 seconds for certificate to expire..."
sleep 35

docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -o BatchMode=yes \
  -l root 10.222.9.20 \
  echo "Should not see this" 2>&1
```

_Captured output:_
```
root@10.222.9.20: Permission denied (publickey,password).
```

**Check the server log for the expiry diagnosis:**

```bash
docker exec ssh-server grep "expired" /var/log/auth.log | tail -1
```

_Captured output:_
```
2026-04-09T11:51:00.489972+00:00 server sshd[4757]: error: Certificate invalid: expired
```

✅ **UC8 validated:** certificates expire and are rejected after their validity window. No server-side action needed — the expiry is enforced by sshd based on the certificate's `valid_before` timestamp.

---

## 15. UC9 — Key Revocation via KRL

### 15.1 Sign a Fresh Certificate

```bash
docker exec ssh-client ssh-keygen \
  -s /poc/ssh-ca \
  -I "Jane Jolie - To Be Revoked" \
  -n root \
  -V +1w \
  -z 7 \
  /root/.ssh/id_ed25519.pub
```

_Captured output:_
```
Signed user key /root/.ssh/id_ed25519-cert.pub: id "Jane Jolie - To Be Revoked" serial 7 for root valid from 2026-04-09T11:50:00 to 2026-04-16T11:51:08
```

**Verify it works before revocation:**

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -l root 10.222.9.20 \
  echo "Pre-revocation: access OK"
```

_Captured output:_
```
Pre-revocation: access OK
```

### 15.2 Create a KRL Revoking the User's Key

```bash
# Copy user public key to the server via bind mounts (requires sudo due to /etc/ssh ownership)
sudo cp poc-data/ssh-client/root-ssh/id_ed25519.pub \
        poc-data/ssh-server/etc-ssh/revoke_this.pub

docker exec ssh-server bash -c '
  # Create a KRL revoking this specific key
  ssh-keygen -k -f /etc/ssh/revoked_keys /etc/ssh/revoke_this.pub

  # Configure sshd to check the KRL
  echo "RevokedKeys /etc/ssh/revoked_keys" >> /etc/ssh/sshd_config

  # Validate and restart
  sshd -t && kill $(pgrep -x sshd) && /usr/sbin/sshd
'
```

_Captured output of KRL creation:_
```
Revoking from /etc/ssh/revoke_this.pub
```

### 15.3 Test — Connection Now Fails

```bash
docker exec ssh-client ssh \
  -o PasswordAuthentication=no \
  -o BatchMode=yes \
  -l root 10.222.9.20 \
  echo "Should not see this" 2>&1
```

_Captured output:_
```
root@10.222.9.20: Permission denied (publickey,password).
```

**Check the server log for the revocation message:**

```bash
docker exec ssh-server grep "revoked" /var/log/auth.log | tail -2
```

_Captured output (both the raw key and the certificate are flagged):_
```
2026-04-09T11:51:28.928696+00:00 server sshd[4795]: error: Authentication key ED25519 SHA256:LPMDuEuPzsTjU25zLbrFgZw/mb3kQbtFQeMKzwK06VU revoked by file /etc/ssh/revoked_keys
2026-04-09T11:51:28.928696+00:00 server sshd[4795]: error: Authentication key ED25519-CERT SHA256:LPMDuEuPzsTjU25zLbrFgZw/mb3kQbtFQeMKzwK06VU revoked by file /etc/ssh/revoked_keys
```

Note that sshd logs two revocation entries for the same key — one for the bare public key (`ED25519`) and one for the certificate (`ED25519-CERT`). The KRL matches on the underlying public key material, so both are rejected.

✅ **UC9 validated:** KRL-based revocation works. A previously valid certificate is now rejected, and the revocation is logged with the specific key fingerprint and KRL file path.

---

## 16. Cleanup

Remove all PoC resources:

```bash
docker stop ssh-client ssh-server cosmian-kms
docker rm ssh-client ssh-server cosmian-kms
docker network rm ssh-ca-lab

# Remove bind-mounted data directories (contains CA keys, host keys, KMS database)
sudo rm -rf poc-data/
```

---

## 17. Results Summary

| UC | Description | Result | Evidence |
|----|-------------|--------|----------|
| UC1 | CA key lifecycle in Cosmian KMS | ✅ | Key generated via `cosmian kms ec keys create`, pubkey exported in SSH format |
| UC2 | Host certificate signing | ✅ | `ssh-keygen -L` shows host cert signed by ECDSA CA with correct principals |
| UC3 | TOFU elimination | ✅ | Connection with `StrictHostKeyChecking=yes` succeeds without prompt |
| UC4 | User certificate auth | ✅ | Login succeeds without authorized_keys; sshd logs Key ID and serial |
| UC5 | Principal-based RBAC | ✅ | `admin` principal → root access; same cert → developer denied |
| UC6 | PTY denial via extensions | ✅ | Command execution works; interactive shell → "PTY allocation request failed" |
| UC7 | force-command | ✅ | User requests `uname`, server executes `date` |
| UC8 | Certificate expiry | ✅ | Access within 30s window; rejected after expiry with "Certificate invalid: expired" |
| UC9 | KRL revocation | ✅ | Previously valid cert rejected; sshd logs "revoked by file" |

---

## 18. What This PoC Does NOT Cover (Production Gaps)

1. **PKCS#11 signing path.** The PoC exports the CA private key from Cosmian KMS for local signing. Production must use `ssh-add -s /usr/local/lib/libcosmian_pkcs11.so` so the private key never leaves the KMS. See Section 10.5 of the technical reference.

2. **Separate User and Host CAs.** The PoC uses a single CA for simplicity (matching Mens' blog). Production should maintain two CAs with distinct trust scopes.

3. **TLS/mTLS for KMS access.** The PoC connects to Cosmian KMS over plaintext HTTP. Production requires TLS with client certificate authentication (`ssl_client_pkcs12_path` in `cosmian.toml`).

4. **Ansible automation.** The PoC performs every step manually to make the mechanics visible. Mens' Ansible playbook (documented in the technical reference, Section 10.2) automates the host key generation → signing → deployment cycle.

5. **KRL distribution.** The PoC creates a KRL on a single server. Production requires distributing KRL updates across all servers, typically via configuration management (Ansible, Puppet, etc.).

6. **NTP synchronisation.** Certificate validity depends on clock accuracy. The PoC containers share the host's clock. Production environments must run NTP on all hosts.
