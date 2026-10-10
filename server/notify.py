"""Pushes a notification when a car someone follows posts a new time.

A background thread polls the events phones have asked about, plus today's
events when anyone follows people by name, through the same cache the app's
own requests use, so it adds at most one upstream fetch per page per TTL.
"""

import json
import logging
import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date, timedelta

import db
import push

log = logging.getLogger(__name__)

POLL_SECONDS = 15
# Without these a phone could have the server poll any number of made-up events.
MAX_WATCHES_PER_DEVICE = 10
MAX_EVENTS_PER_POLL = 40
# The same rule the app uses to tell a timed run from a lap in grid
# (Driver.maxRunSeconds and the 2x-fastest cutoff in Models.swift).
MAX_RUN_SECONDS = 300


@dataclass
class Run:
    key: str
    number: int
    seconds: float | None
    cones: int = 0
    dnf: bool = False


@dataclass
class Car:
    key: str
    number: str
    name: str
    car_class: str | None = None
    position: int | None = None
    class_position: int | None = None
    runs: list[Run] = field(default_factory=list)

    @property
    def best(self) -> float | None:
        times = [run.seconds for run in self.runs if run.seconds is not None]
        return min(times) if times else None


@dataclass
class Upstream:
    sessions: Callable[[int], list]
    results: Callable[[int], list]
    laps: Callable[[int], list]
    gglc_event: Callable[[date], dict | None]
    events: Callable[[int], list]


@dataclass
class Notice:
    device_id: int
    apns_token: str
    environment: str
    payload: dict


def gglc_event_id(day: date) -> int:
    return -int(day.strftime("%Y%m%d"))


def _gglc_day(event_id: int) -> date:
    digits = str(-event_id)
    return date(int(digits[:4]), int(digits[4:6]), int(digits[6:8]))


def _lap_seconds(text) -> float | None:
    if not isinstance(text, str) or not text:
        return None
    total = 0.0
    for part in text.split(":"):
        try:
            total = total * 60 + float(part)
        except ValueError:
            return None
    return total


def _speedhive_cars(upstream: Upstream, event_id: int) -> list[Car]:
    cars = []
    for session in upstream.sessions(event_id):
        session_id = session.get("id") if isinstance(session, dict) else None
        if session_id is None:
            continue
        laps_by_position = {
            row.get("position"): row.get("laps") or []
            for row in upstream.laps(session_id)
            if isinstance(row, dict)
        }
        for row in upstream.results(session_id):
            if not isinstance(row, dict):
                continue
            position = row.get("position")
            laps = laps_by_position.get(position, [])
            times = [_lap_seconds(lap.get("lapTime")) for lap in laps]
            valid = [t for t in times if t is not None and 0 < t < MAX_RUN_SECONDS]
            cutoff = min(MAX_RUN_SECONDS, min(valid) * 2) if valid else MAX_RUN_SECONDS
            runs = []
            for index, (lap, seconds) in enumerate(zip(laps, times)):
                if seconds is None or not 0 < seconds < cutoff:
                    continue
                lap_id = lap.get("lap")
                runs.append(
                    Run(
                        key=f"{session_id}:{index if lap_id is None else lap_id}",
                        number=len(runs) + 1,
                        seconds=seconds,
                    )
                )
            number = row.get("startNumber") or f"P{position}"
            cars.append(
                Car(
                    key=f"{session_id}:{number}",
                    number=number,
                    name=row.get("name") or "(unknown)",
                    car_class=row.get("resultClass"),
                    position=position,
                    class_position=row.get("positionInClass"),
                    runs=runs,
                )
            )
    return cars


