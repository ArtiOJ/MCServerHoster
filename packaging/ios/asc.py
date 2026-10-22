#!/usr/bin/env python3
"""App Store Connect API for the iPhone app: the App ID, its App Store
provisioning profile, TestFlight testers and the uploaded builds.

  python3 packaging/ios/asc.py status                 read only: what exists
  python3 packaging/ios/asc.py setup                  register the App ID, make the profile
  python3 packaging/ios/asc.py testers [--add EMAIL]  the internal TestFlight group
  python3 packaging/ios/asc.py builds                 uploaded builds and their state

Every write looks first and only makes what is missing. The bundle id is
the iOS preset's in export_presets.cfg. The credentials come from the
environment, then from the git-ignored .env at the repository root:
ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_FILE (the AuthKey_<id>.p8)
and APPLE_CERT_ID (the Apple Distribution certificate the profile binds).
The profile is saved to the git-ignored secrets/, where testflight.sh looks.
Needs the `cryptography` package to sign the API token.
"""
import argparse
import base64
import json
import os
import pathlib
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
API = "https://api.appstoreconnect.apple.com"
APP_NAME = "Server Manager"
PROFILE_NAME = "Server Manager App Store"
GROUP_NAME = "Internal"


class Failure(Exception):
    pass


def bundle_id():
    text = (ROOT / "export_presets.cfg").read_text()
    found = re.search(r'^application/bundle_identifier="([^"]+)"', text, re.M)
    if not found:
        raise Failure("no application/bundle_identifier in export_presets.cfg")
    return found.group(1)


