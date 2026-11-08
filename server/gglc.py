import json
import re
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from html.parser import HTMLParser
from threading import Lock
from zoneinfo import ZoneInfo

import db
import httpx

BASE_URL = "https://gglotus.org/gglotus.org/AXTimes/autoxresults{yyyymmdd}.html"

_http = httpx.Client(timeout=10.0, follow_redirects=True)

_TIME_RE = re.compile(r"^(\d+(?:\.\d+)?)(?:\+(\d+))?$")


def today() -> date:
    return datetime.now(tz=ZoneInfo("America/Los_Angeles")).date()


def parse_date(text: str) -> date:
    text = text.replace("-", "")
    if not re.fullmatch(r"\d{8}", text):
        raise ValueError(f"Invalid date {text!r}, expected YYYY-MM-DD or YYYYMMDD")
    return date(int(text[:4]), int(text[4:6]), int(text[6:8]))


def event_url(day: date) -> str:
    return BASE_URL.format(yyyymmdd=day.strftime("%Y%m%d"))


class _PageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.title = ""
        self.tables = []
        self._table = None
        self._row = None
        self._cell = None
        self._text_target = None

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = {"tag": tag, "attrs": dict(attrs), "text": ""}
        elif tag == "h1":
            self._text_target = "title"

    def handle_endtag(self, tag):
        if tag == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None
        elif tag == "tr" and self._row is not None:
            self._table.append(self._row)
            self._row = None
        elif tag in ("td", "th") and self._cell is not None:
            self._row.append(self._cell)
            self._cell = None
        elif tag == "h1":
            self._text_target = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell["text"] += data
        elif self._text_target == "title":
            self.title += data


def _parse_run(number: int, cell: dict) -> dict | None:
    text = cell["text"].strip()
    if not text:
        return None
    best = "lightgreen" in cell["attrs"].get("style", "")
    m = _TIME_RE.match(text)
    if m and float(m.group(1)) == 0:
        # A car that has started but not finished shows 0.000 on the live
        # page; that is a run in progress, not a time, so treat it as blank.
        return None
    if m:
        time = float(m.group(1))
        cones = int(m.group(2) or 0)
        # GGLC penalty is 1 second per cone; the Indexed column on the page
        # is (time + cones) * class index, which is how this was verified.
        return {
            "run": number,
            "raw": text,
            "time": time,
            "cones": cones,
            "dnf": False,
            "total": round(time + cones, 3),
            "best": best,
        }
    return {
        "run": number,
        "raw": text,
        "time": None,
        "cones": 0,
        "dnf": text.lower() == "dnf",
        "total": None,
        "best": best,
    }


# The sheet's run columns are not one per run: the morning block can have more
# columns than anyone used (2026-11-08 had Run 1-10, then the afternoon's Run 1-6
# beside it). A driver's runs are numbered in the order they appear, skipping
# blank cells, and `column` keeps the cell's position among the run columns so
# the compare view can still line two drivers' morning and afternoon runs up.
# Saved copies from before this carried the position in `run`.
def _renumber(runs: list[dict]) -> list[dict]:
    return [
        {**run, "run": number, "column": run.get("column", run["run"])}
        for number, run in enumerate(runs, 1)
    ]


def _parse_table(table: list) -> dict | None:
    if len(table) < 2 or not table[0]:
        return None
    class_name = table[0][0]["text"].strip()
    columns = [c["text"].strip() for c in table[1]]
    run_start = next(
        (i for i, c in enumerate(columns) if c.lower().startswith("run")),
        len(columns),
    )

    def col(texts, name):
        try:
            return texts[columns.index(name)]
        except (ValueError, IndexError):
            return ""

    drivers = []
    for row in table[2:]:
        texts = [c["text"].strip() for c in row]
        indexed = col(texts, "Indexed")
        runs = _renumber(
            [
                run
                for i, cell in enumerate(row[run_start:])
                if (run := _parse_run(i + 1, cell)) is not None
            ]
        )
        totals = [run["total"] for run in runs if run["total"] is not None]
        # GGLC only scores the first 5 runs (the lightgreen cell); we rank by
        # best of all runs and keep the scored one as "official".
        official = next(
            (run["total"] for run in runs if run["best"] and run["total"] is not None),
            None,
        )
        drivers.append(
            {
                "name": col(texts, "Name"),
                "car": col(texts, "Car"),
                "make": col(texts, "Make"),
                "model": col(texts, "Model"),
                "carClass": col(texts, "Class"),
                "indexed": float(indexed)
                if _TIME_RE.fullmatch(indexed) and float(indexed) > 0
                else None,
                "best": min(totals) if totals else None,
                "official": official,
                "runs": runs,
            }
        )
    return {
        "name": class_name,
        "runCount": len(columns) - run_start,
        "drivers": drivers,
    }


_event_cache: dict[date, dict] = {}


# GGLC sometimes publishes a page with a title and no result tables.
def has_results(event: dict) -> bool:
    return any(
        driver["runs"] for klass in event["classes"] for driver in klass["drivers"]
    )