# Ranked the way the app ranks a GGLC page (gglcDrivers in AppModel.swift), so
# the positions and the P-numbers of cars without one match what it shows.
def _gglc_cars(event: dict | None) -> list[Car]:
    if event is None:
        return []
    cars = []
    for klass in event.get("classes", []):
        for driver in klass.get("drivers", []):
            runs = [
                Run(
                    key=str(run["run"]),
                    number=run["run"],
                    seconds=run.get("total"),
                    cones=run.get("cones") or 0,
                    dnf=bool(run.get("dnf")),
                )
                for run in driver.get("runs", [])
                if run.get("total") is not None or run.get("dnf")
            ]
            name = driver.get("name") or ""
            if not name:
                vehicle = " ".join(
                    p for p in (driver.get("make"), driver.get("model")) if p
                )
                name = vehicle or (
                    f"Car {driver['car']}" if driver.get("car") else "(unknown)"
                )
            cars.append(
                Car(
                    key="",
                    number=driver.get("car") or "",
                    name=name,
                    car_class=driver.get("carClass") or klass.get("name"),
                    runs=runs,
                )
            )
    cars.sort(
        key=lambda c: (c.best is None, c.best or 0, c.name if c.best is None else "")
    )
    class_counts: dict = {}
    for index, car in enumerate(cars, start=1):
        class_counts[car.car_class] = class_counts.get(car.car_class, 0) + 1
        car.position = index
        car.class_position = class_counts[car.car_class]
        if not car.number:
            car.number = f"P{index}"
            # A P-number moves with the standings, so the name is what stays put.
            car.key = f"name:{_name_key(car.name)}"
        else:
            car.key = car.number
    return cars


def _name_key(name: str | None) -> str:
    return re.sub(r"\s+", " ", (name or "").strip()).casefold()


