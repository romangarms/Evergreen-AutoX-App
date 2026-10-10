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
