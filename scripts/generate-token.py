"""Sign dev JWTs against the jwks-server keypair.

Examples:
  generate-token
  generate-token --claims '{"sub": "alice", "org": "acme"}'
  generate-token --scopes 'traces:read logs:read'
  generate-token --scopes '["traces:read", "logs:read"]' --ttl 60

Scopes end up in the OAuth-style space-delimited "scope" claim.
--claims is merged last, so it can override anything.
"""
import argparse
import json
import os
import sys
import time

import jwt as pyjwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KID = "winnow-dev"


def default_keys_dir():
    return os.environ.get("WINNOW_DEV_JWKS_DIR", ".dev-jwks")


def load_or_create_key(keys_dir):
    os.makedirs(keys_dir, exist_ok=True)
    pem_path = os.path.join(keys_dir, "private.pem")
    if os.path.exists(pem_path):
        with open(pem_path, "rb") as f:
            return serialization.load_pem_private_key(f.read(), None)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    with open(pem_path, "wb") as f:
        f.write(pem)
    print(f"generated new keypair at {pem_path}", file=sys.stderr)
    return key


def parse_scopes(raw):
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = raw
    if isinstance(parsed, str):
        return parsed.replace(",", " ").split()
    if isinstance(parsed, list):
        return [str(s) for s in parsed]
    sys.exit("--scopes must be a JSON array or a space/comma list")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--claims", default="{}",
                        help="JSON object merged into the payload")
    parser.add_argument("--scopes", default=None,
                        help="JSON array or space/comma-separated list")
    parser.add_argument("--sub", default="dev-user")
    parser.add_argument("--ttl", type=int, default=3600,
                        help="seconds until exp (default 3600)")
    parser.add_argument("--keys-dir", default=default_keys_dir())
    args = parser.parse_args()

    try:
        claims = json.loads(args.claims)
    except json.JSONDecodeError as e:
        sys.exit(f"--claims is not valid JSON: {e}")
    if not isinstance(claims, dict):
        sys.exit("--claims must be a JSON object")

    now = int(time.time())
    payload = {
        "iss": "winnow-dev",
        "sub": args.sub,
        "iat": now,
        "exp": now + args.ttl,
    }
    if args.scopes is not None:
        payload["scope"] = " ".join(parse_scopes(args.scopes))
    payload.update(claims)

    key = load_or_create_key(args.keys_dir)
    token = pyjwt.encode(
        payload, key, algorithm="RS256", headers={"kid": KID},
    )
    print(token)


if __name__ == "__main__":
    main()
