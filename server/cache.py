import time
from threading import Lock

MAX_ENTRIES = 500

_entries: dict = {}
# A fixed pool rather than a lock per key, so unbounded keys (any session ID
# a caller invents) cannot grow it. Two keys sharing a lock only wait longer.
_locks = [Lock() for _ in range(64)]


def cached(key, ttl: float, fetch):
    with _locks[hash(key) % len(_locks)]:
        now = time.monotonic()
        hit = _entries.get(key)
        if hit is not None and hit[0] > now:
            return hit[1]
        # A failed fetch raises here and is not cached, so the next caller retries.
        value = fetch()
        if len(_entries) >= MAX_ENTRIES:
            for stale in [
                k for k, (expires, _) in list(_entries.items()) if expires <= now
            ]:
                _entries.pop(stale, None)
        _entries[key] = (time.monotonic() + ttl, value)
        return value


def clear() -> None:
    _entries.clear()
