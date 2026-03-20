#!/usr/bin/env python3
"""Delete the OTel indices from Quickwit so they get recreated with fresh schema.

Requires QUICKWIT_URL to be set (exported by the devshell).

Usage:
  nuke-indices
"""

import os
import sys
import urllib.request
import urllib.error

INDICES = ["otel-traces-v0_9", "otel-logs-v0_9"]


def delete_index(base_url, index_id):
    url = f"{base_url}/api/v1/indexes/{index_id}"
    req = urllib.request.Request(url, method="DELETE")
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"  deleted {index_id} ({resp.status})")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"  {index_id} not found (already gone)")
        else:
            print(f"  {index_id} failed: {e.code} {e.read().decode()}")
            return False
    except urllib.error.URLError as e:
        print(f"  {index_id} failed: {e.reason}")
        return False
    return True


def main():
    base_url = os.environ.get("QUICKWIT_URL")
    if not base_url:
        print(
            "error: QUICKWIT_URL is not set. "
            "Run this from the devshell (nix develop).",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Nuking OTel indices at {base_url}...")
    ok = True
    for index_id in INDICES:
        if not delete_index(base_url, index_id):
            ok = False

    if ok:
        print("Done. Restart the backend to recreate indices.")
    else:
        print("Some deletions failed.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
