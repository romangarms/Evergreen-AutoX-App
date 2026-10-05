import sqlite3
from contextlib import contextmanager
from pathlib import Path

DB_PATH = Path(__file__).parent / "leaderboard.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS courses (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    distance_miles REAL,
    legacy_distance_miles REAL,
    description TEXT,
    owner_id TEXT,
    created_by TEXT,
    created_at TEXT,
    hidden INTEGER NOT NULL DEFAULT 0,
    region TEXT,
    unlisted INTEGER NOT NULL DEFAULT 0,
    join_code TEXT
);
CREATE TABLE IF NOT EXISTS course_members (
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (course_id, device_id)
);
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY,
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    driver TEXT NOT NULL,
    vehicle TEXT,
    hp INTEGER,
    time_seconds REAL NOT NULL,
    avg_speed_mph REAL,
    top_speed_mph REAL,
    run_date TEXT,
    time_of_day TEXT,
    conditions TEXT,
    legacy INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    owner_id TEXT,
    hidden INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS reports (
    id INTEGER PRIMARY KEY,
    target_type TEXT NOT NULL,
    target_id INTEGER NOT NULL,
    reason TEXT,
    reporter_id TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS blocks (
    id INTEGER PRIMARY KEY,
    blocker_id TEXT NOT NULL,
    blocked_id TEXT NOT NULL,
    label TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (blocker_id, blocked_id)
);
CREATE TABLE IF NOT EXISTS bans (
    id INTEGER PRIMARY KEY,
    device_id TEXT NOT NULL UNIQUE,
    label TEXT,
    reason TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    apple_sub TEXT NOT NULL UNIQUE,
    name TEXT,
    email TEXT,
    apple_refresh_token TEXT,
    label TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS devices (
    id INTEGER PRIMARY KEY,
    token TEXT NOT NULL UNIQUE,
    label TEXT,
    first_seen TEXT,
    last_seen TEXT,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL
);
CREATE TABLE IF NOT EXISTS acceleration_entries (
    id INTEGER PRIMARY KEY,
    year INTEGER,
    vehicle TEXT NOT NULL,
    driver TEXT,
    hp INTEGER,
    weight_lb INTEGER,
    zero_to_30_seconds REAL,
    zero_to_60_seconds REAL,
    quarter_mile_seconds REAL,
    quarter_mile_mph REAL,
    eighth_mile_seconds REAL,
    eighth_mile_mph REAL,
    notes TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    hidden INTEGER NOT NULL DEFAULT 0,
    owner_id TEXT
);
"""

# Columns added after the first release. SQLite's ALTER TABLE can't add a
# column with a non-constant default, so created_at is nullable here and
# filled in by the INSERT.
ADDED_COLUMNS = [
    ("courses", "description", "TEXT"),
    ("courses", "owner_id", "TEXT"),
    ("courses", "created_by", "TEXT"),
    ("courses", "created_at", "TEXT"),
    ("runs", "owner_id", "TEXT"),
    ("courses", "hidden", "INTEGER NOT NULL DEFAULT 0"),
    ("runs", "hidden", "INTEGER NOT NULL DEFAULT 0"),
    ("courses", "region", "TEXT"),
    ("courses", "unlisted", "INTEGER NOT NULL DEFAULT 0"),
    ("courses", "join_code", "TEXT"),
    ("devices", "user_id", "INTEGER REFERENCES users(id) ON DELETE SET NULL"),
    ("acceleration_entries", "owner_id", "TEXT"),
    ("users", "label", "TEXT"),
]


def _migrate(conn: sqlite3.Connection) -> None:
    for table, column, decl in ADDED_COLUMNS:
        existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
    conn.commit()


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    _migrate(conn)
    return conn


@contextmanager
def session():
    conn = connect()
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def parse_time(value: float | str) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    parts = value.strip().split(":")
    if len(parts) > 3 or not all(parts):
        raise ValueError(f"Unrecognized time format: {value!r}")
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return seconds


def format_time(seconds: float) -> str:
    minutes, rest = divmod(seconds, 60)
    hours, minutes = divmod(int(minutes), 60)
    if not hours:
        return f"{minutes}:{rest:06.3f}"
    # Clients size their time column for m:ss.mmm, so an hours-long time only
    # carries a fraction when it has one.
    whole = float(rest).is_integer()
    return (
        f"{hours}:{minutes:02d}:{rest:02.0f}"
        if whole
        else f"{hours}:{minutes:02d}:{rest:06.3f}"
    )


def adjusted_seconds(run: sqlite3.Row | dict, course: sqlite3.Row | dict) -> float:
    time = run["time_seconds"]
    if run["legacy"] and course["distance_miles"] and course["legacy_distance_miles"]:
        return time * course["distance_miles"] / course["legacy_distance_miles"]
    return time


# The join code lets anyone add the board to their app, so only people who
# already have the board get it back.
def course_to_dict(
    course: sqlite3.Row,
    viewer_id: str | None = None,
    is_member: bool = False,
    is_admin: bool = False,
) -> dict:
    out = dict(course)
    owner = out.pop("owner_id")
    code = out.pop("join_code")
    out["has_owner"] = owner is not None
    out["hidden"] = bool(out["hidden"])
    out["unlisted"] = bool(out["unlisted"])
    out["is_owner"] = owner is not None and owner == viewer_id
    out["is_member"] = is_member
    out["join_code"] = code if (is_admin or is_member or out["is_owner"]) else None
    return out


# owner_id is the device's bearer token, so it must never leave the server.
def run_to_dict(
    run: sqlite3.Row, course: sqlite3.Row | dict, viewer_id: str | None = None
) -> dict:
    out = dict(run)
    owner = out.pop("owner_id", None)
    out["has_owner"] = owner is not None
    out["is_owner"] = owner is not None and owner == viewer_id
    out["legacy"] = bool(out["legacy"])
    out["hidden"] = bool(out["hidden"])
    out["time"] = format_time(out["time_seconds"])
    adj = adjusted_seconds(run, course)
    out["adjusted_seconds"] = round(adj, 3)
    out["adjusted_time"] = format_time(adj)
    distance = (
        course["legacy_distance_miles"] if out["legacy"] else course["distance_miles"]
    )
    if distance:
        out["avg_speed_mph"] = round(distance / out["time_seconds"] * 3600, 2)
    return out


def acceleration_to_dict(entry: sqlite3.Row, viewer_id: str | None = None) -> dict:
    out = dict(entry)
    owner = out.pop("owner_id")
    out["has_owner"] = owner is not None
    out["is_owner"] = owner is not None and owner == viewer_id
    out["hidden"] = bool(out["hidden"])
    return out


# Ranked by 0-60, then 0-30, with entries missing a time after those that have it.
def acceleration_sort_key(entry: sqlite3.Row | dict) -> tuple:
    sixty, thirty = entry["zero_to_60_seconds"], entry["zero_to_30_seconds"]
    return (sixty is None, sixty or 0, thirty is None, thirty or 0)
