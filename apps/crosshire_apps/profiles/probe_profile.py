"""Step 1 probe: can a query profile be fetched with a personal access token alone?

Replays the request the UI makes for a profile (captured per PROBE_GUIDE.md) with only
`Authorization: Bearer <token>`, for one statement id, and prints the HTTP status and the
JSON key tree. It never prints values, the token, or cookies.

    export DATABRICKS_HOST=https://<workspace>.cloud.databricks.com
    export DATABRICKS_TOKEN=<token>     # read from the environment only
    python -m crosshire_apps.profiles.probe_profile --curl request.txt --statement-id <id>

In request.txt, write the statement id of the captured request as {statement_id}.
"""
import argparse
import json
import os
import shlex
import sys
import urllib.error
import urllib.parse
import urllib.request

from crosshire_apps.common.key_tree import key_tree, render

# Headers the browser sends that we drop: identity must come from the token alone.
DROPPED_HEADERS = {"cookie", "authorization", "x-csrf-token", "x-databricks-org-id-token"}


def parse_curl(text):
    """(method, url, headers, body) from a 'Copy as cURL (bash)' command."""
    args = shlex.split(text.replace("\\\n", " "))
    if not args or args[0] != "curl":
        raise ValueError("expected a curl command")
    method, url, headers, body = None, None, {}, None
    it = iter(args[1:])
    for a in it:
        if a in ("-X", "--request"):
            method = next(it)
        elif a in ("-H", "--header"):
            k, _, v = next(it).partition(":")
            if k.strip().lower() not in DROPPED_HEADERS:
                headers[k.strip()] = v.strip()
        elif a in ("--data", "--data-raw", "--data-binary", "-d"):
            body = next(it)
        elif a in ("-b", "--cookie"):
            next(it)
        elif not a.startswith("-") and url is None:
            url = a
    return method or ("POST" if body is not None else "GET"), url, headers, body


def probe(method, url, headers, body, host, token, statement_id):
    url = url.replace("{statement_id}", urllib.parse.quote(statement_id))
    # Replay against the configured host, whatever host the capture came from.
    parts = urllib.parse.urlsplit(url)
    url = host.rstrip("/") + parts.path + (f"?{parts.query}" if parts.query else "")
    data = body.replace("{statement_id}", statement_id).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.headers.get("Content-Type", ""), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read()


def report(status, content_type, payload):
    print(f"status: {status}")
    print(f"content-type: {content_type}")
    print(f"bytes: {len(payload)}")
    try:
        doc = json.loads(payload)
    except ValueError:
        print("body is not JSON")
        return
    print("\n".join(render(key_tree(doc))))


def main(argv=None):
    a = argparse.ArgumentParser()
    a.add_argument("--curl", required=True, help="file with the captured request, cookies and tokens removed")
    a.add_argument("--statement-id", required=True)
    args = a.parse_args(argv)
    host, token = os.environ.get("DATABRICKS_HOST"), os.environ.get("DATABRICKS_TOKEN")
    if not host or not token:
        sys.exit("set DATABRICKS_HOST and DATABRICKS_TOKEN")
    with open(args.curl) as f:
        method, url, headers, body = parse_curl(f.read())
    print(f"request: {method} {urllib.parse.urlsplit(url).path}")
    report(*probe(method, url, headers, body, host, token, args.statement_id))


if __name__ == "__main__":
    main()
