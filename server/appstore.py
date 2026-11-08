"""TestFlight tester count from the App Store Connect API.

The server's own device count is every phone that ever ran the app and called
it, which includes App Review's phones, dev and simulator installs, Android,
and testers who have since left TestFlight. App Store Connect knows the actual
testers, so /api/stats reports its number when a key is set.

Needs an App Store Connect API key (Users and Access > Integrations > App Store
Connect API), stored with ./start.sh asc-key FILE ISSUER_ID. Run
`python server/appstore.py` to print what the API reports.
"""

import json
import logging
import os
import time
import urllib.parse
import urllib.request

import jwt

log = logging.getLogger(__name__)

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("APPLE_CLIENT_ID", "com.romangarms.Evergreen-AutoX-App-iOS")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID")
KEY_ID = os.environ.get("ASC_KEY_ID")
PRIVATE_KEY = os.environ.get("ASC_PRIVATE_KEY", "").replace("\\n", "\n")
# The app's numeric Apple ID; looked up from BUNDLE_ID when not set.
APP_ID = os.environ.get("ASC_APP_ID")


def configured() -> bool:
    return bool(ISSUER_ID and KEY_ID and PRIVATE_KEY)


def _get(path: str, params: dict) -> dict:
    now = int(time.time())
    token = jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        PRIVATE_KEY,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def _app_id() -> str:
    global APP_ID
    if not APP_ID:
        apps = _get("/apps", {"filter[bundleId]": BUNDLE_ID})["data"]
        match = [a for a in apps if a["attributes"]["bundleId"] == BUNDLE_ID]
        if not match:
            raise LookupError(f"No app with bundle ID {BUNDLE_ID}")
        APP_ID = match[0]["id"]
    return APP_ID


def tester_count() -> int:
    """Every TestFlight tester of the app, internal and public-link alike, the
    same number App Store Connect's TestFlight page adds up to."""
    body = _get("/betaTesters", {"filter[apps]": _app_id(), "limit": 1})
    return int(body["meta"]["paging"]["total"])


if __name__ == "__main__":
    if not configured():
        raise SystemExit(
            "No App Store Connect key: run ./start.sh asc-key FILE ISSUER_ID"
        )
    testers, cursor = [], {"filter[apps]": _app_id(), "limit": 200}
    while True:
        body = _get("/betaTesters", cursor)
        testers += body["data"]
        nxt = body.get("links", {}).get("next")
        if not nxt:
            break
        cursor = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(nxt).query))
    kinds: dict[str, int] = {}
    for tester in testers:
        kind = tester["attributes"].get("inviteType") or "unknown"
        kinds[kind] = kinds.get(kind, 0) + 1
    print(f"App {_app_id()}: {len(testers)} testers {kinds}")
    print(f"tester_count() = {tester_count()}")
