import hashlib
import hmac
import json
import logging
import os
import time
import urllib.parse
import urllib.request

import jwt

log = logging.getLogger(__name__)

ISSUER = "https://appleid.apple.com"
CLIENT_ID = os.environ.get("APPLE_CLIENT_ID", "com.romangarms.Evergreen-AutoX-App-iOS")

# Only revoking a sign-in needs these (a Sign in with Apple key from the
# developer portal). The key is the .p8 file's text; "\n" may stand in for its
# line breaks so it fits on one line of .env.
TEAM_ID = os.environ.get("APPLE_TEAM_ID")
KEY_ID = os.environ.get("APPLE_KEY_ID")
PRIVATE_KEY = os.environ.get("APPLE_PRIVATE_KEY", "").replace("\\n", "\n")

_keys = jwt.PyJWKClient(f"{ISSUER}/auth/keys")


class AppleError(Exception):
    pass


def _decode(token: str) -> dict:
    try:
        key = _keys.get_signing_key_from_jwt(token)
        return jwt.decode(
            token, key.key, algorithms=["RS256"], audience=CLIENT_ID, issuer=ISSUER
        )
    except jwt.PyJWTError as exc:
        raise AppleError(str(exc)) from exc


# The app hands Apple the SHA-256 of a nonce it made up and sends us the nonce
# itself, so an identity token lifted from somewhere else is useless without it.
def verify_identity_token(token: str, nonce: str) -> dict:
    claims = _decode(token)
    expected = hashlib.sha256(nonce.encode()).hexdigest()
    if not hmac.compare_digest(str(claims.get("nonce", "")), expected):
        raise AppleError("Nonce mismatch")
    return claims


# Apple posts one of these when someone changes how their Apple ID relates to
# the app. The event rides in the token as a JSON string.
def verify_notification(payload: str) -> dict:
    try:
        event = json.loads(_decode(payload).get("events", ""))
    except ValueError as exc:
        raise AppleError("Notification carries no event") from exc
    if not isinstance(event, dict):
        raise AppleError("Notification carries no event")
    return event


def can_revoke() -> bool:
    return bool(TEAM_ID and KEY_ID and PRIVATE_KEY)


def _post(path: str, fields: dict) -> dict:
    now = int(time.time())
    secret = jwt.encode(
        {"iss": TEAM_ID, "iat": now, "exp": now + 300, "aud": ISSUER, "sub": CLIENT_ID},
        PRIVATE_KEY,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )
    data = urllib.parse.urlencode(
        {"client_id": CLIENT_ID, "client_secret": secret, **fields}
    ).encode()
    request = urllib.request.Request(f"{ISSUER}{path}", data=data)
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else {}


# Apple wants a deleted account's sign-in revoked, which takes the refresh
# token this trades the app's one-time code for. Neither step may get in the
# way of signing in or deleting, so failures are logged and swallowed.
def exchange_code(code: str) -> str | None:
    if not can_revoke():
        return None
    try:
        return _post(
            "/auth/token", {"code": code, "grant_type": "authorization_code"}
        ).get("refresh_token")
    except (OSError, ValueError, jwt.PyJWTError):
        log.exception("Apple code exchange failed")
        return None


def revoke(refresh_token: str) -> None:
    if not can_revoke():
        return
    try:
        _post(
            "/auth/revoke",
            {"token": refresh_token, "token_type_hint": "refresh_token"},
        )
    except (OSError, ValueError, jwt.PyJWTError):
        log.exception("Apple token revocation failed")
