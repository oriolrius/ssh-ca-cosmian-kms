"""KRL Distribution Service — stateless, encrypted KRL delivery over REST.

Reference implementation of the design in ``docs/krl-distribution.md``.

The service holds **no secrets**. Every cryptographic operation is delegated to
Cosmian KMS via the ``cosmian`` CLI:

    1. locate the requesting host's public key by tag        (lookup only)
    2. locate + export the current KRL opaque object         (retrieve only)
    3. ``ec sign`` the KRL bytes with the CA *private* key    (private -> signature)
    4. ``ec encrypt`` (ECIES) the inner payload with the      (public  -> ciphertext)
       requesting host's *public* key

Decryption of the response is therefore implicit proof of identity: only the
host that owns the matching ECDSA private key can read its KRL. See the
"Security Properties" table in the design doc.

Each KMS call is a tiny, side-effect-isolated wrapper function so the whole HTTP
surface can be unit-tested offline by monkeypatching those wrappers (see
``test_app.py``) — no live KMS required.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from typing import Optional

from fastapi import FastAPI, Header, Request, Response
from fastapi.responses import JSONResponse

# --------------------------------------------------------------------------- #
# Configuration (all via environment variables — twelve-factor, no secrets)
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Settings:
    """Runtime configuration sourced entirely from the environment."""

    # Path to the cosmian CLI binary.
    cosmian_bin: str = os.environ.get("COSMIAN_BIN", "cosmian")
    # KMS object tag identifying the *current* KRL opaque object.
    krl_tag: str = os.environ.get("KRL_TAG", "krl-current")
    # KMS object tag applied to every registered host public key.
    host_pubkey_tag: str = os.environ.get("HOST_PUBKEY_TAG", "host-pubkey")
    # KMS key id (or tag) of the CA *private* key that signs the KRL.
    # The KRL revokes host keys, so it is signed by the Host CA by default.
    ca_key_id: str = os.environ.get("CA_KEY_ID", "ssh-host-ca")
    # Elliptic curve of the CA signing key (matches the dual-CA convention).
    ca_curve: str = os.environ.get("CA_CURVE", "nist-p256")
    # Freshness window placed inside the ciphertext, in seconds (default 30 min).
    valid_for_seconds: int = int(os.environ.get("KRL_VALID_FOR_SECONDS", "1800"))
    # Timeout for each cosmian subprocess invocation, in seconds.
    cosmian_timeout: int = int(os.environ.get("COSMIAN_TIMEOUT_SECONDS", "30"))


SETTINGS = Settings()

# A conservative hostname / host_id grammar. Accepts DNS names and the lab's
# *.lab.local style identifiers; rejects anything that could be a shell
# injection vector or an attempt to smuggle CLI flags into a tag.
_HOST_ID_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,253}[A-Za-z0-9])?$")


class HostNotRegistered(Exception):
    """Raised when no public key is registered in the KMS for a host_id."""


class KrlUnavailable(Exception):
    """Raised when the current KRL object cannot be located in the KMS."""


# --------------------------------------------------------------------------- #
# Cosmian KMS wrappers — the *only* place that shells out. Each is intentionally
# tiny so tests can monkeypatch them individually.
# --------------------------------------------------------------------------- #


def _run_cosmian(args: list[str]) -> subprocess.CompletedProcess:
    """Run ``cosmian kms <args>`` and return the completed process.

    Raises ``subprocess.CalledProcessError`` on a non-zero exit so callers can
    distinguish "not found" (handled per-wrapper) from genuine failures.
    """
    cmd = [SETTINGS.cosmian_bin, "kms", *args]
    return subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        timeout=SETTINGS.cosmian_timeout,
    )


def kms_locate_host_pubkey(host_id: str) -> str:
    """Return the KMS key id of ``host_id``'s registered public key.

    Mirrors: ``cosmian kms locate --tag <host_id> --tag host-pubkey``.
    ``locate`` prints one id per line and nothing when there is no match —
    so an empty result means the host was never registered (-> 404).
    """
    proc = _run_cosmian(
        ["locate", "--tag", host_id, "--tag", SETTINGS.host_pubkey_tag]
    )
    ids = [line.strip() for line in proc.stdout.decode().splitlines() if line.strip()]
    if not ids:
        raise HostNotRegistered(host_id)
    # If multiple keys share the tags, the most recently registered wins; we
    # take the first deterministically and let the host's own decrypt fail
    # closed if the registration was ambiguous.
    return ids[0]


def kms_locate_krl() -> str:
    """Return the KMS object id of the current KRL opaque object.

    Mirrors: ``cosmian kms locate --tag krl-current``.
    """
    proc = _run_cosmian(["locate", "--tag", SETTINGS.krl_tag])
    ids = [line.strip() for line in proc.stdout.decode().splitlines() if line.strip()]
    if not ids:
        raise KrlUnavailable(SETTINGS.krl_tag)
    return ids[0]


def kms_export_krl(krl_object_id: str) -> bytes:
    """Export the raw KRL bytes for ``krl_object_id``.

    Mirrors: ``cosmian kms opaque-object export --key-id <id> --key-format raw <file>``.
    The CLI writes to a file, so we export into a temp file and read it back.
    """
    with tempfile.NamedTemporaryFile(suffix=".krl") as tmp:
        _run_cosmian(
            [
                "opaque-object",
                "export",
                "--key-id",
                krl_object_id,
                "--key-format",
                "raw",
                tmp.name,
            ]
        )
        with open(tmp.name, "rb") as fh:
            return fh.read()


def kms_sign_krl(krl_bytes: bytes) -> bytes:
    """Sign ``krl_bytes`` with the CA private key inside the KMS (ECDSA).

    Mirrors: ``cosmian kms ec sign --key-id <ca> --curve <curve> -o <out> <file>``.
    The CA private key never leaves the KMS.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        data_path = os.path.join(tmpdir, "krl.bin")
        sig_path = os.path.join(tmpdir, "krl.sig")
        with open(data_path, "wb") as fh:
            fh.write(krl_bytes)
        _run_cosmian(
            [
                "ec",
                "sign",
                "--key-id",
                SETTINGS.ca_key_id,
                "--curve",
                SETTINGS.ca_curve,
                "--output-file",
                sig_path,
                data_path,
            ]
        )
        with open(sig_path, "rb") as fh:
            return fh.read()


