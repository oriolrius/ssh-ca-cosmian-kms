# KRL Distributor

A reference implementation of the encrypted, stateless **SSH Key Revocation
List (KRL) distribution service** designed in
[`docs/krl-distribution.md`](../../docs/krl-distribution.md).

It is a tiny FastAPI app that delivers a per-host, end-to-end **encrypted** KRL.
The service itself **holds no secrets**: every cryptographic operation is
delegated to **Cosmian KMS** through the `cosmian` CLI.

## What it is

| Piece | Role |
|---|---|
| `app.py` | FastAPI service exposing `POST /krl` and `GET /healthz`. |
| `host_puller.sh` | Host-side pull client: fetch, decrypt, verify, install `/etc/ssh/revoked_keys`. |
| `krl-puller.service` / `krl-puller.timer` | systemd units that run the puller every 15 min. |
| `test_app.py` | Offline pytest suite (KMS wrappers mocked — no live KMS needed). |
| `Dockerfile` | Slim `python:3.11-slim` image, built with `uv`, serves on `:8088`. |
| `pyproject.toml` | uv / PEP 621 project metadata. |

## Security model — decryption *is* the proof of identity

The service performs **no application-level auth**. Security is layered
(see the design doc's "Security Properties" table):

1. **Transport** — HTTPS (assumed in front of the service; not re-implemented).
2. **Confidentiality** — the response body is **ECIES** ciphertext encrypted to
   the requesting host's **public** key. Only the host that owns the matching
   private key (`/etc/ssh/ssh_host_ecdsa_key`, which never leaves the host) can
   decrypt it. A host that cannot decrypt the payload cannot use it — so
   **successful decryption is implicit proof of identity**.
3. **Authenticity** — the KRL bytes are signed by the **CA private key** inside
   the KMS (ECDSA). The host verifies that signature with the **CA public key**,
   so the KRL is trustworthy even if the distribution service is compromised.
4. **Freshness** — a `valid_until` timestamp is baked *inside* the ciphertext;
   the host rejects expired payloads, preventing replay.

The CA private key never leaves the KMS; the host private key never leaves the
host. The service in the middle only ever sees public keys and opaque bytes.

`host_id` travels in the **request body**, never the URL — so it does not leak
into access logs, proxy caches, or `curl -v` output. It is also echoed *inside*
the ciphertext to bind each payload to its intended recipient.

## Endpoints

### `POST /krl`

Request:

```http
POST /krl
Content-Type: application/json
If-None-Match: sha256:<local /etc/ssh/revoked_keys hash>

{"host_id": "server.lab.local"}
```

Responses:

| Status | When | Body / headers |
|---|---|---|
| `304 Not Modified` | `If-None-Match` equals the current KRL version | `X-KRL-Version: sha256:…`, no body (cheap path — no signing/encryption) |
| `200 OK` | KRL changed, or no `If-None-Match` | `Content-Type: application/octet-stream`, `X-KRL-Version: sha256:…`, body = ECIES ciphertext |
| `404 Not Found` | `host_id` not registered in the KMS | JSON detail (the only authorization gate) |
| `400 Bad Request` | missing / malformed `host_id` or body | JSON detail |
| `503 Service Unavailable` | no current KRL object in the KMS | JSON detail |

Inner plaintext payload (visible only *after* the host decrypts):

```json
{
  "krl":          "<base64 KRL bytes>",
  "ca_signature": "<base64 ECDSA signature>",
  "krl_version":  "sha256:<hash>",
  "valid_until":  1744292400,
  "host_id":      "server.lab.local"
}
```

### `GET /healthz`

Liveness probe. Returns `{"status": "ok"}` and does **not** touch the KMS.

## How it maps to `docs/krl-distribution.md`

The `POST /krl` handler performs exactly the four KMS operations from the
design doc's **"KMS Operations Summary"** (all run server-side inside the KMS):

| Doc step | Wrapper in `app.py` | `cosmian` call |
|---|---|---|
| Locate host pubkey | `kms_locate_host_pubkey` | `cosmian kms locate --tag <host_id> --tag host-pubkey` |
| Retrieve KRL | `kms_locate_krl` + `kms_export_krl` | `cosmian kms locate --tag krl-current` → `opaque-object export … --key-format raw` |
| Sign KRL | `kms_sign_krl` | `cosmian kms ec sign --key-id <ca> --curve nist-p256` |
| Encrypt payload | `kms_encrypt_for_host` | `cosmian kms ec encrypt --key-id <host_pubkey_id>` |

Each is a small, isolated wrapper so the entire HTTP surface is unit-testable
offline by monkeypatching them (see `test_app.py`).

The host side (`host_puller.sh`) performs only the two **host-local** operations
from the doc:

* `cosmian kms ec decrypt` with the host's own private-key id, and
* `cosmian kms ec sign-verify` with the CA public key,

then atomically `install -m 444` the result to `/etc/ssh/revoked_keys`. `sshd`
re-reads `RevokedKeys` on every authentication attempt, so **no restart is
needed**.

## Configuration (environment variables)

### Service (`app.py`)

| Var | Default | Meaning |
|---|---|---|
| `COSMIAN_BIN` | `cosmian` | Path to the cosmian CLI. |
| `KRL_TAG` | `krl-current` | KMS tag of the current KRL opaque object. |
| `HOST_PUBKEY_TAG` | `host-pubkey` | KMS tag applied to every registered host public key. |
| `CA_KEY_ID` | `ssh-host-ca` | KMS id/tag of the CA private key that signs the KRL. |
| `CA_CURVE` | `nist-p256` | Curve of the CA signing key. |
| `KRL_VALID_FOR_SECONDS` | `1800` | Freshness window (`valid_until = now + this`). |
| `COSMIAN_TIMEOUT_SECONDS` | `30` | Per-`cosmian` subprocess timeout. |
| `HOST` / `PORT` | `0.0.0.0` / `8088` | Bind address when run via `python app.py`. |

KMS connection details (server URL, client TLS PKCS#12) come from
`~/.cosmian/cosmian.toml` under `[kms_config.http_config]`, exactly as the rest
of this repo.

### Host puller (`host_puller.sh`)

Set these in `/etc/krl-puller.env` (read by the systemd unit):

| Var | Default | Meaning |
|---|---|---|
| `KRL_API_URL` | `https://krl.internal:8088/krl` | Service endpoint. |
| `HOST_ID` | `$(hostname -f)` | This host's id (must match its KMS registration). |
| `HOST_PRIV_KEY_ID` | `$HOST_ID` | KMS id of this host's private (ECIES decrypt) key. |
| `CA_PUBLIC_KEY_ID` | `ssh-host-ca_pk` | KMS id of the CA public key (signature verify). |
| `REVOKED_KEYS` | `/etc/ssh/revoked_keys` | Install target (must match `sshd_config` `RevokedKeys`). |

## Run it

### Locally with uv

```bash
uv venv
uv pip install -e '.[dev]'      # fastapi, uvicorn, pytest, httpx
uv run uvicorn app:app --host 0.0.0.0 --port 8088
```

### Tests (offline — no KMS required)

```bash
uv run --extra dev pytest
```

### Docker

CI builds and publishes this image to the GitHub Container Registry on every
push to `main` (tag `latest`) and for each `v*` release tag:

```bash
docker pull ghcr.io/oriolrius/ssh-ca-cosmian-kms/krl-distributor:latest
```

Or build it locally:

```bash
docker build -t krl-distributor .
docker run --rm -p 8088:8088 \
  -v "$HOME/.cosmian:/home/krl/.cosmian:ro" \
  -v /usr/local/bin/cosmian:/usr/local/bin/cosmian:ro \
  krl-distributor
```

The image is intentionally minimal and ships **no** cosmian CLI or KMS
credentials — mount them at runtime (or extend the image) so the container stays
secret-free.

### Deploy the host puller

```bash
sudo install -m 755 host_puller.sh /usr/local/sbin/host_puller.sh
sudo install -m 644 krl-puller.service krl-puller.timer /etc/systemd/system/
sudo tee /etc/krl-puller.env >/dev/null <<'EOF'
KRL_API_URL=https://krl.internal:8088/krl
HOST_ID=server.lab.local
HOST_PRIV_KEY_ID=server.lab.local
CA_PUBLIC_KEY_ID=ssh-host-ca_pk
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now krl-puller.timer
```

## License

[MIT](../../LICENSE) © 2026 Oriol Rius.
