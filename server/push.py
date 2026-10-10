import logging
import os
import threading
import time

import httpx
import jwt

log = logging.getLogger(__name__)

# An APNs auth key from the developer portal (Keys > + > Apple Push
# Notifications service). Like the Sign in with Apple key, the .p8 text may use
# "\n" for its line breaks so it fits on one line of .env.
TEAM_ID = os.environ.get("APNS_TEAM_ID") or os.environ.get("APPLE_TEAM_ID")
KEY_ID = os.environ.get("APNS_KEY_ID")
PRIVATE_KEY = os.environ.get("APNS_PRIVATE_KEY", "").replace("\\n", "\n")
TOPIC = os.environ.get("APNS_TOPIC", "com.romangarms.Evergreen-AutoX-App-iOS")

# Builds from Xcode get sandbox tokens, TestFlight and the App Store
# production ones, and each only works against its own host.
HOSTS = {
    "production": "https://api.push.apple.com",
    "sandbox": "https://api.sandbox.push.apple.com",
}
# Apple refuses a provider token older than an hour and throttles one renewed
# more often than every 20 minutes.
TOKEN_SECONDS = 45 * 60

_lock = threading.Lock()
_token: tuple[float, str] | None = None
_http: httpx.Client | None = None


def configured() -> bool:
    return bool(TEAM_ID and KEY_ID and PRIVATE_KEY)


def _provider_token() -> str:
    global _token
    with _lock:
        now = time.time()
        if _token is None or now - _token[0] > TOKEN_SECONDS:
            _token = (
                now,
                jwt.encode(
                    {"iss": TEAM_ID, "iat": int(now)},
                    PRIVATE_KEY,
                    algorithm="ES256",
                    headers={"kid": KEY_ID},
                ),
            )
        return _token[1]


def _client() -> httpx.Client:
    global _http
    with _lock:
        if _http is None:
            # APNs only speaks HTTP/2.
            _http = httpx.Client(http2=True, timeout=10.0)
        return _http


class Gone(Exception):
    """The app was uninstalled or the token is not one Apple knows."""


# Apple's status and reason for one notification; (0, why) when it never got there.
def _post(device_token: str, environment: str, payload: dict) -> tuple[int, str]:
    try:
        response = _client().post(
            f"{HOSTS[environment]}/3/device/{device_token}",
            json=payload,
            headers={
                "authorization": f"bearer {_provider_token()}",
                "apns-topic": TOPIC,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-expiration": str(int(time.time()) + 3600),
            },
        )
    except (httpx.HTTPError, jwt.PyJWTError, ValueError) as exc:
        log.exception("APNs request failed")
        return 0, str(exc)
    if response.status_code == 200:
        return 200, ""
    try:
        reason = response.json().get("reason", "")
    except ValueError:
        reason = response.text
    return response.status_code, reason


def _is_gone(status: int, reason: str) -> bool:
    return status == 410 or reason in (
        "BadDeviceToken",
        "DeviceTokenNotForTopic",
        "Unregistered",
    )


# Returns normally once Apple has accepted the notification. Anything else but
# a dead token is logged and dropped: a missed notification is not worth a retry
# that could arrive after the next run.
def send(device_token: str, environment: str, payload: dict) -> None:
    if not configured():
        return
    status, reason = _post(device_token, environment, payload)
    if status == 200:
        return
    if _is_gone(status, reason):
        raise Gone(reason)
    log.warning("APNs refused a notification: %s %s", status, reason)


# For the dev console's test button: what Apple said, in words.
def try_send(device_token: str, environment: str, payload: dict) -> str:
    if not configured():
        return "No APNs key on the server (./start.sh push-key)"
    status, reason = _post(device_token, environment, payload)
    if status == 200:
        return "Sent"
    if _is_gone(status, reason):
        raise Gone(reason)
    return f"Apple refused it: {status} {reason}".strip()