def setting(name):
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in (ROOT / ".env").read_text().splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    raise Failure(f"{name} is not set (environment or {ROOT / '.env'})")


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def make_token():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    key = serialization.load_pem_private_key(pathlib.Path(setting("ASC_API_KEY_FILE")).read_bytes(), None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": setting("ASC_API_KEY_ID"), "typ": "JWT"}
    payload = {"iss": setting("ASC_API_ISSUER_ID"), "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = ".".join(b64url(json.dumps(p, separators=(",", ":")).encode()) for p in (header, payload))
    # cryptography signs to DER; a JWT wants the raw r || s.
    r, s = utils.decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    return signing_input + "." + b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def ssl_context():
    context = ssl.create_default_context()
    if context.cert_store_stats().get("x509_ca"):
        return context
    import certifi  # a python.org Python ships without the system's CAs

    return ssl.create_default_context(cafile=certifi.where())


class Client:
    def __init__(self):
        self.token = make_token()
        self.context = ssl_context()

    def call(self, method, path, params=None, body=None):
        url = path if path.startswith("http") else API + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Authorization", "Bearer " + self.token)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=60) as response:
                raw = response.read()
        except urllib.error.HTTPError as err:
            raise Failure(f"{method} {path}: HTTP {err.code}\n{err.read().decode('utf-8', 'replace')}")
        return json.loads(raw) if raw else {}

    def get_all(self, path, params=None):
        page = self.call("GET", path, params)
        rows = page.get("data", [])
        while page.get("links", {}).get("next"):
            page = self.call("GET", page["links"]["next"])
            rows += page.get("data", [])
        return rows

    def post(self, path, body):
        return self.call("POST", path, body=body)


def attrs(row):
    return row.get("attributes", {})


def find_bundle_id(client, ident):
    rows = client.get_all("/v1/bundleIds", {"filter[identifier]": ident})
    return next((r for r in rows if attrs(r).get("identifier") == ident), None)


def find_app(client, ident):
    rows = client.get_all("/v1/apps", {"filter[bundleId]": ident})
    return next((r for r in rows if attrs(r).get("bundleId") == ident), None)


def store_profiles(client, bundle_row):
    rows = client.get_all(f"/v1/bundleIds/{bundle_row['id']}/profiles")
    return [p for p in rows if attrs(p).get("profileType") == "IOS_APP_STORE"]


def save_profile(row):
    path = ROOT / "secrets" / (attrs(row)["name"].replace(" ", "_") + ".mobileprovision")
    path.parent.mkdir(mode=0o700, exist_ok=True)
    path.write_bytes(base64.b64decode(attrs(row)["profileContent"]))
    path.chmod(0o600)
    print(f"  saved to {path}")


def cmd_status(client, args):
    ident = bundle_id()
    row = find_bundle_id(client, ident)
    print(f"App ID {ident}: {'registered' if row else 'NOT registered (run: setup)'}")
    if row:
        for p in store_profiles(client, row):
            a = attrs(p)
            print(f"  profile {a['name']!r}: {a.get('profileState')}, expires {a.get('expirationDate', '')[:10]}")
    app = find_app(client, ident)
    print(f"App Store Connect record: {repr(attrs(app).get('name')) if app else 'none yet (made on the website)'}")


def cmd_setup(client, args):
    ident = bundle_id()
    row = find_bundle_id(client, ident)
    if row:
        print(f"App ID {ident}: already registered")
    else:
        body = {"data": {"type": "bundleIds",
                         "attributes": {"identifier": ident, "name": APP_NAME, "platform": "IOS"}}}
        row = client.post("/v1/bundleIds", body)["data"]
        print(f"App ID {ident}: REGISTERED")
    cert_id = setting("APPLE_CERT_ID")
    for p in store_profiles(client, row):
        if attrs(p).get("profileState") == "ACTIVE" and attrs(p).get("name") == PROFILE_NAME:
            print(f"profile {PROFILE_NAME!r}: already active, downloading it again")
            save_profile(p)
            return
    body = {"data": {"type": "profiles",
                     "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
                     "relationships": {
                         "bundleId": {"data": {"type": "bundleIds", "id": row["id"]}},
                         "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}}
    profile = client.post("/v1/profiles", body)["data"]
    print(f"profile {PROFILE_NAME!r}: CREATED for certificate {cert_id}, expires {attrs(profile).get('expirationDate', '')[:10]}")
    save_profile(profile)


def require_app(client):
    app = find_app(client, bundle_id())
    if not app:
        raise Failure("no App Store Connect record for this bundle id yet; it is made on the website")
    return app


def cmd_testers(client, args):
    app = require_app(client)
    groups = client.get_all(f"/v1/apps/{app['id']}/betaGroups")
    group = next((g for g in groups if attrs(g).get("isInternalGroup")), None)
    if group:
        print(f"internal group {attrs(group).get('name')!r}: exists")
    elif args.add:
        body = {"data": {"type": "betaGroups",
                         "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
                         "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}}
        group = client.post("/v1/betaGroups", body)["data"]
        print(f"internal group {GROUP_NAME!r}: CREATED (every build)")
    else:
        print("no internal group yet (run: testers --add EMAIL)")
        return
    present = {attrs(t).get("email", "").lower() for t in client.get_all(f"/v1/betaGroups/{group['id']}/betaTesters")}
    for email in args.add or []:
        if email.lower() in present:
            continue
        known = client.get_all("/v1/betaTesters", {"filter[email]": email})
        if known:
            client.post(f"/v1/betaGroups/{group['id']}/relationships/betaTesters",
                        {"data": [{"type": "betaTesters", "id": known[0]["id"]}]})
        else:
            client.post("/v1/betaTesters", {"data": {
                "type": "betaTesters", "attributes": {"email": email},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
        present.add(email.lower())
        print(f"  {email}: ADDED")
    print("  testers: " + (", ".join(sorted(present)) or "nobody"))


def cmd_builds(client, args):
    app = require_app(client)
    rows = client.get_all("/v1/builds", {"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 20})
    print(f"builds: {len(rows)}")
    for row in rows:
        a = attrs(row)
        print(f"  ({a.get('version')})  {a.get('processingState')}  uploaded {a.get('uploadedDate', '')[:16]}"
              + ("  EXPIRED" if a.get("expired") else ""))


def main():
    parser = argparse.ArgumentParser(description="App Store Connect API for the iPhone app.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    sub.add_parser("setup").set_defaults(fn=cmd_setup)
    p = sub.add_parser("testers")
    p.add_argument("--add", action="append", metavar="EMAIL")
    p.set_defaults(fn=cmd_testers)
    sub.add_parser("builds").set_defaults(fn=cmd_builds)
    args = parser.parse_args()
    try:
        args.fn(Client(), args)
    except Failure as err:
        sys.exit(f"asc.py: {err}")


if __name__ == "__main__":
    main()
