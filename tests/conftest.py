import os
import sys
from pathlib import Path

import pytest

ADMIN = ("admin", "test-admin-password")
READ_KEY = "test-read-key"

# app.py reads its credentials when it is imported.
os.environ["LEADERBOARD_ADMIN_USER"] = ADMIN[0]
os.environ["LEADERBOARD_ADMIN_PASSWORD"] = ADMIN[1]
os.environ["LEADERBOARD_READ_KEY"] = READ_KEY
sys.path.insert(0, str(Path(__file__).parent.parent / "server"))

import app
import db
import ratelimit
from fastapi.testclient import TestClient

DATA = Path(__file__).parent / "data"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "leaderboard.db")
    ratelimit.clear()
    return TestClient(app.app)


def bearer(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def device():
    def make(name: str, signed_in: bool = True) -> dict:
        token = f"test-device-{name}".ljust(24, "0")
        with db.session() as conn:
            conn.execute("INSERT OR IGNORE INTO devices (token) VALUES (?)", (token,))
            if signed_in:
                conn.execute(
                    "INSERT OR IGNORE INTO users (apple_sub, name) VALUES (?, ?)",
                    (name, name),
                )
                conn.execute(
                    """UPDATE devices SET user_id =
                           (SELECT id FROM users WHERE apple_sub = ?)
                       WHERE token = ?""",
                    (name, token),
                )
        return bearer(token)

    return make


@pytest.fixture
def drag_log() -> str:
    return (DATA / "drag_quarter_mile.csv").read_text()


TA_HEADER = (
    "# RaceRender Data: TrackAddict 5.0.5 (Mode: 2)\n"
    '"Time","Lap","Sector","GPS_Update","Latitude","Longitude","Speed (MPH)"\n'
)


def _marker(seconds: float) -> str:
    minutes, rest = divmod(seconds, 60)
    return f"00:{int(minutes):02d}:{rest:06.3f}"


def _rows(points: list[tuple[float, int, float]], miles: float) -> list[str]:
    # Due north, spread evenly so the lap covers `miles`.
    step = miles / 69.05 / max(len(points) - 1, 1)
    return [
        f"{t:.3f},{lap},0,1,{45 - i * step:.7f},-120.0000000,{mph:.1f}"
        for i, (t, lap, mph) in enumerate(points)
    ]


def lap_log(seconds: float, miles: float = 1.0) -> str:
    """A TrackAddict log whose lap 1 took `seconds` over about `miles`."""
    points = [(0.0, 0, 30.0), (1.0, 1, 30.0), (1.0 + seconds / 2, 1, 60.0)]
    points.append((1.0 + seconds, 1, 40.0))
    rows = _rows(points, miles)
    return (
        TA_HEADER
        + "\n".join(rows[:1])
        + "\n# Lap 0: 00:00:01.000\n"
        + "\n".join(rows[1:])
        + f"\n# Lap 1: {_marker(seconds)}\n"
    )


def drag_log_for(zero_to_60=None, zero_to_30=None) -> str:
    """A TrackAddict drag log whose lap 1 has exactly these times."""
    if zero_to_30 is None and zero_to_60 is not None:
        zero_to_30 = zero_to_60 / 2
    points = [(0.0, 0, 0.0), (1.0, 1, 0.0)]
    if zero_to_30 is not None:
        points.append((1.0 + zero_to_30, 1, 30.0))
    if zero_to_60 is not None:
        points.append((1.0 + zero_to_60, 1, 60.0))
    else:
        points.append((points[-1][0] + 1, 1, 40.0))
    end = points[-1][0] - 1.0
    rows = _rows(points, 0.2)
    return (
        TA_HEADER
        + rows[0]
        + "\n# Lap 0: 00:00:01.000\n"
        + "\n".join(rows[1:])
        + f"\n# Lap 1: {_marker(end)}\n"
    )