def _format(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.3f}"
    minutes = int(seconds // 60)
    return f"{minutes}:{seconds - minutes * 60:06.3f}"


def _run_text(run: Run) -> str:
    if run.dnf or run.seconds is None:
        return f"Run {run.number}: DNF"
    text = f"Run {run.number}: {_format(run.seconds)}"
    if run.cones:
        text += f" (+{run.cones} cone{'s' if run.cones != 1 else ''})"
    return text


def _standing(car: Car) -> str | None:
    parts = []
    if car.class_position and car.car_class:
        parts.append(f"P{car.class_position} in {car.car_class}")
    if car.position:
        parts.append(f"P{car.position} overall")
    return ", ".join(parts) or None


def _message(car: Car, run: Run, is_me: bool, me: Car | None) -> tuple[str, str]:
    earlier = [
        r.seconds for r in car.runs if r.seconds is not None and r.key != run.key
    ]
    personal_best = (
        run.seconds is not None and bool(earlier) and run.seconds < min(earlier)
    )
    lines = []
    if personal_best:
        lines.append("New best!")
    elif car.best is not None:
        lines.append(f"Best {_format(car.best)}.")
    if not is_me and me is not None and me.best is not None and car.best is not None:
        gap = car.best - me.best
        if abs(gap) < 0.0005:
            lines.append("Tied with you.")
        else:
            lines.append(f"{abs(gap):.2f} {'behind' if gap > 0 else 'ahead of'} you.")
    standing = _standing(car)
    if standing:
        lines.append(f"{standing}.")
    title = _run_text(run) if is_me else f"{car.name} · {_run_text(run)}"
    return title, " ".join(lines)


@dataclass
class Follower:
    device_id: int
    apns_token: str
    environment: str
    notify_me: bool
    notify_friends: bool
    me_name: str | None
    friend_names: set[str]
    watches: dict[int, tuple[str | None, set[str]]]


def _followers(conn, today: date) -> list[Follower]:
    yesterday = (today - timedelta(days=1)).isoformat()
    conn.execute("DELETE FROM push_watches WHERE event_date < ?", (yesterday,))
    followers = {}
    for row in conn.execute(
        """SELECT * FROM push_registrations
           WHERE notify_me = 1 OR notify_friends = 1"""
    ):
        followers[row["device_id"]] = Follower(
            device_id=row["device_id"],
            apns_token=row["apns_token"],
            environment=row["environment"],
            notify_me=bool(row["notify_me"]),
            notify_friends=bool(row["notify_friends"]),
            me_name=_name_key(row["me_name"]) or None,
            friend_names={_name_key(n) for n in json.loads(row["friend_names"] or "[]")}
            - {""},
            watches={},
        )
    for row in conn.execute("SELECT * FROM push_watches"):
        follower = followers.get(row["device_id"])
        if follower is not None:
            follower.watches[row["event_id"]] = (
                row["me"],
                set(json.loads(row["friends"])),
            )
    return list(followers.values())


class Watcher:
    def __init__(self, upstream: Upstream, org_id: int):
        self.upstream = upstream
        self.org_id = org_id
        # Run keys already seen per event and car. An event's first poll only
        # records what is there, so a restart or a new follower sends nothing old.
        self.seen: dict[int, dict[str, set[str]]] = {}

    def _todays_events(self, today: date) -> list[int]:
        ids = [gglc_event_id(today)]
        for event in self.upstream.events(self.org_id):
            if (
                isinstance(event, dict)
                and str(event.get("startDate") or "")[:10] == today.isoformat()
                and "autox" in str(event.get("name") or "").lower()
            ):
                ids.append(event["id"])
        return ids

    def _cars(self, event_id: int) -> list[Car]:
        if event_id < 0:
            return _gglc_cars(self.upstream.gglc_event(_gglc_day(event_id)))
        return _speedhive_cars(self.upstream, event_id)

    def poll(self, today: date) -> list[Notice]:
        with db.session() as conn:
            followers = _followers(conn, today)
        if not followers:
            self.seen.clear()
            return []
        event_ids = sorted({e for f in followers for e in f.watches})
        if any(f.me_name or f.friend_names for f in followers):
            try:
                event_ids += [
                    e for e in self._todays_events(today) if e not in event_ids
                ]
            except Exception:
                log.exception("Could not list today's events")
        event_ids = event_ids[:MAX_EVENTS_PER_POLL]

        notices = []
        for event_id in event_ids:
            try:
                cars = self._cars(event_id)
            except Exception:
                log.exception("Could not load event %s", event_id)
                continue
            before = self.seen.get(event_id)
            self.seen[event_id] = {car.key: {r.key for r in car.runs} for car in cars}
            if before is None:
                continue
            fresh = {}
            for car in cars:
                new = [r for r in car.runs if r.key not in before.get(car.key, set())]
                if new:
                    fresh[car.key] = new[-1]
            if fresh:
                for follower in followers:
                    notices += self._notices(follower, event_id, cars, fresh)
        for stale in set(self.seen) - set(event_ids):
            del self.seen[stale]
        return notices

    def _notices(self, follower: Follower, event_id: int, cars, fresh) -> list[Notice]:
        watch = follower.watches.get(event_id)
        if watch is not None:
            me_number, friend_numbers = watch

            def is_me(car):
                return me_number is not None and car.number == me_number

            def is_friend(car):
                return car.number in friend_numbers
        else:

            def is_me(car):
                return (
                    follower.me_name is not None
                    and _name_key(car.name) == follower.me_name
                )

            def is_friend(car):
                return _name_key(car.name) in follower.friend_names

        me = next((car for car in cars if is_me(car)), None)
        notices = []
        for car in cars:
            run = fresh.get(car.key)
            if run is None:
                continue
            if is_me(car):
                if not follower.notify_me:
                    continue
                mine = True
            elif is_friend(car):
                if not follower.notify_friends:
                    continue
                mine = False
            else:
                continue
            title, body = _message(car, run, mine, me)
            notices.append(
                Notice(
                    device_id=follower.device_id,
                    apns_token=follower.apns_token,
                    environment=follower.environment,
                    payload={
                        "aps": {
                            "alert": {"title": title, "body": body},
                            "sound": "default",
                            "thread-id": f"event-{event_id}",
                        },
                        "event_id": event_id,
                    },
                )
            )
        return notices


def deliver(notices: list[Notice]) -> None:
    gone = set()
    for notice in notices:
        if notice.device_id in gone:
            continue
        try:
            push.send(notice.apns_token, notice.environment, notice.payload)
        except push.Gone:
            gone.add(notice.device_id)
    if gone:
        with db.session() as conn:
            conn.executemany(
                "DELETE FROM push_registrations WHERE device_id = ?",
                [(device_id,) for device_id in gone],
            )


def start(watcher: Watcher, today: Callable[[], date]) -> threading.Thread:
    def loop():
        while True:
            started = time.monotonic()
            try:
                deliver(watcher.poll(today()))
            except Exception:
                log.exception("Notification poll failed")
            time.sleep(max(1.0, POLL_SECONDS - (time.monotonic() - started)))

    thread = threading.Thread(target=loop, name="notify", daemon=True)
    thread.start()
    return thread
