#!/usr/bin/env python3
"""Wartet, bis Apple den hochgeladenen Build verarbeitet hat, und gibt ihn allen internen TestFlight-Gruppen frei."""
import json, os, sys, time, urllib.request, urllib.error
import jwt

KEY_ID, ISSUER, KEY = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_P8"]
BUNDLE = os.environ.get("BUNDLE_ID", "es.mohs.familie")
BUILD = os.environ["BUILD_NUMBER"]
API = "https://api.appstoreconnect.apple.com/v1"


def call(method, path, body=None):
    now = int(time.time())
    tok = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
                     KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            d = r.read()
            return json.loads(d) if d else {}
    except urllib.error.HTTPError as e:
        print(f"::warning::TestFlight-Zuweisung: {e.code} bei {method} {path}: {e.read().decode()[:300]}")
        return None


apps = (call("GET", f"/apps?filter[bundleId]={BUNDLE}") or {}).get("data", [])
if not apps:
    sys.exit("::warning::TestFlight: App mit Bundle-ID nicht gefunden")
app = apps[0]["id"]

build = None
for i in range(60):  # bis zu 30 Minuten
    r = call("GET", f"/builds?filter[app]={app}&filter[version]={BUILD}&limit=5") or {}
    data = r.get("data", [])
    if data:
        st = data[0]["attributes"].get("processingState")
        print(f"Build {BUILD}: {st}")
        if st == "VALID":
            build = data[0]["id"]
            break
        if st in ("FAILED", "INVALID"):
            sys.exit(f"::warning::TestFlight: Build {BUILD} ist {st}")
    else:
        print(f"Build {BUILD} noch nicht sichtbar")
    time.sleep(30)
if not build:
    sys.exit("::warning::TestFlight: Build nach 30 Minuten noch nicht verarbeitet")

# Exportkonformität: keine eigene Verschlüsselung (falls Apple trotzdem fragt)
call("PATCH", f"/builds/{build}", {"data": {"type": "builds", "id": build, "attributes": {"usesNonExemptEncryption": False}}})

groups = (call("GET", f"/apps/{app}/betaGroups?limit=50") or {}).get("data", [])
for g in groups:
    if g["attributes"].get("isInternalGroup"):
        call("POST", f"/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": build}]})
        print(f"::notice::TestFlight: Build {BUILD} an Gruppe „{g['attributes'].get('name')}“ verteilt")
