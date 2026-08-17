import re
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from html.parser import HTMLParser
from threading import Lock
from zoneinfo import ZoneInfo

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
        runs = [
            run
            for i, cell in enumerate(row[run_start:])
            if (run := _parse_run(i + 1, cell)) is not None
        ]
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
                "indexed": float(indexed) if _TIME_RE.fullmatch(indexed) else None,
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


def fetch_event(day: date) -> dict | None:
    # Past events never change, so cache them; today's page updates all day.
    cached = _event_cache.get(day)
    if cached is not None:
        return cached

    url = event_url(day)
    resp = _http.get(url)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()

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
    if day < today():
        _event_cache[day] = event
    return event


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


def list_events(year: int) -> list[dict]:
    with _probe_lock:
        to_probe = [
            d for d in _candidates(year) if d not in _found and d not in _missing
        ]
        if to_probe:
            with ThreadPoolExecutor(max_workers=8) as pool:
                statuses = pool.map(
                    lambda d: _http.head(event_url(d)).status_code, to_probe
                )
            for day, code in zip(to_probe, statuses):
                if code == 200:
                    _found.add(day)
                elif day < today():
                    _missing.add(day)
        return [
            {"date": d.isoformat(), "url": event_url(d)}
            for d in sorted(_found, reverse=True)
            if d.year == year
        ]
