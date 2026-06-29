"""Offline unit tests for the KRL Distribution Service.

These tests run with **no live KMS**: every cosmian subprocess wrapper in
``app`` is replaced via monkeypatch. They assert the four behaviours called out
in docs/krl-distribution.md plus the inner-payload shape.

Run with:  uv run pytest
"""

from __future__ import annotations

import base64
import json

import pytest
from fastapi.testclient import TestClient

import app as appmod

# A deterministic fake KMS state shared by the fixtures below.
KRL_BYTES = b"# fake KRL\nsha256:deadbeef\n"
FAKE_SIGNATURE = b"\x30\x45fake-ecdsa-signature-bytes"
REGISTERED_HOST = "server.lab.local"
HOST_PUBKEY_ID = "server.lab.local_pk"


@pytest.fixture
def fake_kms(monkeypatch):
    """Replace every cosmian wrapper with an in-memory fake.

    Returns a mutable dict the test can tweak (e.g. to simulate a KRL change or
    capture what was sent to ``ec encrypt``).
    """
    state = {
        "krl_bytes": KRL_BYTES,
        "registered_hosts": {REGISTERED_HOST: HOST_PUBKEY_ID},
        "encrypt_calls": [],
        "sign_calls": [],
    }

    def fake_locate_host_pubkey(host_id):
        try:
            return state["registered_hosts"][host_id]
        except KeyError as exc:
            raise appmod.HostNotRegistered(host_id) from exc

    def fake_locate_krl():
        return "krl-object-id"

    def fake_export_krl(_krl_object_id):
        return state["krl_bytes"]

    def fake_sign_krl(krl_bytes):
        state["sign_calls"].append(krl_bytes)
        return FAKE_SIGNATURE

    def fake_encrypt_for_host(host_pubkey_id, plaintext):
        # The fake "ciphertext" is just the plaintext tagged with the recipient,
        # so the test can recover and inspect the inner payload.
        state["encrypt_calls"].append((host_pubkey_id, plaintext))
        return b"ENC:" + host_pubkey_id.encode() + b":" + plaintext

    monkeypatch.setattr(appmod, "kms_locate_host_pubkey", fake_locate_host_pubkey)
    monkeypatch.setattr(appmod, "kms_locate_krl", fake_locate_krl)
    monkeypatch.setattr(appmod, "kms_export_krl", fake_export_krl)
    monkeypatch.setattr(appmod, "kms_sign_krl", fake_sign_krl)
    monkeypatch.setattr(appmod, "kms_encrypt_for_host", fake_encrypt_for_host)
    return state


@pytest.fixture
def client(fake_kms):
    return TestClient(appmod.app)


def _decode_fake_ciphertext(blob: bytes) -> dict:
    """Recover the inner payload from the fake ciphertext format."""
    # Format: b"ENC:" + pubkey_id + b":" + plaintext
    _enc, _pk, plaintext = blob.split(b":", 2)
    return json.loads(plaintext)


def test_healthz(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_304_on_etag_match(client, fake_kms):
    """If-None-Match equal to the current version -> 304 + X-KRL-Version, no body."""
    version = appmod.krl_version(fake_kms["krl_bytes"])
    resp = client.post(
        "/krl",
        json={"host_id": REGISTERED_HOST},
        headers={"If-None-Match": version},
    )
    assert resp.status_code == 304
    assert resp.headers["X-KRL-Version"] == version
    assert resp.content == b""
    # The cheap path must not have signed or encrypted anything.
    assert fake_kms["sign_calls"] == []
    assert fake_kms["encrypt_calls"] == []


def test_200_on_change(client, fake_kms):
    """Stale (or absent) ETag -> 200 octet-stream ciphertext + X-KRL-Version."""
    # Simulate the client holding an *old* KRL hash.
    resp = client.post(
        "/krl",
        json={"host_id": REGISTERED_HOST},
        headers={"If-None-Match": "sha256:stale000"},
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/octet-stream"
    version = appmod.krl_version(fake_kms["krl_bytes"])
    assert resp.headers["X-KRL-Version"] == version
    assert resp.content  # non-empty ciphertext
    # Encryption was performed for the correct host public key.
    assert len(fake_kms["encrypt_calls"]) == 1
    assert fake_kms["encrypt_calls"][0][0] == HOST_PUBKEY_ID


def test_200_when_no_etag(client, fake_kms):
    """No If-None-Match header at all -> always 200 with ciphertext."""
    resp = client.post("/krl", json={"host_id": REGISTERED_HOST})
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/octet-stream"
    assert resp.content


def test_404_on_unknown_host(client):
    """An unregistered host_id is the only authorization gate -> 404."""
    resp = client.post("/krl", json={"host_id": "ghost.lab.local"})
    assert resp.status_code == 404
    assert "not registered" in resp.json()["detail"]


def test_400_on_missing_host_id(client):
    resp = client.post("/krl", json={})
    assert resp.status_code == 400


def test_400_on_malformed_host_id(client):
    # A value with shell/flag-injection characters must be rejected.
    resp = client.post("/krl", json={"host_id": "--tag evil; rm -rf /"})
    assert resp.status_code == 400


def test_inner_payload_shape(client, fake_kms):
    """The decrypted inner payload matches the documented schema exactly."""
    resp = client.post("/krl", json={"host_id": REGISTERED_HOST})
    assert resp.status_code == 200

    payload = _decode_fake_ciphertext(resp.content)

    # Exact key set per docs/krl-distribution.md.
    assert set(payload.keys()) == {
        "krl",
        "ca_signature",
        "krl_version",
        "valid_until",
        "host_id",
    }

    # krl is base64 of the original KRL bytes.
    assert base64.b64decode(payload["krl"]) == fake_kms["krl_bytes"]
    # ca_signature is base64 of the (fake) CA signature.
    assert base64.b64decode(payload["ca_signature"]) == FAKE_SIGNATURE
    # version is sha256 of the KRL bytes and matches the response header.
    expected_version = appmod.krl_version(fake_kms["krl_bytes"])
    assert payload["krl_version"] == expected_version
    assert resp.headers["X-KRL-Version"] == expected_version
    # host_id is echoed back inside the ciphertext (binds payload to recipient).
    assert payload["host_id"] == REGISTERED_HOST
    # valid_until is a unix timestamp in the near future (~ now + window).
    assert isinstance(payload["valid_until"], int)
    assert payload["valid_until"] > 0


def test_build_inner_payload_valid_until(monkeypatch):
    """valid_until == issued_at + configured window (default 1800s = 30 min)."""
    payload = appmod.build_inner_payload(
        krl_bytes=b"x",
        ca_signature=b"y",
        version="sha256:abc",
        host_id=REGISTERED_HOST,
        now=1_000_000,
    )
    assert payload["valid_until"] == 1_000_000 + appmod.SETTINGS.valid_for_seconds


def test_host_id_validation():
    assert appmod.valid_host_id("server.lab.local")
    assert appmod.valid_host_id("host-01.example.com")
    assert not appmod.valid_host_id("")
    assert not appmod.valid_host_id("-leading-dash")
    assert not appmod.valid_host_id("has space")
    assert not appmod.valid_host_id("--tag")
    assert not appmod.valid_host_id(None)
    assert not appmod.valid_host_id(1234)
