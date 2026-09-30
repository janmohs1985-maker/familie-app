#!/usr/bin/env python3
"""Ad-hoc-Profil für es.mohs.familie über die App-Store-Connect-API holen.

Nimmt das Apple-Distribution-Zertifikat, dessen Seriennummer übergeben wird, und alle
eingetragenen iPhones, legt ein frisches Ad-hoc-Profil an (alte eigene werden gelöscht),
installiert es und gibt den Profilnamen aus. So entstehen bei jedem Build KEINE neuen Zertifikate.
"""
import base64, json, os, sys, time, urllib.request, urllib.error, uuid, plistlib, pathlib
import jwt  # PyJWT

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
KEY = os.environ["ASC_KEY_P8"]
BUNDLE = os.environ.get("BUNDLE_ID", "es.mohs.familie")
SERIAL = os.environ["CERT_SERIAL"].upper().lstrip("0")
PREFIX = os.environ.get("PROFILE_PREFIX", "Familie AdHoc CI")
BUNDLE_NAME = os.environ.get("BUNDLE_NAME", "Familie")
API = "https://api.appstoreconnect.apple.com/v1"


def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
                      KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(path if path.startswith("http") else API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"API-Fehler {e.code} bei {method} {path}: {e.read().decode()[:600]}")


def all_pages(path):
    out, url = [], path
    while url:
        r = call("GET", url)
        out += r.get("data", [])
        url = r.get("links", {}).get("next")
    return out


# 1) App-ID
ids = call("GET", f"/bundleIds?filter[identifier]={BUNDLE}&limit=200").get("data", [])
ids = [b for b in ids if b["attributes"]["identifier"] == BUNDLE]
if ids:
    bundle_id = ids[0]["id"]
else:
    bundle_id = call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE, "name": BUNDLE_NAME, "platform": "IOS"}}})["data"]["id"]
    print(f"App-ID {BUNDLE} angelegt", file=sys.stderr)

# 1b) gewünschte Fähigkeiten der App-ID einschalten (z. B. Mitteilungen mit Profilbild) – Fehler brechen nicht ab
CAPS = [c for c in os.environ.get("ENABLE_CAPS", "").split(",") if c]
if CAPS:
    ok = True
    try:
        have = {c["attributes"]["capabilityType"] for c in call("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities").get("data", [])}
    except SystemExit:
        have, ok = set(), False
    print("Fähigkeiten der App-ID: " + (", ".join(sorted(have)) or "keine"), file=sys.stderr)
    for cap in CAPS:
        if cap in have:
            continue
        req = urllib.request.Request(API + "/bundleIdCapabilities", method="POST", data=json.dumps({"data": {
            "type": "bundleIdCapabilities", "attributes": {"capabilityType": cap},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}}}}).encode(),
            headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=60).read()
            print(f"Fähigkeit {cap} eingeschaltet", file=sys.stderr)
        except urllib.error.HTTPError as e:
            ok = False
            print(f"Fähigkeit {cap} nicht möglich ({e.code}): {e.read().decode()[:300]}", file=sys.stderr)
    if ok and os.environ.get("CAPS_OK_FILE"):
        pathlib.Path(os.environ["CAPS_OK_FILE"]).write_text("ok")

# 2) Zertifikat zur Seriennummer
certs = all_pages("/certificates?limit=200")
cert = next((c for c in certs if c["attributes"].get("serialNumber", "").upper().lstrip("0") == SERIAL), None)
if not cert:
    sys.exit("Das Zertifikat aus DIST_P12 wurde im Entwicklerkonto nicht gefunden (Seriennummer " + SERIAL + ").")

# 3) Geräte
devices = [d for d in all_pages("/devices?limit=200")
           if d["attributes"].get("status") == "ENABLED" and d["attributes"].get("platform") in ("IOS", "UNIVERSAL")]
if not devices:
    sys.exit("Im Entwicklerkonto sind keine iPhones eingetragen.")

# 4) alte eigene Profile löschen, neues anlegen
for p in all_pages("/profiles?limit=200"):
    if p["attributes"]["name"].startswith(PREFIX):
        call("DELETE", f"/profiles/{p['id']}")
name = f"{PREFIX} {int(time.time())}"
prof = call("POST", "/profiles", {"data": {"type": "profiles",
    "attributes": {"name": name, "profileType": "IOS_APP_ADHOC"},
    "relationships": {
        "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
        "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
        "devices": {"data": [{"type": "devices", "id": d["id"]} for d in devices]}}}})["data"]

content = base64.b64decode(prof["attributes"]["profileContent"])
start, end = content.find(b"<?xml"), content.find(b"</plist>") + len(b"</plist>")
info = plistlib.loads(content[start:end])
folder = pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"
folder.mkdir(parents=True, exist_ok=True)
(folder / f"{info['UUID']}.mobileprovision").write_bytes(content)
print(f"Profil „{name}“ mit {len(devices)} Gerät(en) installiert", file=sys.stderr)
print(name)
