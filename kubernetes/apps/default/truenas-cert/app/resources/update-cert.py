"""Push the cert-manager wildcard certificate into TrueNAS and apply it to the web UI.

Idempotent: exits 0 without touching TrueNAS when the active UI certificate already
matches the mounted one, so it is safe to run on a frequent schedule.

Stdlib only (no pip), configured through the environment:
  TRUENAS_HOST       FQDN of the NAS
  CERT_NAME_PREFIX   prefix for the imported certificate name
  CERT_DIR           directory holding tls.crt / tls.key (default /certs)
  API_KEY_FILE       file holding the TrueNAS API key (default /secrets/api-key)
  ADDRESS_FILE       optional file holding the NAS IP (default /secrets/address). When
                     set, connect to that IP instead of resolving TRUENAS_HOST, while
                     still sending SNI and verifying the certificate for TRUENAS_HOST.
"""

import base64
import hashlib
import json
import os
import http.client
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = os.environ["TRUENAS_HOST"]
PREFIX = os.environ["CERT_NAME_PREFIX"]
CERT_DIR = os.environ.get("CERT_DIR", "/certs")
API_KEY_FILE = os.environ.get("API_KEY_FILE", "/secrets/api-key")
ADDRESS_FILE = os.environ.get("ADDRESS_FILE", "/secrets/address")
BASE = f"https://{HOST}/api/v2.0"


def log(message):
    print(f"[truenas-cert-update] {message}", flush=True)


def fail(message):
    log(f"ERROR: {message}")
    sys.exit(1)


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
ADDRESS = read(ADDRESS_FILE).strip() if os.path.exists(ADDRESS_FILE) else ""
# Tolerate a pasted URL: only the bare IP/host is wanted (scheme and path are ignored).
ADDRESS = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://", "", ADDRESS).split("/")[0]
HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
}


class _PinnedConnection(http.client.HTTPSConnection):
    """Dial ADDRESS but keep TLS SNI and hostname verification on the URL's host."""

    def connect(self):
        sock = socket.create_connection((ADDRESS, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class _PinnedHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_PinnedConnection, req, context=self._context)


OPENER = urllib.request.build_opener(_PinnedHandler()) if ADDRESS else urllib.request.build_opener()


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
    log(f"API {method} {path}")
    try:
        with OPENER.open(req, timeout=30) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        fail(f"{method} {path} returned HTTP {e.code}: {scrub(e.read().decode(errors='replace'))}")
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        if tolerate_disconnect:
            log(f"Connection dropped ({scrub(e)}); expected while the web UI restarts")
            return None
        fail(f"{method} {path} failed: {scrub(e)}")
    return json.loads(raw) if raw else None


def cert_id_of(value):
    """ui_certificate is an object on current releases and a bare id on older ones."""
    return value.get("id") if isinstance(value, dict) else value


def wait_for_job(job_id):
    log(f"Waiting for import job {job_id} to finish")
    for _ in range(60):
        jobs = api("GET", "/core/get_jobs/", params={"id": job_id})
        if jobs:
            state = jobs[0].get("state")
            if state == "SUCCESS":
                log(f"Import job {job_id} succeeded")
                return
            if state in ("FAILED", "ABORTED"):
                fail(f"Import job {job_id} {state}: {scrub(jobs[0].get('error'))}")
        time.sleep(1)
    fail(f"Timed out waiting for import job {job_id}")


def list_certs():
    return api("GET", "/certificate/", params={"limit": 0}) or []


log(f"Starting certificate sync for {HOST}")
not_before, sha256 = leaf_info(CERT)
log(f"Step 1/5: Loaded local certificate (issued {not_before}, sha256 {sha256[:8]})")
if ADDRESS:
    log(f"Connecting to {HOST} via pinned address from secret (DNS lookup skipped)")
else:
    log(f"Connecting to {HOST} via DNS (no pinned address configured)")

log("Step 2/5: Checking the certificate currently active on TrueNAS")
general = api("GET", "/system/general/")
active_id = cert_id_of(general.get("ui_certificate"))
certs = list_certs()
log(f"TrueNAS has {len(certs)} certificate(s) stored")

active = next((c for c in certs if c.get("id") == active_id), None)
if active and (active.get("certificate") or "").strip() == CERT:
    log(f"SKIPPED: active UI certificate '{active.get('name')}' (id {active_id}) already matches the local certificate; no changes made")
    sys.exit(0)
if active:
    log(f"Active UI certificate '{active.get('name')}' (id {active_id}) differs from the local certificate; update required")
else:
    log(f"No active UI certificate found (ui_certificate={active_id}); update required")

# <prefix>-<notBefore date>-<short fingerprint>; the fingerprint keeps two
# certificates issued on the same day from colliding.
name = f"{PREFIX}-{not_before}-{sha256[:8]}"

# Match by content, not name, so a re-run after a partial failure (imported but
# not yet activated) reuses the import even if the date has rolled over.
log("Step 3/5: Importing the certificate into TrueNAS")
existing = next((c for c in certs if (c.get("certificate") or "").strip() == CERT), None)
if existing:
    log(f"Certificate already imported as '{existing.get('name')}' (id {existing['id']}); reusing it instead of importing again")
    new_id = existing["id"]
else:
    log(f"Importing certificate as '{name}'")
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
        fail(f"Certificate '{name}' not found after import")
    log(f"Imported certificate '{name}' (id {new_id})")

log(f"Step 4/5: Setting certificate id {new_id} as the web UI certificate")
api("PUT", "/system/general/", body={"ui_certificate": new_id})
log("Web UI certificate updated")

log("Step 5/5: Restarting the TrueNAS web UI to apply the certificate")
api("GET", "/system/general/ui_restart/", tolerate_disconnect=True)
log("Web UI restart requested")
log(f"COMPLETED: TrueNAS now serves certificate id {new_id}")
