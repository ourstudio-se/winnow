"""Dev JWKS server for testing the sample auth module.

Generates an RSA keypair on first run (stored in the keys dir, shared
with generate-token) and serves the public JWKS on every GET path.
Point the module at it: WINNOW_AUTH_JWKS_URL=http://localhost:7292/jwks.json
"""
import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

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
    print(f"generated new keypair at {pem_path}")
    return key


def build_jwks(key):
    jwk = json.loads(RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update({"kid": KID, "alg": "RS256", "use": "sig"})
    return {"keys": [jwk]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=7292)
    parser.add_argument("--keys-dir", default=default_keys_dir())
    args = parser.parse_args()

    key = load_or_create_key(args.keys_dir)
    body = json.dumps(build_jwks(key), indent=2).encode()

    jwks_path = os.path.join(args.keys_dir, "jwks.json")
    with open(jwks_path, "wb") as f:
        f.write(body)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *log_args):
            print(f"{self.address_string()} {fmt % log_args}")

    print(f"serving JWKS on http://localhost:{args.port}/jwks.json")
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
