"""Faux login server for the dev auth rig (cookie strategy).

GET /login?return_to=<url>   mints a JWT signed with the shared dev key,
sets it as a cookie, and redirects back to return_to.
GET /logout?return_to=<url>  clears the cookie and redirects back.

Without return_to, a plain confirmation page is shown. Cookies are
host-scoped (ports don't matter), so a cookie set on localhost:3005 is
sent to winnow on localhost:8080.

Pairs with a winnow.kdl auth block like:
  login_url  "http://localhost:3005/login?return_to={winnow_return_url}"
  logout_url "http://localhost:3005/logout?return_to={winnow_return_url}"
  strategy "cookie"
  cookie_name "jwt"
"""
import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

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


def mint_token(key, args):
    now = int(time.time())
    payload = {
        "iss": "winnow-dev",
        "sub": args.sub,
        "iat": now,
        "exp": now + args.ttl,
    }
    if args.scopes is not None:
        payload["scope"] = " ".join(parse_scopes(args.scopes))
    payload.update(args.parsed_claims)
    return pyjwt.encode(payload, key, algorithm="RS256",
                        headers={"kid": KID})


PAGE = ("<!doctype html><title>winnow dev login</title>"
        "<body style='font-family: sans-serif'><h3>{msg}</h3>"
        "<p>No return_to given; go back to winnow manually.</p>")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--port", type=int, default=3005)
    parser.add_argument("--cookie-name", default="jwt")
    parser.add_argument("--sub", default="dev-user")
    parser.add_argument("--ttl", type=int, default=3600,
                        help="cookie & token lifetime in seconds")
    parser.add_argument("--scopes", default=None,
                        help="JSON array or space/comma-separated list")
    parser.add_argument("--claims", default="{}",
                        help="JSON object merged into the payload")
    parser.add_argument("--keys-dir", default=default_keys_dir())
    args = parser.parse_args()

    try:
        args.parsed_claims = json.loads(args.claims)
    except json.JSONDecodeError as e:
        sys.exit(f"--claims is not valid JSON: {e}")
    if not isinstance(args.parsed_claims, dict):
        sys.exit("--claims must be a JSON object")

    key = load_or_create_key(args.keys_dir)

    class Handler(BaseHTTPRequestHandler):
        def respond(self, cookie_value, max_age, msg):
            query = parse_qs(urlsplit(self.path).query)
            return_to = query.get("return_to", [None])[0]
            cookie = (f"{args.cookie_name}={cookie_value}; Path=/; "
                      f"Max-Age={max_age}; SameSite=Lax")
            if return_to:
                self.send_response(302)
                self.send_header("Location", return_to)
            else:
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
            self.send_header("Set-Cookie", cookie)
            self.end_headers()
            if not return_to:
                self.wfile.write(PAGE.format(msg=msg).encode())

        def do_GET(self):
            route = urlsplit(self.path).path
            if route == "/login":
                self.respond(mint_token(key, args), args.ttl, "Logged in")
            elif route == "/logout":
                self.respond("", 0, "Logged out")
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, fmt, *log_args):
            print(f"{self.address_string()} {fmt % log_args}")

    print(f"faux login server on http://localhost:{args.port}"
          f" (cookie: {args.cookie_name!r}, sub: {args.sub!r})")
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
