import ipaddress
import time
from collections import deque
from threading import Lock

MAX_KEYS = 20000
# The longest window any bucket uses; older hits can never matter.
MAX_WINDOW = 3600

_hits: dict[tuple[str, str], deque] = {}
_lock = Lock()


# The server sits behind a reverse proxy (and Docker's port mapping), so the
# peer address is the proxy's for every caller. The proxy appends the address
# it saw to X-Forwarded-For, so only the last entry is trusted: anything to its
# left came from the caller. A caller reaching the port directly from outside
# the private ranges is taken at its own address and cannot spoof one.
def client_key(peer: str | None, forwarded_for: str | None) -> str:
    host = peer or "unknown"
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if forwarded_for and (address is None or address.is_private or address.is_loopback):
        last = forwarded_for.rsplit(",", 1)[-1].strip()
        try:
            address = ipaddress.ip_address(last)
            host = last
        except ValueError:
            pass
    # One IPv6 subscriber usually holds a whole /64, so that is one caller.
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is None:
        return str(ipaddress.ip_network(f"{address}/64", strict=False))
    return host


def hit(bucket: str, key: str, limit: int, window: float) -> float | None:
    """Count one request; return seconds to wait if it is over the limit."""
    now = time.monotonic()
    with _lock:
        if len(_hits) >= MAX_KEYS:
            _sweep(now)
        stamps = _hits.setdefault((bucket, key), deque())
        while stamps and stamps[0] <= now - window:
            stamps.popleft()
        if len(stamps) >= limit:
            return stamps[0] + window - now
        stamps.append(now)
        return None


# Drops callers with nothing recent; if every key is busy, forgets them all
# rather than growing without bound.
def _sweep(now: float) -> None:
    for key in [
        k for k, stamps in _hits.items() if not stamps or stamps[-1] <= now - MAX_WINDOW
    ]:
        del _hits[key]
    if len(_hits) >= MAX_KEYS:
        _hits.clear()


def clear() -> None:
    with _lock:
        _hits.clear()
