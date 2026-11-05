"""Push the cert-manager wildcard certificate into TrueNAS and apply it to the web UI.

Idempotent: exits 0 without touching TrueNAS when the active UI certificate already
matches the mounted one, so it is safe to run on a frequent schedule.

Stdlib only (no pip), configured through the environment:
  TRUENAS_HOST       FQDN of the NAS
  CERT_NAME_PREFIX   prefix for the imported certificate name
  CERT_DIR           directory holding tls.crt / tls.key (default /certs)
  API_KEY_FILE       file holding the TrueNAS API key (default /secrets/api-key)
"""

import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = os.environ["TRUENAS_HOST"]
PREFIX = os.environ["CERT_NAME_PREFIX"]
CERT_DIR = os.environ.get("CERT_DIR", "/certs")
API_KEY_FILE = os.environ.get("API_KEY_FILE", "/secrets/api-key")
BASE = f"https://{HOST}/api/v2.0"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _tlv(buf, pos):
    """Return (tag, content_start, content_length) of the DER element at pos."""
    tag, length = buf[pos], buf[pos + 1]
    pos += 2
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(buf[pos : pos + n], "big")
        pos += n
    return tag, pos, length


def leaf_info(pem):
    """Return (notBefore as YYYY-MM-DD, sha256 hex) of the first certificate in a PEM chain."""
    block = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)
    der = base64.b64decode("".join(block.group(1).split()))

    _, pos, _ = _tlv(der, 0)  # Certificate
    _, pos, _ = _tlv(der, pos)  # tbsCertificate
    tag, start, length = _tlv(der, pos)
    if tag == 0xA0:  # optional explicit version
        pos = start + length
    for _ in range(3):  # serialNumber, signature, issuer
        _, start, length = _tlv(der, pos)
        pos = start + length
    _, pos, _ = _tlv(der, pos)  # validity
    tag, start, length = _tlv(der, pos)  # notBefore
    raw = der[start : start + length].decode("ascii")
    if tag == 0x17:  # UTCTime YYMMDD...
        year = int(raw[:2])
        raw = ("20" if year < 50 else "19") + raw
    # GeneralizedTime is already YYYYMMDD...
    return f"{raw[:4]}-{raw[4:6]}-{raw[6:8]}", hashlib.sha256(der).hexdigest()


CERT = read(f"{CERT_DIR}/tls.crt").strip()
KEY = read(f"{CERT_DIR}/tls.key").strip()
API_KEY = read(API_KEY_FILE).strip()
HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
}


def scrub(text, limit=500):
    """Make API error text safe to log: no key material, bounded length."""
    text = re.sub(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)", "[REDACTED KEY]", str(text), flags=re.S)
    text = text.replace(API_KEY, "[REDACTED]") if API_KEY else text
    return text[:limit]


def api(method, path, body=None, params=None, tolerate_disconnect=False):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        print(f"{method} {path} failed: HTTP {e.code}")
        print(scrub(e.read().decode(errors="replace")))
        sys.exit(1)
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        if tolerate_disconnect:
            print(f"{method} {path}: connection dropped ({scrub(e)}); expected while the UI restarts")
            return None
        print(f"{method} {path} failed: {scrub(e)}")
        sys.exit(1)
    return json.loads(raw) if raw else None


def cert_id_of(value):
    """ui_certificate is an object on current releases and a bare id on older ones."""
    return value.get("id") if isinstance(value, dict) else value


def wait_for_job(job_id):
    for _ in range(60):
        jobs = api("GET", "/core/get_jobs/", params={"id": job_id})
        if jobs:
            state = jobs[0].get("state")
            if state == "SUCCESS":
                return
            if state in ("FAILED", "ABORTED"):
                print(f"Import job {job_id} {state}: {scrub(jobs[0].get('error'))}")
                sys.exit(1)
        time.sleep(1)
    print(f"Timed out waiting for import job {job_id}")
    sys.exit(1)


def list_certs():
    return api("GET", "/certificate/", params={"limit": 0}) or []


general = api("GET", "/system/general/")
active_id = cert_id_of(general.get("ui_certificate"))
certs = list_certs()

active = next((c for c in certs if c.get("id") == active_id), None)
if active and (active.get("certificate") or "").strip() == CERT:
    print(f"Active UI certificate '{active.get('name')}' already matches; nothing to do")
    sys.exit(0)

# <prefix>-<notBefore date>-<short fingerprint>; the fingerprint keeps two
# certificates issued on the same day from colliding.
not_before, sha256 = leaf_info(CERT)
name = f"{PREFIX}-{not_before}-{sha256[:8]}"

# Match by content, not name, so a re-run after a partial failure (imported but
# not yet activated) reuses the import even if the date has rolled over.
existing = next((c for c in certs if (c.get("certificate") or "").strip() == CERT), None)
if existing:
    print(f"Certificate '{existing.get('name')}' already imported (id {existing['id']})")
    new_id = existing["id"]
else:
    print(f"Importing certificate '{name}'")
    result = api(
        "POST",
        "/certificate/",
        body={
            "create_type": "CERTIFICATE_CREATE_IMPORTED",
            "name": name,
            "certificate": CERT,
            "privatekey": KEY,
        },
    )
    if isinstance(result, int):
        wait_for_job(result)
    new_id = None
    for _ in range(10):
        match = next((c for c in list_certs() if c.get("name") == name), None)
        if match:
            new_id = match["id"]
            break
        time.sleep(1)
    if new_id is None:
        print(f"Certificate '{name}' not found after import")
        sys.exit(1)

api("PUT", "/system/general/", body={"ui_certificate": new_id})
print(f"Set certificate id {new_id} as the UI certificate")

api("GET", "/system/general/ui_restart/", tolerate_disconnect=True)
print("Web UI restart requested")
