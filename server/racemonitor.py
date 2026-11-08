"""Live timing from Race Monitor, served as Speedhive-shaped events.

Evergreen Speedway's timing goes live only to Race Monitor; Speedhive gets the
results after the event. This joins the feed Race Monitor's public web widget
uses, which its terms reserve for authorized apps: it is a TestFlight-only
experiment, to be dropped or replaced by an authorized feed before any App
Store release.

A discovery thread reads Race Monitor's live page for races whose name or
track matches RACEMONITOR_MATCH, plus races an admin added by ID. While a race
is inside its scheduled window, one thread holds its websocket (one
connection, like one browser tab) and records every session into SQLite, so
runs survive restarts and stay readable after the event. The feed only
carries laps from the moment it is joined, which is why the server records
rather than connecting on demand.

Recorded events and sessions get IDs from ID_OFFSET up, which Speedhive's
(millions) never reach and which still fit a 32-bit int, so both apps treat
them as Speedhive events without knowing the difference."""

import html
import json
import logging
import os
import re
import threading
import time
from collections import deque
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import cache
import db
import httpx
from rmonitor import Session
from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect

log = logging.getLogger(__name__)

LIVE_PAGE = "https://www.race-monitor.com/Live"
RACE_PAGE = "https://www.race-monitor.com/Live/Race/{race_id}"
RACE_LIST = "https://api.race-monitor.com/Info/WebRaceList"
ORIGIN = "https://api.race-monitor.com"

ID_OFFSET = 2_000_000_000
TZ = ZoneInfo("America/Los_Angeles")

DISCOVER_SECONDS = 600
LIST_SECONDS = 30
SAVE_SECONDS = 5
# How far outside a race's scheduled start and end it is still watched.
WINDOW = timedelta(hours=2)
MAX_PENDING_LINES = 5000

LOCATION = "Race Monitor live timing"


def enabled() -> bool:
    return os.environ.get("RACEMONITOR", "on").lower() not in ("0", "off", "false")


def match_pattern() -> str:
    return os.environ.get("RACEMONITOR_MATCH", "evergreen")


def now_local() -> datetime:
    return datetime.now(tz=TZ)


def _local(epoch: int | None) -> datetime | None:
    return datetime.fromtimestamp(epoch, tz=TZ) if epoch else None


