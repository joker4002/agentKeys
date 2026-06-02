#!/usr/bin/env python3
"""WebAuthn (K11) UserOp signer for the ERC-4337 P256Account (#164 E7/E8).

The production P256Account verifies a UserOp via the on-chain K11Verifier, which
expects a real WebAuthn assertion whose challenge == base64url(userOpHash). This
helper produces that assertion (authData + clientDataJSON + P-256 r,s) exactly the
way K11Verifier.verifyAssertion parses it:
  - authData = sha256(rpId) || flags(0x05 = UP|UV) || signCount(4)   (37 bytes)
  - clientDataJSON = {"type":"webauthn.get","challenge":"<43-char b64url>","origin":...}
    → challenge value starts at offset 36 (challengeLocation)
  - msgHash = sha256(authData || sha256(clientDataJSON)); P-256 sign (low-s)

Modes:
  keygen <keyfile> <rpId>            -> PUBX=, PUBY=, RPIDHASH=
  sign   <keyfile> <userOpHash> <rpId> -> AUTHDATA=, CDJ=, CHALLENGE_LOC=, R=, S=
"""
import base64
import hashlib
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed, decode_dss_signature

CURVE_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


def _rp_id_hash(rp_id: str) -> bytes:
    return hashlib.sha256(rp_id.encode()).digest()


def keygen(keyfile: str, rp_id: str) -> None:
    priv = ec.generate_private_key(ec.SECP256R1())
    with open(keyfile, "wb") as f:
        f.write(priv.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ))
    n = priv.public_key().public_numbers()
    print(f"PUBX=0x{n.x:064x}")
    print(f"PUBY=0x{n.y:064x}")
    print(f"RPIDHASH=0x{_rp_id_hash(rp_id).hex()}")


def sign(keyfile: str, userophash_hex: str, rp_id: str) -> None:
    with open(keyfile, "rb") as f:
        priv = serialization.load_pem_private_key(f.read(), password=None)

    uoh = bytes.fromhex(userophash_hex[2:] if userophash_hex.startswith("0x") else userophash_hex)
    assert len(uoh) == 32, "userOpHash must be 32 bytes"

    challenge_b64 = base64.urlsafe_b64encode(uoh).rstrip(b"=").decode()  # 43 chars
    client_data = (
        '{"type":"webauthn.get","challenge":"' + challenge_b64
        + '","origin":"https://' + rp_id + '"}'
    ).encode()
    # K11Verifier expects the challenge value at offset 36 (after `{"type":"webauthn.get","challenge":"`).
    assert client_data[36:36 + 43] == challenge_b64.encode(), "challengeLocation drift"

    auth_data = _rp_id_hash(rp_id) + bytes([0x05]) + (0).to_bytes(4, "big")  # UP|UV, signCount 0

    msg_hash = hashlib.sha256(auth_data + hashlib.sha256(client_data).digest()).digest()
    der = priv.sign(msg_hash, ec.ECDSA(Prehashed(hashes.SHA256())))
    r, s = decode_dss_signature(der)
    if s > CURVE_N // 2:
        s = CURVE_N - s

    print(f"AUTHDATA=0x{auth_data.hex()}")
    print(f"CDJ=0x{client_data.hex()}")
    print("CHALLENGE_LOC=36")
    print(f"R=0x{r:064x}")
    print(f"S=0x{s:064x}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "keygen":
        keygen(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 5 and sys.argv[1] == "sign":
        sign(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit("usage: erc4337-webauthn-sign.py keygen <keyfile> <rpId> | sign <keyfile> <userOpHash> <rpId>")