def _stored(day: date) -> tuple[dict, bool] | None:
    with db.session() as conn:
        row = conn.execute(
            "SELECT event, final FROM gglc_events WHERE date = ?", (day.isoformat(),)
        ).fetchone()
    if row is None:
        return None
    event = json.loads(row["event"])
    # Copies saved before runs were renumbered still carry column positions.
    for klass in event["classes"]:
        for driver in klass["drivers"]:
            driver["runs"] = _renumber(driver["runs"])
    return event, bool(row["final"])


def _stored_days(year: int) -> set[date]:
    with db.session() as conn:
        rows = conn.execute(
            "SELECT date FROM gglc_events WHERE date LIKE ?", (f"{year}-%",)
        ).fetchall()
    return {date.fromisoformat(row["date"]) for row in rows}


_saved: dict[date, tuple[str, bool]] = {}


def save_event(event: dict, source: str, final: bool) -> None:
    day = date.fromisoformat(event["date"])
    payload = json.dumps(event, separators=(",", ":"))
    if _saved.get(day) == (payload, final):
        return
    with db.session() as conn:
        conn.execute(
            "INSERT INTO gglc_events (date, event, source, final, saved_at)"
            " VALUES (?, ?, ?, ?, datetime('now'))"
            " ON CONFLICT(date) DO UPDATE SET event = excluded.event,"
            " source = excluded.source, final = excluded.final,"
            " saved_at = excluded.saved_at",
            (day.isoformat(), payload, source, int(final)),
        )
    _saved[day] = (payload, final)


def fetch_event(day: date) -> dict | None:
    # Past events never change, so cache them; today's page updates all day,
    # and a page without results may still be filled in later.
    cached = _event_cache.get(day)
    if cached is not None:
        return cached

    stored = _stored(day)
    if stored is not None and stored[1]:
        _event_cache[day] = stored[0]
        return stored[0]

    url = event_url(day)
    try:
        resp = _http.get(url)
        if resp.status_code == 404:
            return stored[0] if stored else None
        resp.raise_for_status()
    except httpx.HTTPError:
        if stored:
            return stored[0]
        raise

    parser = _PageParser()
    parser.feed(resp.text)
    # "Updated HH:MMPM" is a <p> on current pages but bare text on older ones.
    updated = re.search(r"Updated\s*([^<\n]+)", resp.text)
    event = {
        "date": day.isoformat(),
        "url": url,
        "title": parser.title.strip(),
        "updated": updated.group(1).strip() if updated else "",
        "classes": [
            parsed for t in parser.tables if (parsed := _parse_table(t)) is not None
        ],
    }
    if stored is not None and not _replaces(day, event, stored[0]):
        return stored[0]
    if has_results(event):
        final = day < today()
        save_event(event, "gglc", final)
        if final:
            _event_cache[day] = event
    return event


# GGLC rewrites the page in place while it updates it, so a poll can catch it
# empty or cut short. A page with no results never replaces saved ones, and one
# with fewer runs than the saved copy only does once it has stayed short this
# long (a real correction), so a half-uploaded page never blanks the event.
SHRINK_GRACE = 120
_shrunk_since: dict[date, float] = {}


def _run_count(event: dict) -> int:
    return sum(
        len(driver["runs"]) for klass in event["classes"] for driver in klass["drivers"]
    )


def _replaces(day: date, event: dict, saved: dict) -> bool:
    if not has_results(event):
        return False
    if _run_count(event) >= _run_count(saved):
        _shrunk_since.pop(day, None)
        return True
    now = time.monotonic()
    if now - _shrunk_since.setdefault(day, now) < SHRINK_GRACE:
        return False
    _shrunk_since.pop(day, None)
    return True


_found: set[date] = set()
_missing: set[date] = set()
_probe_lock = Lock()


def _candidates(year: int) -> list[date]:
    end = min(date(year, 12, 31), today())
    day = date(year, 1, 1)
    days = []
    while day <= end:
        # GGLC autocrosses run on weekends (occasionally Fridays).
        if day.weekday() >= 4:
            days.append(day)
        day += timedelta(days=1)
    return days


def _is_listable(day: date) -> bool:
    # Today's event is listed before its first run so it can be followed live.
    if day >= today():
        return True
    # A page that can't be read right now stays listed; opening it reports why.
    try:
        event = fetch_event(day)
    except httpx.HTTPError:
        return True
    return event is not None and has_results(event)


def _probe(day: date) -> int | None:
    try:
        return _http.head(event_url(day)).status_code
    except httpx.HTTPError:
        return None


def list_events(year: int) -> list[dict]:
    stored = _stored_days(year)
    with _probe_lock:
        to_probe = [
            d
            for d in _candidates(year)
            if d not in _found and d not in _missing and d not in stored
        ]
        if to_probe:
            with ThreadPoolExecutor(max_workers=8) as pool:
                statuses = list(pool.map(_probe, to_probe))
            # A day whose probe failed is neither found nor missing, so the
            # next listing asks again instead of the whole list failing.
            for day, code in zip(to_probe, statuses):
                if code == 200:
                    _found.add(day)
                elif code == 404 and day < today():
                    _missing.add(day)
        days = sorted({d for d in _found if d.year == year} | stored, reverse=True)
    with ThreadPoolExecutor(max_workers=8) as pool:
        listable = pool.map(_is_listable, days)
    return [
        {"date": d.isoformat(), "url": event_url(d)}
        for d, ok in zip(days, listable)
        if ok
    ]