def _text(fragment: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>|\s+", " ", fragment)).strip()


def parse_live_page(page: str) -> list[dict]:
    races = []
    for chunk in page.split('class="raceItem')[1:]:
        race_id = re.search(r"raceClicked\((\d+)", chunk)
        name = re.search(r'largeRaceText"><a[^>]*>(.*?)</a>', chunk, re.DOTALL)
        track = re.search(r'smallRaceText">\s*@\s*<a[^>]*>(.*?)</a>', chunk, re.DOTALL)
        when = re.search(r"add\w*Date\(\d+,\s*(\d+),\s*(\d+)\)", chunk)
        if not (race_id and name):
            continue
        races.append(
            {
                "id": int(race_id.group(1)),
                "name": _text(name.group(1)),
                "track": _text(track.group(1)) if track else None,
                "starts_at": int(when.group(1)) if when else None,
                "ends_at": int(when.group(2)) if when else None,
            }
        )
    return races


def parse_race_page(race_id: int, page: str) -> dict | None:
    name = re.search(r"<h2[^>]*>(.*?)</h2>", page, re.DOTALL)
    if not name:
        return None
    track = re.search(r"<span[^>]*>\s*@\s*(.*?)</span>", page, re.DOTALL)
    when = re.search(r"addCurrentDate\((\d+),\s*(\d+)\)", page)
    return {
        "id": race_id,
        "name": _text(name.group(1)),
        "track": _text(track.group(1)) if track else None,
        "starts_at": int(when.group(1)) if when else None,
        "ends_at": int(when.group(2)) if when else None,
    }


def fetch_race_info(race_id: int) -> dict | None:
    response = httpx.get(RACE_PAGE.format(race_id=race_id), timeout=10)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    return parse_race_page(race_id, response.text)


def live_race(race_id: int) -> dict | None:
    """None when Race Monitor does not list the race as current, {} while it
    is current but not receiving data, else what joining its socket needs."""
    response = httpx.get(
        RACE_LIST,
        params={"accountID": "", "seriesID": "", "raceID": race_id},
        timeout=10,
    )
    response.raise_for_status()
    body = response.json()
    race = next(
        (r for r in body.get("CurrentRaces") or [] if r.get("ID") == race_id), None
    )
    if race is None:
        return None
    if not race.get("ReceivingData"):
        return {}
    return {
        "host": body["LiveTimingHost"],
        "instance": race["Instance"],
        "token": body["LiveTimingToken"],
    }


def socket_url(live: dict) -> str:
    return f"wss://{live['host']}/instance/{live['instance']}/{live['token']}"


class Race:
    """Splits one race's feed into sessions by their $B, saving each one.

    $I and every reconnect leave the feed without a known session until the
    next $B, so the lines in between are held and replayed into whichever
    session that $B names; a session seen before carries on with its saved
    lap history instead of starting over."""

    def __init__(self, race_id: int, name: str, track: str | None):
        self.race_id = race_id
        self.name = name
        self.track = track
        self.lock = threading.Lock()
        # session row id -> Session, for the sessions this process has fed.
        self.sessions: dict[int, Session] = {}
        self.current: int | None = None
        self.pending: deque[str] = deque(maxlen=MAX_PENDING_LINES)
        self.dirty: set[int] = set()
        self.last_frame: float | None = None
        self.connected = False

    def rejoin(self) -> None:
        with self.lock:
            self.current = None
            self.pending.clear()

    def feed(self, frame: str) -> None:
        self.last_frame = time.time()
        for line in frame.splitlines():
            line = line.strip()
            if not line.startswith("$"):
                continue
            kind = line.split(",", 1)[0].upper()
            if kind == "$I":
                with self.lock:
                    self.current = None
                    self.pending.clear()
            elif kind == "$B":
                self._begin(line)
            else:
                with self.lock:
                    if self.current is None:
                        self.pending.append(line)
                    else:
                        self.sessions[self.current].feed(line)
                        self.dirty.add(self.current)

    def _begin(self, line: str) -> None:
        probe = Session()
        probe.feed(line)
        key = probe.session_id or probe.session_name
        session_id, session = _open_session(self, key, probe.session_name)
        with self.lock:
            session = self.sessions.setdefault(session_id, session)
            session.feed(line)
            for held in self.pending:
                session.feed(held)
            self.pending.clear()
            self.current = session_id
            self.dirty.add(session_id)

    def save(self) -> None:
        with self.lock:
            states = {
                session_id: (
                    self.sessions[session_id].session_name,
                    json.dumps(self.sessions[session_id].to_state()),
                    len(self.sessions[session_id].results()),
                )
                for session_id in self.dirty
            }
            self.dirty.clear()
        if not states:
            return
        stamp = now_local().isoformat(timespec="seconds")
        with db.session() as conn:
            conn.executemany(
                """UPDATE racemonitor_sessions
                   SET name = ?, state = ?, cars = ?, updated_at = ? WHERE id = ?""",
                [
                    (name or None, state, cars, stamp, session_id)
                    for session_id, (name, state, cars) in states.items()
                ],
            )

    def session(self, session_id: int) -> Session | None:
        return self.sessions.get(session_id)


def _open_session(race: Race, key: str, name: str) -> tuple[int, Session]:
    """The row for this race's session `key` today, made if new, with its
    saved state."""
    today = now_local()
    with db.session() as conn:
        conn.execute(
            """INSERT OR IGNORE INTO racemonitor_events (race_id, date, name, track)
               VALUES (?, ?, ?, ?)""",
            (race.race_id, today.date().isoformat(), race.name, race.track),
        )
        event_id = conn.execute(
            "SELECT id FROM racemonitor_events WHERE race_id = ? AND date = ?",
            (race.race_id, today.date().isoformat()),
        ).fetchone()["id"]
        stamp = today.isoformat(timespec="seconds")
        conn.execute(
            """INSERT OR IGNORE INTO racemonitor_sessions
                   (event_id, session_key, name, started_at, state, updated_at)
               VALUES (?, ?, ?, ?, '{}', ?)""",
            (event_id, key, name or None, stamp[:19], stamp),
        )
        row = conn.execute(
            """SELECT id, state FROM racemonitor_sessions
               WHERE event_id = ? AND session_key = ?""",
            (event_id, key),
        ).fetchone()
    return row["id"], Session.from_state(json.loads(row["state"]))


# race id -> the Race being followed, while its thread runs.
_live: dict[int, Race] = {}
_live_lock = threading.Lock()


def _race_row(race_id: int):
    with db.session() as conn:
        return conn.execute(
            "SELECT * FROM racemonitor_races WHERE id = ?", (race_id,)
        ).fetchone()


def wanted(row, now: datetime) -> bool:
    """Inside the race's scheduled window, or for a race added by hand without
    a schedule, the day it was added."""
    if row is None:
        return False
    starts, ends = _local(row["starts_at"]), _local(row["ends_at"])
    if starts and ends:
        return starts - WINDOW <= now <= ends + WINDOW
    added = datetime.fromisoformat(row["created_at"]).replace(tzinfo=ZoneInfo("UTC"))
    return added.astimezone(TZ).date() == now.date()


def _follow(race: Race, stop: threading.Event) -> None:
    while not stop.is_set() and wanted(_race_row(race.race_id), now_local()):
        try:
            live = live_race(race.race_id)
        except (httpx.HTTPError, ValueError) as error:
            log.warning("Race Monitor race list failed for %s: %s", race.race_id, error)
            live = {}
        if not live:
            stop.wait(LIST_SECONDS)
            continue
        race.rejoin()
        try:
            _stream(race, live, stop)
        except (ConnectionClosed, OSError, TimeoutError) as error:
            log.warning("Race Monitor feed for %s dropped: %s", race.race_id, error)
        finally:
            race.connected = False
            race.save()
        stop.wait(5)


def _stream(race: Race, live: dict, stop: threading.Event) -> None:
    with connect(socket_url(live), origin=ORIGIN, open_timeout=10) as socket:
        socket.send(f"$JOIN,{live['instance']},{live['token']}")
        race.connected = True
        saved = checked = time.monotonic()
        while not stop.is_set():
            try:
                frame = socket.recv(timeout=SAVE_SECONDS)
            except TimeoutError:
                frame = None
            if frame is not None:
                if isinstance(frame, bytes):
                    frame = frame.decode("utf-8", "replace")
                race.feed(frame)
            if time.monotonic() - saved >= SAVE_SECONDS:
                race.save()
                saved = time.monotonic()
            if time.monotonic() - checked >= 60:
                if not wanted(_race_row(race.race_id), now_local()):
                    return
                checked = time.monotonic()


def _run_race(race: Race, stop: threading.Event) -> None:
    try:
        _follow(race, stop)
    except Exception:
        log.exception("Race Monitor follower for %s failed", race.race_id)
    finally:
        race.save()
        with _live_lock:
            if _live.get(race.race_id) is race:
                del _live[race.race_id]


def _remember(found: dict, manual: bool = False) -> None:
    with db.session() as conn:
        conn.execute(
            """INSERT INTO racemonitor_races (id, name, track, starts_at, ends_at, manual)
               VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT (id) DO UPDATE SET
                   name = excluded.name, track = excluded.track,
                   starts_at = excluded.starts_at, ends_at = excluded.ends_at,
                   manual = MAX(manual, excluded.manual)""",
            (
                found["id"],
                found["name"],
                found.get("track"),
                found.get("starts_at"),
                found.get("ends_at"),
                int(manual),
            ),
        )


def discover() -> None:
    response = httpx.get(LIVE_PAGE, timeout=15)
    response.raise_for_status()
    pattern = re.compile(match_pattern(), re.IGNORECASE)
    for found in parse_live_page(response.text):
        if pattern.search(found["name"]) or pattern.search(found["track"] or ""):
            _remember(found)


def _ensure_followers(stop: threading.Event) -> None:
    now = now_local()
    with db.session() as conn:
        rows = conn.execute("SELECT * FROM racemonitor_races").fetchall()
    for row in rows:
        if not wanted(row, now):
            continue
        with _live_lock:
            if row["id"] in _live:
                continue
            race = _live[row["id"]] = Race(row["id"], row["name"], row["track"])
        threading.Thread(
            target=_run_race,
            args=(race, stop),
            name=f"racemonitor-{row['id']}",
            daemon=True,
        ).start()


_stop = threading.Event()
_wake = threading.Event()


def start() -> threading.Thread:
    def loop():
        while not _stop.is_set():
            try:
                discover()
            except (httpx.HTTPError, re.error) as error:
                log.warning("Race Monitor discovery failed: %s", error)
            for _ in range(DISCOVER_SECONDS // LIST_SECONDS):
                try:
                    _ensure_followers(_stop)
                except Exception:
                    log.exception("Race Monitor followers failed to start")
                _wake.wait(LIST_SECONDS)
                if _wake.is_set():
                    _wake.clear()
                if _stop.is_set():
                    return

    thread = threading.Thread(target=loop, name="racemonitor", daemon=True)
    thread.start()
    return thread


def add_race(race_id: int) -> dict | None:
    found = fetch_race_info(race_id)
    if found is None:
        return None
    _remember(found, manual=True)
    _wake.set()
    return found


def remove_race(race_id: int) -> bool:
    with db.session() as conn:
        removed = conn.execute(
            "DELETE FROM racemonitor_races WHERE id = ?", (race_id,)
        ).rowcount
    return bool(removed)


def delete_event(event_id: int) -> bool:
    with db.session() as conn:
        removed = conn.execute(
            "DELETE FROM racemonitor_events WHERE id = ?", (event_id - ID_OFFSET,)
        ).rowcount
    return bool(removed)


def is_id(value: int) -> bool:
    return value >= ID_OFFSET


def events() -> list[dict]:
    """Recorded events that have at least one car, Speedhive-shaped."""
    with db.session() as conn:
        rows = conn.execute(
            """SELECT e.id, e.name, e.date, e.track FROM racemonitor_events e
               WHERE EXISTS (SELECT 1 FROM racemonitor_sessions s
                             WHERE s.event_id = e.id AND s.cars > 0)
               ORDER BY e.date DESC, e.id DESC"""
        ).fetchall()
    return [
        {
            "id": ID_OFFSET + row["id"],
            "name": row["name"],
            "startDate": row["date"],
            "location": {"name": LOCATION, "lengthLabel": None},
            "sessions": None,
            "liveTiming": "racemonitor",
        }
        for row in rows
    ]


def merge_events(speedhive: list) -> list:
    """Speedhive's list plus recorded events on dates Speedhive has nothing
    for: once the official upload lands, the live copy steps aside."""
    dates = {
        str(event.get("startDate") or "")[:10]
        for event in speedhive
        if isinstance(event, dict)
    }
    extra = [event for event in events() if event["startDate"] not in dates]
    return extra + list(speedhive)


def sessions(event_id: int) -> list[dict] | None:
    with db.session() as conn:
        if not conn.execute(
            "SELECT 1 FROM racemonitor_events WHERE id = ?", (event_id - ID_OFFSET,)
        ).fetchone():
            return None
        rows = conn.execute(
            """SELECT id, name, started_at, state FROM racemonitor_sessions
               WHERE event_id = ? AND cars > 0 ORDER BY started_at""",
            (event_id - ID_OFFSET,),
        ).fetchall()
    result = []
    for row in rows:
        sort_mode = json.loads(row["state"]).get("sort_mode") or ""
        result.append(
            {
                "id": ID_OFFSET + row["id"],
                "name": row["name"],
                "eventId": event_id,
                "type": "qualify" if sort_mode.startswith("q") else "race",
                "startTime": row["started_at"],
                "resultStatus": "Live",
            }
        )
    return result


def _live_session(row_id: int) -> tuple[Race, Session] | None:
    with _live_lock:
        races = list(_live.values())
    for race in races:
        session = race.session(row_id)
        if session is not None:
            return race, session
    return None


def _stored(row_id: int) -> Session | None:
    def load():
        with db.session() as conn:
            row = conn.execute(
                "SELECT state FROM racemonitor_sessions WHERE id = ?", (row_id,)
            ).fetchone()
        return Session.from_state(json.loads(row["state"])) if row else None

    return cache.cached(("racemonitor-session", row_id), 10, load)


def _rows(session_id: int, read) -> list | None:
    row_id = session_id - ID_OFFSET
    live = _live_session(row_id)
    if live is not None:
        race, session = live
        with race.lock:
            return read(session)
    stored = _stored(row_id)
    return read(stored) if stored is not None else None


def results(session_id: int) -> list | None:
    return _rows(session_id, Session.results)


def laps(session_id: int) -> list | None:
    return _rows(session_id, Session.laps)


def status() -> dict:
    with db.session() as conn:
        races = conn.execute(
            "SELECT * FROM racemonitor_races ORDER BY COALESCE(starts_at, 0) DESC, id DESC"
        ).fetchall()
        recorded = conn.execute(
            """SELECT e.id, e.race_id, e.name, e.date,
                      COUNT(s.id) AS sessions, MAX(s.cars) AS cars,
                      MAX(s.updated_at) AS updated_at
               FROM racemonitor_events e
               LEFT JOIN racemonitor_sessions s ON s.event_id = e.id
               GROUP BY e.id ORDER BY e.date DESC, e.id DESC"""
        ).fetchall()
    with _live_lock:
        live = dict(_live)
    now = now_local()
    return {
        "enabled": enabled(),
        "match": match_pattern(),
        "races": [
            {
                "id": row["id"],
                "name": row["name"],
                "track": row["track"],
                "starts_at": row["starts_at"],
                "ends_at": row["ends_at"],
                "manual": bool(row["manual"]),
                "watching": wanted(row, now),
                "following": row["id"] in live,
                "connected": row["id"] in live and live[row["id"]].connected,
                "last_frame_age": (
                    round(time.time() - live[row["id"]].last_frame)
                    if row["id"] in live and live[row["id"]].last_frame
                    else None
                ),
            }
            for row in races
        ],
        "events": [
            {
                "id": ID_OFFSET + row["id"],
                "race_id": row["race_id"],
                "name": row["name"],
                "date": row["date"],
                "sessions": row["sessions"],
                "cars": row["cars"] or 0,
                "updated_at": row["updated_at"],
            }
            for row in recorded
        ],
    }