def kms_encrypt_for_host(host_pubkey_id: str, plaintext: bytes) -> bytes:
    """ECIES-encrypt ``plaintext`` to ``host_pubkey_id`` inside the KMS.

    Mirrors: ``cosmian kms ec encrypt --key-id <host_pubkey_id> -o <out> <file>``.
    Only the host's matching private key can later decrypt the result.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        in_path = os.path.join(tmpdir, "payload.json")
        out_path = os.path.join(tmpdir, "payload.enc")
        with open(in_path, "wb") as fh:
            fh.write(plaintext)
        _run_cosmian(
            [
                "ec",
                "encrypt",
                "--key-id",
                host_pubkey_id,
                "--output-file",
                out_path,
                in_path,
            ]
        )
        with open(out_path, "rb") as fh:
            return fh.read()


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def krl_version(krl_bytes: bytes) -> str:
    """Return the canonical KRL version string: ``sha256:<hex>``."""
    return "sha256:" + hashlib.sha256(krl_bytes).hexdigest()


def build_inner_payload(
    krl_bytes: bytes,
    ca_signature: bytes,
    version: str,
    host_id: str,
    now: Optional[int] = None,
) -> dict:
    """Assemble the inner plaintext payload (encrypted before it leaves us).

    Shape per docs/krl-distribution.md "Inner plaintext payload".
    """
    issued = int(now if now is not None else time.time())
    return {
        "krl": base64.b64encode(krl_bytes).decode("ascii"),
        "ca_signature": base64.b64encode(ca_signature).decode("ascii"),
        "krl_version": version,
        "valid_until": issued + SETTINGS.valid_for_seconds,
        "host_id": host_id,
    }


def valid_host_id(host_id: object) -> bool:
    """True if ``host_id`` is a well-formed, injection-safe identifier."""
    return isinstance(host_id, str) and bool(_HOST_ID_RE.match(host_id))


# --------------------------------------------------------------------------- #
# FastAPI app
# --------------------------------------------------------------------------- #

app = FastAPI(
    title="KRL Distribution Service",
    version="1.0.0",
    description=(
        "Stateless, encrypted SSH Key Revocation List distribution. "
        "Holds no secrets; all crypto is delegated to Cosmian KMS."
    ),
)


@app.get("/healthz")
def healthz() -> dict:
    """Liveness probe. Does not touch the KMS (the service is stateless)."""
    return {"status": "ok"}


@app.post("/krl")
async def get_krl(
    request: Request,
    if_none_match: Optional[str] = Header(default=None),
) -> Response:
    """Deliver the per-host encrypted KRL.

    Body: ``{"host_id": "<hostname>"}`` (host_id is in the body, never the URL).

    * ``If-None-Match`` matches current KRL version -> **304** + ``X-KRL-Version``.
    * KRL changed (or no ETag) -> **200** ``application/octet-stream`` carrying the
      ECIES ciphertext.
    * Unknown / unregistered host -> **404** (the only authorization gate).
    * Malformed request -> **400**.
    """
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"detail": "invalid JSON body"}, status_code=400)

    host_id = body.get("host_id") if isinstance(body, dict) else None
    if not valid_host_id(host_id):
        return JSONResponse(
            {"detail": "missing or malformed host_id"}, status_code=400
        )

    # ---- The only gate: the host must have been registered at issuance time.
    try:
        host_pubkey_id = kms_locate_host_pubkey(host_id)
    except HostNotRegistered:
        return JSONResponse(
            {"detail": f"host_id not registered: {host_id}"}, status_code=404
        )

    # ---- Determine the current KRL version (cheap path for the 304 case).
    try:
        krl_object_id = kms_locate_krl()
        krl_bytes = kms_export_krl(krl_object_id)
    except KrlUnavailable:
        return JSONResponse({"detail": "no KRL available"}, status_code=503)

    version = krl_version(krl_bytes)

    # ---- 304: client already holds the current KRL. No write, no signing.
    if if_none_match is not None and if_none_match.strip() == version:
        return Response(status_code=304, headers={"X-KRL-Version": version})

    # ---- 200: build, sign, encrypt, return.
    ca_signature = kms_sign_krl(krl_bytes)
    payload = build_inner_payload(
        krl_bytes=krl_bytes,
        ca_signature=ca_signature,
        version=version,
        host_id=host_id,
    )
    plaintext = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    ciphertext = kms_encrypt_for_host(host_pubkey_id, plaintext)

    return Response(
        content=ciphertext,
        media_type="application/octet-stream",
        headers={"X-KRL-Version": version},
    )


if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run(
        "app:app",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8088")),
    )
