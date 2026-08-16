import sqlite3
from contextlib import contextmanager
from pathlib import Path

DB_PATH = Path(__file__).parent / "leaderboard.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS courses (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    distance_miles REAL,
    legacy_distance_miles REAL
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
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
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
    return f"{int(minutes)}:{rest:06.3f}"


def adjusted_seconds(run: sqlite3.Row | dict, course: sqlite3.Row | dict) -> float:
    time = run["time_seconds"]
    if run["legacy"] and course["distance_miles"] and course["legacy_distance_miles"]:
        return time * course["distance_miles"] / course["legacy_distance_miles"]
    return time


def run_to_dict(run: sqlite3.Row, course: sqlite3.Row | dict) -> dict:
    out = dict(run)
    out["legacy"] = bool(out["legacy"])
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
