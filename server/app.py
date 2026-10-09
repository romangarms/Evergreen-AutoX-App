import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Literal

import apple
import cache
import db
import gglc
import moderation
import trackaddict
from fastapi import Cookie, Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.security import (
    HTTPAuthorizationCredentials,
    HTTPBasic,
    HTTPBasicCredentials,
    HTTPBearer,
)
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from speedhive.generated.api.session_controller import get_all_lap_times
from speedhive.wrapper import SpeedhiveClient

app = FastAPI(title="AutoX Live server")

# The leaderboard site at romangarms.com/ar/ reads the API straight from the browser.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        origin.strip()
        for origin in os.environ.get(
            "LEADERBOARD_CORS_ORIGINS", "https://romangarms.com"
        ).split(",")
        if origin.strip()
    ],
    allow_methods=["GET"],
    allow_headers=["X-Leaderboard-Key"],
)
client = SpeedhiveClient.create()

STATIC_DIR = Path(__file__).parent / "static"

ADMIN_USER = os.environ.get("LEADERBOARD_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("LEADERBOARD_ADMIN_PASSWORD")
# What the website sends to read unlisted boards. It ships in the site's
# public bundle, so it must never grant more than reading: no join codes, no
# writes. Unset means nothing can use it.
READ_KEY = os.environ.get("LEADERBOARD_READ_KEY")
READ_KEY_HEADER = "X-Leaderboard-Key"
basic_auth = HTTPBasic(auto_error=False)
bearer_auth = HTTPBearer(auto_error=False)
SESSION_COOKIE = "admin_session"
SESSION_SECONDS = 30 * 24 * 60 * 60

# The app identifies itself with a random token it generated on first launch.
# Until the device signs in with Apple the token is the only proof of
# ownership, so it is stored as-is and never echoed back.
DEVICE_TOKEN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
MAX_COURSES_PER_OWNER = 20
MAX_ACCELERATION_PER_OWNER = 20
MAX_PENDING_SUBMISSIONS = 5
MAX_PROOF_BYTES = 4 * 1024 * 1024
# Matched against the file's first bytes: what the upload calls itself is not
# trusted, and the dev console must never be handed something a browser would
# render as a page.
PROOF_TYPES = {
    b"\xff\xd8\xff": ("jpg", "image/jpeg"),
    b"\x89PNG\r\n\x1a\n": ("png", "image/png"),
}
# A device that never signed in, posted, joined, blocked or reported is only a
# row; these bound how many of them the table keeps.
IDLE_DEVICE_DAYS = 90
MAX_IDLE_DEVICES = 5000
PRUNE_INTERVAL_SECONDS = 3600
USERNAME_REQUIRED = 428
# No 0/O or 1/I/L, since codes get read aloud and typed on a phone.
JOIN_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
JOIN_CODE_LENGTH = 8


@dataclass(frozen=True)
class Actor:
    device_id: str | None = None
    is_admin: bool = False
    reads_unlisted: bool = False
    user_id: int | None = None
    username: str | None = None

    @property
    def is_anonymous(self) -> bool:
        return self.device_id is None and not self.is_admin


def _check_admin(credentials: HTTPBasicCredentials) -> None:
    if not ADMIN_PASSWORD:
        raise HTTPException(
            status_code=503,
            detail="Admin login is disabled: set LEADERBOARD_ADMIN_PASSWORD",
        )
    user_ok = secrets.compare_digest(credentials.username.encode(), ADMIN_USER.encode())
    password_ok = secrets.compare_digest(
        credentials.password.encode(), ADMIN_PASSWORD.encode()
    )
    if not (user_ok and password_ok):
        raise HTTPException(status_code=401, detail="Invalid credentials")


# The key is derived from the credentials, so sessions survive a restart and
# changing the password signs every browser out.
def _sign_session(expires: int) -> str:
    key = hashlib.sha256(
        f"admin-session\0{ADMIN_USER}\0{ADMIN_PASSWORD}".encode()
    ).digest()
    signature = hmac.new(key, str(expires).encode(), hashlib.sha256).hexdigest()
    return f"{expires}.{signature}"


def _session_valid(request: Request, cookie: str) -> bool:
    if not ADMIN_PASSWORD:
        return False
    # SameSite does not stop other romangarms.com subdomains from sending the
    # cookie. Browsers omit the header on plain-HTTP LAN addresses.
    if request.headers.get("sec-fetch-site", "same-origin") != "same-origin":
        return False
    expires = cookie.partition(".")[0]
    if not (expires.isascii() and expires.isdigit()) or int(expires) < time.time():
        return False
    return secrets.compare_digest(cookie.encode(), _sign_session(int(expires)).encode())


def _record_device(conn, token: str) -> None:
    conn.execute(
        """INSERT INTO devices (token, first_seen, last_seen)
           VALUES (?, datetime('now'), datetime('now'))
           ON CONFLICT (token) DO UPDATE SET
               first_seen = COALESCE(first_seen, excluded.first_seen),
               last_seen = excluded.last_seen""",
        (token,),
    )


# Every column a device token or account id is stored in.
IDENTITY_COLUMNS = (
    ("courses", "owner_id"),
    ("runs", "owner_id"),
    ("acceleration_entries", "owner_id"),
    ("reports", "reporter_id"),
    ("blocks", "blocker_id"),
    ("blocks", "blocked_id"),
    ("bans", "device_id"),
    ("course_members", "device_id"),
    ("submissions", "owner_id"),
)
_IDENTITIES = " UNION ".join(
    f"SELECT {column} AS id FROM {table}" for table, column in IDENTITY_COLUMNS
)
_last_prune = 0.0


# Any well-formed token creates a row, so rows nothing depends on are dropped
# once they go stale or the table fills with them. A dropped device loses
# nothing: its row comes back the next time it calls.
def _prune_devices(conn) -> None:
    idle = f"""user_id IS NULL AND label IS NULL
               AND token NOT IN (SELECT id FROM ({_IDENTITIES}) WHERE id IS NOT NULL)"""
    conn.execute(
        f"""DELETE FROM devices WHERE {idle}
            AND (last_seen IS NULL OR last_seen < datetime('now', ?))""",
        (f"-{IDLE_DEVICE_DAYS} days",),
    )
    conn.execute(
        f"""DELETE FROM devices WHERE id IN (
                SELECT id FROM devices WHERE {idle}
                ORDER BY last_seen DESC, id DESC LIMIT -1 OFFSET ?)""",
        (MAX_IDLE_DEVICES,),
    )


# What a signed-in device's posts are filed under instead of its own token, so
# every phone on the account is the same owner. The colon keeps it from ever
# being accepted as a bearer token.
def _account_owner_id(apple_sub: str) -> str:
    return f"apple:{apple_sub}"


def _device_actor(token: str) -> Actor:
    global _last_prune
    with db.session() as conn:
        _record_device(conn, token)
        if time.monotonic() - _last_prune > PRUNE_INTERVAL_SECONDS:
            _last_prune = time.monotonic()
            _prune_devices(conn)
        user = conn.execute(
            """SELECT users.id, users.apple_sub, users.name FROM devices
               JOIN users ON users.id = devices.user_id WHERE devices.token = ?""",
            (token,),
        ).fetchone()
    if user is None:
        return Actor(device_id=token)
    return Actor(
        device_id=_account_owner_id(user["apple_sub"]),
        user_id=user["id"],
        username=user["name"],
    )


def get_actor(
    request: Request,
    basic: Annotated[HTTPBasicCredentials | None, Depends(basic_auth)],
    bearer: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_auth)],
    session: Annotated[str | None, Cookie(alias=SESSION_COOKIE)] = None,
    read_key: Annotated[str | None, Header(alias=READ_KEY_HEADER)] = None,
) -> Actor:
    if basic is not None:
        _check_admin(basic)
        return Actor(is_admin=True)
    if bearer is not None:
        if not DEVICE_TOKEN.match(bearer.credentials):
            raise HTTPException(status_code=401, detail="Malformed device token")
        return _device_actor(bearer.credentials)
    if session is not None and _session_valid(request, session):
        return Actor(is_admin=True)
    if read_key is not None:
        if not READ_KEY or not secrets.compare_digest(
            read_key.encode(), READ_KEY.encode()
        ):
            raise HTTPException(status_code=401, detail="Invalid read key")
        return Actor(reads_unlisted=True)
    return Actor()


def require_actor(actor: Annotated[Actor, Depends(get_actor)]) -> Actor:
    if actor.is_anonymous:
        raise HTTPException(
            status_code=401,
            detail="Authentication required: admin login or device token",
        )
    if actor.device_id is not None:
        with db.session() as conn:
            banned = conn.execute(
                "SELECT 1 FROM bans WHERE device_id = ?", (actor.device_id,)
            ).fetchone()
        if banned:
            raise HTTPException(
                status_code=403,
                detail="This device can no longer post: it broke the community guidelines",
            )
    return actor


def require_admin(actor: Annotated[Actor, Depends(get_actor)]) -> Actor:
    if not actor.is_admin:
        raise HTTPException(status_code=401, detail="Admin login required")
    return actor


def require_device_token(
    bearer: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_auth)],
) -> str:
    if bearer is None or not DEVICE_TOKEN.match(bearer.credentials):
        raise HTTPException(status_code=401, detail="Device token required")
    return bearer.credentials


ActorDep = Annotated[Actor, Depends(get_actor)]
DeviceTokenDep = Annotated[str, Depends(require_device_token)]
WriterDep = Annotated[Actor, Depends(require_actor)]
AdminDep = Annotated[Actor, Depends(require_admin)]


@app.get("/api/admin/session")
def get_admin_session(actor: ActorDep):
    return {"user": ADMIN_USER if actor.is_admin else None}


@app.post("/api/admin/session")
def create_admin_session(
    request: Request,
    response: Response,
    basic: Annotated[HTTPBasicCredentials | None, Depends(basic_auth)],
):
    if basic is None:
        raise HTTPException(status_code=401, detail="Admin login required")
    _check_admin(basic)
    response.set_cookie(
        SESSION_COOKIE,
        _sign_session(int(time.time()) + SESSION_SECONDS),
        max_age=SESSION_SECONDS,
        httponly=True,
        samesite="strict",
        # The reverse proxy terminates TLS; plain HTTP is only LAN development.
        secure=request.headers.get("x-forwarded-proto", request.url.scheme) == "https",
    )
    return {"user": ADMIN_USER}


@app.delete("/api/admin/session")
def delete_admin_session(response: Response):
    response.delete_cookie(SESSION_COOKIE)
    return {"user": None}


# Everyone watching an event polls these, so each upstream page is fetched at
# most once per TTL however many phones ask.
LIVE_TTL = 10
LIST_TTL = 60


def _fetch_laps(session_id: int) -> list:
    response = get_all_lap_times.sync_detailed(id=session_id, client=client.client)
    result = SpeedhiveClient._parse_response(response)
    if isinstance(result, dict):
        result = result.get("rows", result.get("laps", []))
    return result if isinstance(result, list) else []


def _raw_laps(session_id: int) -> list:
    return cache.cached(("laps", session_id), LIVE_TTL, lambda: _fetch_laps(session_id))


def _results(session_id: int) -> list:
    return cache.cached(
        ("results", session_id), LIVE_TTL, lambda: client.get_results(session_id)
    )


@app.get("/api/orgs/{org_id}")
def get_org(org_id: int):
    org = cache.cached(
        ("org", org_id), LIST_TTL, lambda: client.get_organization(org_id)
    )
    if org is None:
        raise HTTPException(status_code=404, detail=f"Organization {org_id} not found")
    return org


@app.get("/api/orgs/{org_id}/events")
def get_events(org_id: int, limit: int = 50, offset: int = 0):
    return cache.cached(
        ("events", org_id, limit, offset),
        LIST_TTL,
        lambda: client.get_events(org_id, limit=limit, offset=offset),
    )


@app.get("/api/events/{event_id}/sessions")
def get_sessions(event_id: int):
    return cache.cached(
        ("sessions", event_id), LIST_TTL, lambda: client.get_sessions(event_id)
    )


@app.get("/api/sessions/{session_id}/results")
def get_results(session_id: int):
    return _results(session_id)


@app.get("/api/sessions/{session_id}/laps")
def get_laps(session_id: int):
    return _raw_laps(session_id)


@app.get("/api/sessions/{session_id}/drivers")
def get_drivers(session_id: int):
    drivers = []
    for row in _results(session_id):
        if not isinstance(row, dict):
            continue
        drivers.append(
            {
                "position": row.get("position"),
                "name": row.get("name") or row.get("driverName") or "(unknown)",
                "startNumber": row.get("startNumber"),
                "carClass": row.get("resultClass"),
            }
        )
    return drivers


@app.get("/api/sessions/{session_id}/drivers/{position}")
def get_driver(session_id: int, position: int):
    result_row = next(
        (
            row
            for row in _results(session_id)
            if isinstance(row, dict) and row.get("position") == position
        ),
        None,
    )
    if result_row is None:
        raise HTTPException(
            status_code=404,
            detail=f"Position {position} not found in session {session_id}",
        )

    laps = [
        row
        for row in _raw_laps(session_id)
        if isinstance(row, dict) and row.get("position") == position
    ]
    return {"result": result_row, "laps": laps}


@app.get("/api/gglc/events")
def gglc_events(year: int | None = None):
    year = year or gglc.today().year
    return cache.cached(("gglc-events", year), LIST_TTL, lambda: gglc.list_events(year))


@app.get("/api/gglc/events/{event_date}")
def gglc_event(event_date: str):
    try:
        day = gglc.parse_date(event_date)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    event = cache.cached(("gglc-event", day), LIVE_TTL, lambda: gglc.fetch_event(day))
    if event is None:
        raise HTTPException(
            status_code=404, detail=f"No GGLC results for {day.isoformat()}"
        )
    return event


NameStr = Annotated[str, Field(min_length=1, max_length=80)]
ShortStr = Annotated[str | None, Field(max_length=80)]
LongStr = Annotated[str | None, Field(max_length=500)]
Miles = Annotated[float | None, Field(gt=0, le=100)]
Horsepower = Annotated[int | None, Field(ge=0, le=5000)]
Speed = Annotated[float | None, Field(ge=0, le=400)]
Seconds = Annotated[float | None, Field(gt=0, le=600)]


class CourseIn(BaseModel):
    name: NameStr
    distance_miles: Miles = None
    legacy_distance_miles: Miles = None
    description: LongStr = None
    created_by: ShortStr = None
    region: ShortStr = None
    unlisted: bool = False


class CourseUpdate(BaseModel):
    name: NameStr | None = None
    distance_miles: Miles = None
    legacy_distance_miles: Miles = None
    description: LongStr = None
    region: ShortStr = None
    unlisted: bool | None = None


class JoinIn(BaseModel):
    code: Annotated[str, Field(min_length=1, max_length=40)]


# How the admin names someone: an account by its users.id, or a device that
# has not signed in by its devices.id.
class PersonIn(BaseModel):
    kind: Literal["user", "device"]
    id: int


class PersonBanIn(PersonIn):
    reason: LongStr = None


class CourseOwnerIn(BaseModel):
    device_token: str | None = None
    person: PersonIn | None = None


class LabelIn(BaseModel):
    label: ShortStr


class MoveDeviceIn(BaseModel):
    user_id: int


class AccountUpdate(BaseModel):
    name: NameStr


class AppleNotification(BaseModel):
    payload: Annotated[str, Field(min_length=1, max_length=8000)]


class AppleSignIn(BaseModel):
    identity_token: Annotated[str, Field(min_length=1, max_length=8000)]
    nonce: Annotated[str, Field(min_length=16, max_length=200)]
    authorization_code: Annotated[str | None, Field(max_length=2000)] = None
    name: ShortStr = None


class HiddenIn(BaseModel):
    hidden: bool


class RunIn(BaseModel):
    driver: NameStr
    time: float | str
    vehicle: ShortStr = None
    hp: Horsepower = None
    avg_speed_mph: Speed = None
    top_speed_mph: Speed = None
    run_date: ShortStr = None
    time_of_day: ShortStr = None
    conditions: ShortStr = None
    legacy: bool = False
    notes: LongStr = None
    source: Annotated[str, Field(max_length=40)] = "manual"


class RunUpdate(BaseModel):
    driver: NameStr | None = None
    time: float | str | None = None
    vehicle: ShortStr = None
    hp: Horsepower = None
    avg_speed_mph: Speed = None
    top_speed_mph: Speed = None
    run_date: ShortStr = None
    time_of_day: ShortStr = None
    conditions: ShortStr = None
    legacy: bool | None = None
    notes: LongStr = None
    source: Annotated[str | None, Field(max_length=40)] = None


class AccelerationIn(BaseModel):
    vehicle: NameStr
    year: Annotated[int | None, Field(ge=1880, le=2100)] = None
    driver: ShortStr = None
    hp: Horsepower = None
    weight_lb: Annotated[int | None, Field(gt=0, le=200000)] = None
    zero_to_30_seconds: Seconds = None
    zero_to_60_seconds: Seconds = None
    quarter_mile_seconds: Seconds = None
    quarter_mile_mph: Speed = None
    eighth_mile_seconds: Seconds = None
    eighth_mile_mph: Speed = None
    notes: LongStr = None
    source: Annotated[str, Field(max_length=40)] = "manual"


class AccelerationUpdate(AccelerationIn):
    vehicle: NameStr | None = None
    source: Annotated[str | None, Field(max_length=40)] = None
    hidden: bool | None = None


# A time typed in by hand, with a photo to back it up. It only reaches a board
# once the admin approves it.
class SubmissionIn(BaseModel):
    course_id: int | None = None
    run: RunIn | None = None
    acceleration: AccelerationIn | None = None
    proof: Annotated[str, Field(min_length=1, max_length=MAX_PROOF_BYTES * 4 // 3 + 4)]


class ReviewIn(BaseModel):
    note: LongStr = None


class TargetIn(BaseModel):
    target_type: Literal["course", "run", "acceleration"]
    target_id: int


class ReportIn(TargetIn):
    reason: Annotated[str, Field(min_length=1, max_length=500)]


class BanIn(TargetIn):
    reason: LongStr = None


def _clean(value: str | None) -> str | None:
    if value is None:
        return None
    value = " ".join(value.split())
    return value or None


def _reject_blocked_words(actor: Actor, *values: str | None) -> None:
    if actor.is_admin:
        return
    if moderation.contains_blocked_word(*values):
        raise HTTPException(
            status_code=400,
            detail="That contains language the community guidelines don't allow",
        )


def _parse_time(value: float | str) -> float:
    try:
        seconds = db.parse_time(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not 0 < seconds < 24 * 3600:
        raise HTTPException(status_code=400, detail="Time must be under 24 hours")
    return seconds


# Hiding is the moderation tool: a hidden board or run does not exist for
# anyone but the admin, its owner included, so a poster cannot undo it.
def _get_course(conn, course_id: int, actor: Actor):
    course = conn.execute("SELECT * FROM courses WHERE id = ?", (course_id,)).fetchone()
    if (
        course is None
        or (course["hidden"] and not actor.is_admin)
        or not _listed_for(course, actor, _member_course_ids(conn, actor))
    ):
        raise HTTPException(status_code=404, detail=f"Course {course_id} not found")
    return course


def _member_course_ids(conn, actor: Actor) -> set[int]:
    if actor.device_id is None:
        return set()
    return {
        row["course_id"]
        for row in conn.execute(
            "SELECT course_id FROM course_members WHERE device_id = ?",
            (actor.device_id,),
        )
    }


# An unlisted board exists only for its creator, whoever joined with its
# code, the website's read key, and the admin. Everyone else, callers with no
# credentials included, gets a 404.
def _listed_for(course, actor: Actor, member_of: set[int]) -> bool:
    return (
        not course["unlisted"]
        or actor.is_admin
        or actor.reads_unlisted
        or _owns(course, actor)
        or course["id"] in member_of
    )


def _course_out(conn, course, actor: Actor) -> dict:
    return db.course_to_dict(
        course,
        actor.device_id,
        is_member=course["id"] in _member_course_ids(conn, actor),
        is_admin=actor.is_admin,
    )


def _new_join_code(conn) -> str:
    while True:
        code = "".join(
            secrets.choice(JOIN_CODE_ALPHABET) for _ in range(JOIN_CODE_LENGTH)
        )
        taken = conn.execute(
            "SELECT 1 FROM courses WHERE join_code = ?", (code,)
        ).fetchone()
        if not taken:
            return code


def _get_run(conn, run_id: int, actor: Actor):
    run = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
    if run is None or (run["hidden"] and not actor.is_admin):
        raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
    return run


def _blocked_ids(conn, actor: Actor) -> set[str]:
    if actor.device_id is None:
        return set()
    return {
        row["blocked_id"]
        for row in conn.execute(
            "SELECT blocked_id FROM blocks WHERE blocker_id = ?", (actor.device_id,)
        )
    }


# The poster's token and the name to remember them by.
def _target_poster(conn, target: TargetIn, actor: Actor) -> tuple[str | None, str]:
    if target.target_type == "course":
        course = _get_course(conn, target.target_id, actor)
        return course["owner_id"], course["created_by"] or course["name"]
    if target.target_type == "acceleration":
        entry = _get_acceleration(conn, target.target_id, actor)
        return entry["owner_id"], entry["driver"] or entry["vehicle"]
    run = _get_run(conn, target.target_id, actor)
    _get_course(conn, run["course_id"], actor)
    return run["owner_id"], run["driver"]


# The UNIQUE constraint on courses.name is case-sensitive, so this catches
# "hwy 9" vs "HWY 9" before the insert does not.
def _reject_duplicate_name(conn, name: str, exclude_id: int | None = None) -> None:
    clash = conn.execute(
        "SELECT id FROM courses WHERE name = ? COLLATE NOCASE", (name,)
    ).fetchone()
    if clash is not None and clash["id"] != exclude_id:
        raise HTTPException(
            status_code=409, detail=f"A leaderboard named {name!r} already exists"
        )


# Region is how the boards are grouped for display, so only an admin assigns it.
def _clean_region(region: str | None, actor: Actor) -> str | None:
    region = _clean(region)
    if region is not None and not actor.is_admin:
        raise HTTPException(
            status_code=403, detail="Only an admin can set a leaderboard's region"
        )
    return region.upper() if region else None


def _owns(row, actor: Actor) -> bool:
    return row["owner_id"] is not None and row["owner_id"] == actor.device_id


# Posting needs an account so a lost phone does not strand what was posted,
# and the account needs a username because Apple often shares no name and the
# admin has to tell accounts apart. Editing needs neither, or a device could
# not tidy up what it posted before.
def _require_account(actor: Actor) -> None:
    if actor.is_admin:
        return
    if actor.user_id is None:
        raise HTTPException(
            status_code=403,
            detail="Sign in with Apple to post. Update AutoX Live if you don't see how.",
        )
    if not actor.username:
        raise HTTPException(
            status_code=403, detail="Choose a username in Setup before posting."
        )


def _require_course_owner(course, actor: Actor) -> None:
    if not (actor.is_admin or _owns(course, actor)):
        raise HTTPException(
            status_code=403, detail="Only the leaderboard's creator can change it"
        )


# A run can be removed by whoever posted it or by whoever owns the board.
def _require_run_owner(run, course, actor: Actor) -> None:
    if not (actor.is_admin or _owns(run, actor) or _owns(course, actor)):
        raise HTTPException(
            status_code=403,
            detail="Only the run's poster or the board's creator can change it",
        )


@app.get("/api/leaderboard/courses")
def list_courses(actor: ActorDep, region: str | None = None):
    with db.session() as conn:
        blocked = _blocked_ids(conn, actor)
        member_of = _member_course_ids(conn, actor)
        return [
            db.course_to_dict(
                row,
                actor.device_id,
                is_member=row["id"] in member_of,
                is_admin=actor.is_admin,
            )
            for row in conn.execute("SELECT * FROM courses ORDER BY id")
            if (actor.is_admin or not row["hidden"])
            and _listed_for(row, actor, member_of)
            and row["owner_id"] not in blocked
            and (region is None or (row["region"] or "") == region.strip().upper())
        ]


@app.post("/api/leaderboard/courses")
def create_course(course: CourseIn, actor: WriterDep):
    name = _clean(course.name)
    if not name:
        raise HTTPException(status_code=400, detail="Name cannot be blank")
    region = _clean_region(course.region, actor)
    _require_account(actor)
    _reject_blocked_words(actor, name, course.description, course.created_by)
    with db.session() as conn:
        if actor.device_id is not None:
            owned = conn.execute(
                "SELECT COUNT(*) FROM courses WHERE owner_id = ?", (actor.device_id,)
            ).fetchone()[0]
            if owned >= MAX_COURSES_PER_OWNER:
                raise HTTPException(
                    status_code=429,
                    detail=f"Limit of {MAX_COURSES_PER_OWNER} leaderboards per device",
                )
        _reject_duplicate_name(conn, name)
        try:
            cur = conn.execute(
                """INSERT INTO courses (name, distance_miles, legacy_distance_miles,
                    description, owner_id, created_by, created_at, region,
                    unlisted, join_code)
                   VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?, ?, ?)""",
                (
                    name,
                    course.distance_miles,
                    course.legacy_distance_miles,
                    _clean(course.description),
                    actor.device_id,
                    _clean(course.created_by),
                    region,
                    int(course.unlisted),
                    _new_join_code(conn) if course.unlisted else None,
                ),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(
                status_code=409, detail=f"A leaderboard named {name!r} already exists"
            ) from exc
        return _course_out(conn, _get_course(conn, cur.lastrowid, actor), actor)


@app.patch("/api/leaderboard/courses/{course_id}")
def update_course(course_id: int, update: CourseUpdate, actor: WriterDep):
    fields = update.model_dump(exclude_unset=True)
    for key in ("name", "description"):
        if key in fields:
            fields[key] = _clean(fields[key])
    if fields.get("name", "x") is None:
        raise HTTPException(status_code=400, detail="Name cannot be blank")
    if "region" in fields:
        if not actor.is_admin:
            raise HTTPException(
                status_code=403, detail="Only an admin can set a leaderboard's region"
            )
        fields["region"] = _clean_region(fields["region"], actor)
    if fields.get("unlisted", 0) is None:
        del fields["unlisted"]
    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")
    _reject_blocked_words(actor, fields.get("name"), fields.get("description"))
    with db.session() as conn:
        course = _get_course(conn, course_id, actor)
        _require_course_owner(course, actor)
        if "unlisted" in fields:
            fields["unlisted"] = int(fields["unlisted"])
            if fields["unlisted"] and not course["join_code"]:
                fields["join_code"] = _new_join_code(conn)
        if "name" in fields:
            _reject_duplicate_name(conn, fields["name"], exclude_id=course_id)
        assignments = ", ".join(f"{name} = ?" for name in fields)
        try:
            conn.execute(
                f"UPDATE courses SET {assignments} WHERE id = ?",
                (*fields.values(), course_id),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(
                status_code=409,
                detail=f"A leaderboard named {fields['name']!r} already exists",
            ) from exc
        return _course_out(conn, _get_course(conn, course_id, actor), actor)


# Hands a board to a person from the Users panel or to a pasted device token
# (or back to nobody with neither); the only way an admin-created board gets
# an owner.
@app.put("/api/leaderboard/courses/{course_id}/owner")
def set_course_owner(course_id: int, owner: CourseOwnerIn, admin: AdminDep):
    token = owner.device_token.strip() if owner.device_token else None
    if token is not None and not DEVICE_TOKEN.match(token):
        raise HTTPException(status_code=400, detail="Malformed device token")
    if token is not None:
        token = _device_actor(token).device_id
    with db.session() as conn:
        _get_course(conn, course_id, admin)
        if owner.person is not None:
            token = _person_owner_id(conn, owner.person)
        conn.execute("UPDATE courses SET owner_id = ? WHERE id = ?", (token, course_id))
        return _course_out(conn, _get_course(conn, course_id, admin), admin)


@app.put("/api/leaderboard/courses/{course_id}/hidden")
def set_course_hidden(course_id: int, body: HiddenIn, admin: AdminDep):
    with db.session() as conn:
        _get_course(conn, course_id, admin)
        conn.execute(
            "UPDATE courses SET hidden = ? WHERE id = ?", (int(body.hidden), course_id)
        )
        return _course_out(conn, _get_course(conn, course_id, admin), admin)


@app.delete("/api/leaderboard/courses/{course_id}")
def delete_course(course_id: int, actor: WriterDep):
    with db.session() as conn:
        _require_course_owner(_get_course(conn, course_id, actor), actor)
        _delete_submissions(conn, "course_id = ?", (course_id,))
        conn.execute("DELETE FROM courses WHERE id = ?", (course_id,))
        return {"deleted": course_id}


@app.post("/api/leaderboard/join")
def join_course(body: JoinIn, actor: WriterDep):
    if actor.device_id is None:
        raise HTTPException(status_code=400, detail="Joining needs a device token")
    code = re.sub(r"[^A-Z0-9]", "", body.code.upper())
    with db.session() as conn:
        course = conn.execute(
            "SELECT * FROM courses WHERE join_code = ? AND unlisted = 1 AND hidden = 0",
            (code,),
        ).fetchone()
        if course is None:
            raise HTTPException(status_code=404, detail="No leaderboard has that code")
        conn.execute(
            "INSERT OR IGNORE INTO course_members (course_id, device_id) VALUES (?, ?)",
            (course["id"], actor.device_id),
        )
        return _course_out(conn, course, actor)


@app.delete("/api/leaderboard/courses/{course_id}/membership")
def leave_course(course_id: int, actor: ActorDep):
    with db.session() as conn:
        cur = conn.execute(
            "DELETE FROM course_members WHERE course_id = ? AND device_id = ?",
            (course_id, actor.device_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(
                status_code=404, detail=f"Not a member of course {course_id}"
            )
        return {"deleted": course_id}


def _members_out(conn, course_id: int) -> list[dict]:
    people = {person["owner"]: person for person in _people(conn)}
    out = []
    for row in conn.execute(
        """SELECT device_id, created_at FROM course_members
           WHERE course_id = ? ORDER BY created_at, rowid""",
        (course_id,),
    ):
        person = people.get(row["device_id"])
        if person is not None:
            out.append(
                {
                    **{key: person[key] for key in ("kind", "id", "label", "name")},
                    "names": person["names"],
                    "joined_at": row["created_at"],
                }
            )
    return out


@app.get("/api/leaderboard/courses/{course_id}/members")
def list_members(course_id: int, admin: AdminDep):
    with db.session() as conn:
        _get_course(conn, course_id, admin)
        return _members_out(conn, course_id)


# The same row a join code makes, without the person needing the code.
@app.post("/api/leaderboard/courses/{course_id}/members")
def add_member(course_id: int, person: PersonIn, admin: AdminDep):
    with db.session() as conn:
        _get_course(conn, course_id, admin)
        conn.execute(
            "INSERT OR IGNORE INTO course_members (course_id, device_id) VALUES (?, ?)",
            (course_id, _person_owner_id(conn, person)),
        )
        return _members_out(conn, course_id)


@app.delete("/api/leaderboard/courses/{course_id}/members/{kind}/{person_id}")
def remove_member(
    course_id: int, kind: Literal["user", "device"], person_id: int, admin: AdminDep
):
    with db.session() as conn:
        _get_course(conn, course_id, admin)
        conn.execute(
            "DELETE FROM course_members WHERE course_id = ? AND device_id = ?",
            (course_id, _person_owner_id(conn, PersonIn(kind=kind, id=person_id))),
        )
        return _members_out(conn, course_id)


@app.get("/api/leaderboard/courses/{course_id}")
def get_leaderboard(course_id: int, actor: ActorDep):
    with db.session() as conn:
        course = _get_course(conn, course_id, actor)
        blocked = _blocked_ids(conn, actor)
        runs = [
            db.run_to_dict(row, course, actor.device_id)
            for row in conn.execute(
                "SELECT * FROM runs WHERE course_id = ?", (course_id,)
            )
            if (actor.is_admin or not row["hidden"]) and row["owner_id"] not in blocked
        ]
        runs.sort(key=lambda r: r["adjusted_seconds"])
        return {"course": _course_out(conn, course, actor), "runs": runs}


# The checked, cleaned columns of a new run, shared by posting one and by
# submitting one for review.
def _run_fields(run: RunIn, actor: Actor) -> dict:
    fields = {
        "driver": _clean(run.driver),
        "vehicle": _clean(run.vehicle),
        "hp": run.hp,
        "time_seconds": _parse_time(run.time),
        "avg_speed_mph": run.avg_speed_mph,
        "top_speed_mph": run.top_speed_mph,
        "run_date": _clean(run.run_date),
        "time_of_day": _clean(run.time_of_day),
        "conditions": _clean(run.conditions),
        "legacy": int(run.legacy),
        "notes": _clean(run.notes),
        "source": run.source,
    }
    if not fields["driver"]:
        raise HTTPException(status_code=400, detail="Driver cannot be blank")
    _require_account(actor)
    _reject_blocked_words(
        actor,
        *(fields[key] for key in ("driver", "vehicle", "conditions", "notes")),
    )
    return fields


def _insert_row(conn, table: str, fields: dict) -> int:
    cur = conn.execute(
        f"""INSERT INTO {table} ({", ".join(fields)})
            VALUES ({", ".join("?" for _ in fields)})""",
        tuple(fields.values()),
    )
    return cur.lastrowid


@app.post("/api/leaderboard/courses/{course_id}/runs")
def create_run(course_id: int, run: RunIn, actor: WriterDep):
    fields = _run_fields(run, actor)
    with db.session() as conn:
        course = _get_course(conn, course_id, actor)
        run_id = _insert_row(
            conn,
            "runs",
            {**fields, "course_id": course_id, "owner_id": actor.device_id},
        )
        return db.run_to_dict(_get_run(conn, run_id, actor), course, actor.device_id)


@app.patch("/api/leaderboard/runs/{run_id}")
def update_run(run_id: int, update: RunUpdate, actor: WriterDep):
    fields = update.model_dump(exclude_unset=True)
    if "time" in fields:
        fields["time_seconds"] = _parse_time(fields.pop("time"))
    if "legacy" in fields:
        fields["legacy"] = int(fields["legacy"])
    for key in ("driver", "vehicle", "run_date", "time_of_day", "conditions", "notes"):
        if key in fields:
            fields[key] = _clean(fields[key])
    if fields.get("driver", "x") is None:
        raise HTTPException(status_code=400, detail="Driver cannot be blank")
    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")
    _reject_blocked_words(
        actor,
        *(fields.get(key) for key in ("driver", "vehicle", "conditions", "notes")),
    )
    with db.session() as conn:
        row = _get_run(conn, run_id, actor)
        course = _get_course(conn, row["course_id"], actor)
        _require_run_owner(row, course, actor)
        assignments = ", ".join(f"{name} = ?" for name in fields)
        conn.execute(
            f"UPDATE runs SET {assignments} WHERE id = ?",
            (*fields.values(), run_id),
        )
        return db.run_to_dict(_get_run(conn, run_id, actor), course, actor.device_id)


@app.put("/api/leaderboard/runs/{run_id}/hidden")
def set_run_hidden(run_id: int, body: HiddenIn, admin: AdminDep):
    with db.session() as conn:
        row = _get_run(conn, run_id, admin)
        conn.execute(
            "UPDATE runs SET hidden = ? WHERE id = ?", (int(body.hidden), run_id)
        )
        course = _get_course(conn, row["course_id"], admin)
        return db.run_to_dict(_get_run(conn, run_id, admin), course)


@app.delete("/api/leaderboard/runs/{run_id}")
def delete_run(run_id: int, actor: WriterDep):
    with db.session() as conn:
        row = _get_run(conn, run_id, actor)
        _require_run_owner(row, _get_course(conn, row["course_id"], actor), actor)
        conn.execute("DELETE FROM runs WHERE id = ?", (run_id,))
        return {"deleted": run_id}


@app.post("/api/leaderboard/reports", status_code=201)
def create_report(report: ReportIn, actor: WriterDep):
    with db.session() as conn:
        _target_poster(conn, report, actor)
        cur = conn.execute(
            "INSERT INTO reports (target_type, target_id, reason, reporter_id) VALUES (?, ?, ?, ?)",
            (
                report.target_type,
                report.target_id,
                _clean(report.reason),
                actor.device_id,
            ),
        )
        return {"id": cur.lastrowid}


@app.get("/api/leaderboard/reports")
def list_reports(_: AdminDep):
    with db.session() as conn:
        out = []
        for row in conn.execute("SELECT * FROM reports ORDER BY id DESC"):
            report = dict(row)
            report.pop("reporter_id")
            if row["target_type"] == "course":
                target = conn.execute(
                    """SELECT id, name, hidden, owner_id IS NOT NULL AS has_owner
                       FROM courses WHERE id = ?""",
                    (row["target_id"],),
                ).fetchone()
                report["target"] = dict(target) if target else None
            elif row["target_type"] == "acceleration":
                target = conn.execute(
                    """SELECT id, vehicle, driver, hidden,
                              owner_id IS NOT NULL AS has_owner
                       FROM acceleration_entries WHERE id = ?""",
                    (row["target_id"],),
                ).fetchone()
                report["target"] = dict(target) if target else None
            else:
                target = conn.execute(
                    """SELECT runs.id, runs.driver, runs.time_seconds, runs.course_id,
                              runs.hidden, runs.owner_id IS NOT NULL AS has_owner,
                              courses.name AS course_name
                       FROM runs JOIN courses ON courses.id = runs.course_id
                       WHERE runs.id = ?""",
                    (row["target_id"],),
                ).fetchone()
                report["target"] = dict(target) if target else None
                if target:
                    report["target"]["time"] = db.format_time(target["time_seconds"])
            out.append(report)
        return out


@app.delete("/api/leaderboard/reports/{report_id}")
def delete_report(report_id: int, _: AdminDep):
    with db.session() as conn:
        cur = conn.execute("DELETE FROM reports WHERE id = ?", (report_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"Report {report_id} not found")
        return {"deleted": report_id}


def _block_to_dict(row) -> dict:
    return {"id": row["id"], "label": row["label"], "created_at": row["created_at"]}


# Blocking is per device and one-way: the blocker stops seeing everything the
# poster owns, and the block is filed as a report so the admin hears about it.
@app.post("/api/leaderboard/blocks", status_code=201)
def create_block(target: TargetIn, actor: WriterDep):
    if actor.device_id is None:
        raise HTTPException(
            status_code=400, detail="Blocking needs a device token; admins ban instead"
        )
    with db.session() as conn:
        poster, label = _target_poster(conn, target, actor)
        if poster is None:
            raise HTTPException(
                status_code=400, detail="This entry has no poster to block"
            )
        if poster == actor.device_id:
            raise HTTPException(status_code=400, detail="You cannot block yourself")
        added = conn.execute(
            "INSERT OR IGNORE INTO blocks (blocker_id, blocked_id, label) VALUES (?, ?, ?)",
            (actor.device_id, poster, label),
        )
        if added.rowcount:
            conn.execute(
                "INSERT INTO reports (target_type, target_id, reason, reporter_id) VALUES (?, ?, ?, ?)",
                (
                    target.target_type,
                    target.target_id,
                    "Poster blocked",
                    actor.device_id,
                ),
            )
        return _block_to_dict(
            conn.execute(
                "SELECT * FROM blocks WHERE blocker_id = ? AND blocked_id = ?",
                (actor.device_id, poster),
            ).fetchone()
        )


@app.get("/api/leaderboard/blocks")
def list_blocks(actor: ActorDep):
    with db.session() as conn:
        return [
            _block_to_dict(row)
            for row in conn.execute(
                "SELECT * FROM blocks WHERE blocker_id = ? ORDER BY id DESC",
                (actor.device_id,),
            )
        ]


@app.delete("/api/leaderboard/blocks/{block_id}")
def delete_block(block_id: int, actor: ActorDep):
    with db.session() as conn:
        cur = conn.execute(
            "DELETE FROM blocks WHERE id = ? AND blocker_id = ?",
            (block_id, actor.device_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"Block {block_id} not found")
        return {"deleted": block_id}


def _ban_to_dict(row) -> dict:
    return {key: row[key] for key in ("id", "label", "reason", "created_at")}


# A ban stops the device writing and hides everything it has posted. Lifting it
# leaves that content hidden; unhide what should come back.
@app.post("/api/leaderboard/bans", status_code=201)
def create_ban(ban: BanIn, admin: AdminDep):
    with db.session() as conn:
        poster, label = _target_poster(conn, ban, admin)
        if poster is None:
            raise HTTPException(
                status_code=400, detail="This entry has no poster to ban"
            )
        return _ban(conn, poster, label, ban.reason)


def _ban(conn, poster: str, label: str | None, reason: str | None) -> dict:
    conn.execute(
        "INSERT OR IGNORE INTO bans (device_id, label, reason) VALUES (?, ?, ?)",
        (poster, label, _clean(reason)),
    )
    conn.execute("UPDATE courses SET hidden = 1 WHERE owner_id = ?", (poster,))
    conn.execute("UPDATE runs SET hidden = 1 WHERE owner_id = ?", (poster,))
    conn.execute(
        "UPDATE acceleration_entries SET hidden = 1 WHERE owner_id = ?", (poster,)
    )
    _delete_submissions(conn, "owner_id = ? AND status = 'pending'", (poster,))
    return _ban_to_dict(
        conn.execute("SELECT * FROM bans WHERE device_id = ?", (poster,)).fetchone()
    )


# The same ban a report leads to, for someone picked in the Users panel.
@app.post("/api/admin/bans", status_code=201)
def ban_person(ban: PersonBanIn, _: AdminDep):
    with db.session() as conn:
        owner = _person_owner_id(conn, ban)
        person = next(p for p in _people(conn) if p["owner"] == owner)
        label = person["label"] or person["name"] or next(iter(person["names"]), None)
        return _ban(conn, owner, label, ban.reason)


@app.get("/api/leaderboard/bans")
def list_bans(_: AdminDep):
    with db.session() as conn:
        return [
            _ban_to_dict(row)
            for row in conn.execute("SELECT * FROM bans ORDER BY id DESC")
        ]


@app.delete("/api/leaderboard/bans/{ban_id}")
def delete_ban(ban_id: int, _: AdminDep):
    with db.session() as conn:
        cur = conn.execute("DELETE FROM bans WHERE id = ?", (ban_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"Ban {ban_id} not found")
        return {"deleted": ban_id}


# The string a person's rows are filed under. A signed-in device stands for
# its account.
def _person_owner_id(conn, person: PersonIn) -> str:
    if person.kind == "user":
        row = conn.execute(
            "SELECT apple_sub, NULL AS token FROM users WHERE id = ?", (person.id,)
        ).fetchone()
    else:
        row = conn.execute(
            """SELECT users.apple_sub, devices.token FROM devices
               LEFT JOIN users ON users.id = devices.user_id WHERE devices.id = ?""",
            (person.id,),
        ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=404, detail=f"No {person.kind} with id {person.id}"
        )
    return _account_owner_id(row["apple_sub"]) if row["apple_sub"] else row["token"]


# One entry per account, with its devices nested, and one per device that has
# not signed in. An account signed out everywhere still owns its posts, so it
# is listed with no devices. `owner` is the token or account id the entry's
# rows are filed under and must be dropped before an entry leaves the server.
def _people(conn) -> list[dict]:
    # Tokens that posted before the server kept this table and have not been
    # back since; they stay without a first_seen.
    conn.execute(
        f"""INSERT OR IGNORE INTO devices (token)
            SELECT id FROM ({_IDENTITIES})
            WHERE id IS NOT NULL AND id NOT LIKE 'apple:%'"""
    )
    names: dict[str, Counter] = defaultdict(Counter)
    counts: dict[str, Counter] = defaultdict(Counter)
    owned: dict[str, list[int]] = defaultdict(list)
    joined: dict[str, list[int]] = defaultdict(list)
    for table, name_column in (
        ("courses", "created_by"),
        ("runs", "driver"),
        ("acceleration_entries", "driver"),
    ):
        for row in conn.execute(
            f"SELECT owner_id, {name_column} AS name FROM {table} WHERE owner_id IS NOT NULL"
        ):
            counts[table][row["owner_id"]] += 1
            if row["name"]:
                names[row["owner_id"]][row["name"]] += 1
    for row in conn.execute(
        "SELECT id, owner_id FROM courses WHERE owner_id IS NOT NULL"
    ):
        owned[row["owner_id"]].append(row["id"])
    for row in conn.execute("SELECT course_id, device_id FROM course_members"):
        joined[row["device_id"]].append(row["course_id"])
    bans = {
        row["device_id"]: row["id"]
        for row in conn.execute("SELECT id, device_id FROM bans")
    }

    def entry(kind: str, row_id: int, owner: str, **fields) -> dict:
        # An owner can already see and post to the board, so it counts as joined.
        joined_ids = sorted({*joined[owner], *owned[owner]})
        return {
            "kind": kind,
            "id": row_id,
            "owner": owner,
            **fields,
            "names": [name for name, _ in names[owner].most_common()],
            "courses": counts["courses"][owner],
            "runs": counts["runs"][owner],
            "acceleration": counts["acceleration_entries"][owner],
            "joined": len(joined_ids),
            "owned_course_ids": owned[owner],
            "joined_course_ids": joined_ids,
            "banned": owner in bans,
            "ban_id": bans.get(owner),
        }

    devices: dict[int | None, list[dict]] = defaultdict(list)
    for row in conn.execute(
        "SELECT * FROM devices ORDER BY last_seen DESC NULLS LAST, id DESC"
    ):
        devices[row["user_id"]].append(
            {key: row[key] for key in ("id", "label", "first_seen", "last_seen")}
            | {"token": row["token"]}
        )
    people = []
    for user in conn.execute("SELECT * FROM users"):
        own = [
            {key: value for key, value in device.items() if key != "token"}
            for device in devices[user["id"]]
        ]
        people.append(
            entry(
                "user",
                user["id"],
                _account_owner_id(user["apple_sub"]),
                label=user["label"],
                name=user["name"],
                email=user["email"],
                first_seen=user["created_at"],
                last_seen=max(
                    (d["last_seen"] for d in own if d["last_seen"]), default=None
                ),
                devices=own,
            )
        )
    for device in devices[None]:
        people.append(
            entry(
                "device",
                device["id"],
                device["token"],
                label=device["label"],
                name=None,
                email=None,
                first_seen=device["first_seen"],
                last_seen=device["last_seen"],
                devices=[],
            )
        )
    people.sort(key=lambda p: (p["last_seen"] or "", p["id"]), reverse=True)
    return people


@app.get("/api/admin/users")
def list_users(_: AdminDep):
    with db.session() as conn:
        people = _people(conn)
    for person in people:
        del person["owner"]
    return people


@app.patch("/api/admin/users/{user_id}")
def update_user(user_id: int, update: LabelIn, _: AdminDep):
    label = _clean(update.label)
    with db.session() as conn:
        cur = conn.execute("UPDATE users SET label = ? WHERE id = ?", (label, user_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"User {user_id} not found")
        return {"id": user_id, "label": label}


@app.patch("/api/admin/devices/{device_id}")
def update_device(device_id: int, update: LabelIn, _: AdminDep):
    label = _clean(update.label)
    with db.session() as conn:
        cur = conn.execute(
            "UPDATE devices SET label = ? WHERE id = ?", (label, device_id)
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"Device {device_id} not found")
        return {"id": device_id, "label": label}


# For a phone that posted and will never sign in: files everything under its
# token with an account instead. The phone itself is not signed in by this.
@app.post("/api/admin/devices/{device_id}/move")
def move_device_posts(device_id: int, body: MoveDeviceIn, _: AdminDep):
    with db.session() as conn:
        device = conn.execute(
            "SELECT * FROM devices WHERE id = ?", (device_id,)
        ).fetchone()
        if device is None:
            raise HTTPException(status_code=404, detail=f"Device {device_id} not found")
        if device["user_id"] is not None:
            raise HTTPException(
                status_code=400, detail="That device is signed in to an account"
            )
        owner = _person_owner_id(conn, PersonIn(kind="user", id=body.user_id))
        _adopt_device(conn, device["token"], owner)
        return {"moved": device_id, "user_id": body.user_id}


def _account_out(user) -> dict:
    return {"signed_in": user is not None, "name": user["name"] if user else None}


# Everything the device did under its own token moves to the account. Where
# the account already has the same block, ban or membership, the device's
# copy is dropped instead.
def _adopt_device(conn, token: str, owner_id: str) -> None:
    for table, column in (
        ("courses", "owner_id"),
        ("runs", "owner_id"),
        ("acceleration_entries", "owner_id"),
        ("reports", "reporter_id"),
        ("submissions", "owner_id"),
    ):
        conn.execute(
            f"UPDATE {table} SET {column} = ? WHERE {column} = ?", (owner_id, token)
        )
    for table, column in (
        ("blocks", "blocker_id"),
        ("blocks", "blocked_id"),
        ("bans", "device_id"),
        ("course_members", "device_id"),
    ):
        conn.execute(
            f"UPDATE OR IGNORE {table} SET {column} = ? WHERE {column} = ?",
            (owner_id, token),
        )
        conn.execute(f"DELETE FROM {table} WHERE {column} = ?", (token,))
    conn.execute("DELETE FROM blocks WHERE blocker_id = blocked_id")


@app.get("/api/account")
def get_account(actor: ActorDep):
    with db.session() as conn:
        return _account_out(
            conn.execute(
                "SELECT * FROM users WHERE id = ?", (actor.user_id,)
            ).fetchone()
        )


# Every account has a username so the admin can tell people apart before they
# post. The name Apple shares seeds it; Apple often shares none, and then the
# sign-in is turned away with USERNAME_REQUIRED until the app sends one the
# person typed. A username already stored is kept.
@app.post("/api/account/apple")
def sign_in_with_apple(body: AppleSignIn, token: DeviceTokenDep):
    try:
        claims = apple.verify_identity_token(body.identity_token, body.nonce)
    except apple.AppleError as exc:
        raise HTTPException(
            status_code=401, detail="Apple did not confirm that sign-in"
        ) from exc
    name = _clean(body.name)
    # A name the word filter rejects counts as none, so the app asks for another.
    if moderation.contains_blocked_word(name):
        name = None
    with db.session() as conn:
        known = conn.execute(
            "SELECT name FROM users WHERE apple_sub = ?", (claims["sub"],)
        ).fetchone()
    if not name and not (known and known["name"]):
        raise HTTPException(status_code=USERNAME_REQUIRED, detail="Choose a username")
    # Apple's code works once, so it is only spent on a sign-in that will go through.
    refresh_token = (
        apple.exchange_code(body.authorization_code)
        if body.authorization_code
        else None
    )
    with db.session() as conn:
        conn.execute(
            """INSERT INTO users (apple_sub, name, email, apple_refresh_token)
               VALUES (?, ?, ?, ?)
               ON CONFLICT (apple_sub) DO UPDATE SET
                   name = COALESCE(name, excluded.name),
                   email = COALESCE(excluded.email, email),
                   apple_refresh_token = COALESCE(
                       excluded.apple_refresh_token, apple_refresh_token)""",
            (claims["sub"], name, claims.get("email"), refresh_token),
        )
        user = conn.execute(
            "SELECT * FROM users WHERE apple_sub = ?", (claims["sub"],)
        ).fetchone()
        _record_device(conn, token)
        conn.execute(
            "UPDATE devices SET user_id = ? WHERE token = ?", (user["id"], token)
        )
        _adopt_device(conn, token, _account_owner_id(user["apple_sub"]))
        return _account_out(user)


# The account's name is its username: what the admin sees and the default for
# the poster field. It is not shown to other users.
@app.patch("/api/account")
def update_account(update: AccountUpdate, actor: WriterDep):
    if actor.user_id is None:
        raise HTTPException(status_code=401, detail="Not signed in")
    name = _clean(update.name)
    if not name:
        raise HTTPException(status_code=400, detail="Username cannot be blank")
    _reject_blocked_words(actor, name)
    with db.session() as conn:
        conn.execute("UPDATE users SET name = ? WHERE id = ?", (name, actor.user_id))
        return _account_out(
            conn.execute(
                "SELECT * FROM users WHERE id = ?", (actor.user_id,)
            ).fetchone()
        )


# Apple calls this when someone stops using their Apple ID with the app or
# deletes the Apple ID. Either way no phone may stay signed in on the strength
# of it; the posts stay with the account in case they sign in again.
@app.post("/api/account/apple/notifications")
def apple_notification(body: AppleNotification):
    try:
        event = apple.verify_notification(body.payload)
    except apple.AppleError as exc:
        raise HTTPException(
            status_code=401, detail="Not a notification from Apple"
        ) from exc
    if event.get("type") in ("consent-revoked", "account-delete"):
        with db.session() as conn:
            user = conn.execute(
                "SELECT id FROM users WHERE apple_sub = ?", (event.get("sub"),)
            ).fetchone()
            if user is not None:
                conn.execute(
                    "UPDATE devices SET user_id = NULL WHERE user_id = ?", (user["id"],)
                )
                conn.execute(
                    "UPDATE users SET apple_refresh_token = NULL WHERE id = ?",
                    (user["id"],),
                )
    return {}


# Signing out only unlinks this device; what it posted stays with the account.
@app.delete("/api/account/session")
def sign_out(token: DeviceTokenDep):
    with db.session() as conn:
        conn.execute("UPDATE devices SET user_id = NULL WHERE token = ?", (token,))
    return _account_out(None)


# Removes the account and everything posted from it. A ban stays behind, keyed
# by Apple's identifier, so deleting and signing up again does not lift it.
@app.delete("/api/account")
def delete_account(actor: ActorDep):
    if actor.user_id is None:
        raise HTTPException(status_code=401, detail="Not signed in")
    with db.session() as conn:
        user = conn.execute(
            "SELECT * FROM users WHERE id = ?", (actor.user_id,)
        ).fetchone()
        owner_id = actor.device_id
        _delete_submissions(
            conn,
            """owner_id = ? OR course_id IN
                   (SELECT id FROM courses WHERE owner_id = ?)""",
            (owner_id, owner_id),
        )
        conn.execute("DELETE FROM runs WHERE owner_id = ?", (owner_id,))
        conn.execute("DELETE FROM courses WHERE owner_id = ?", (owner_id,))
        conn.execute("DELETE FROM acceleration_entries WHERE owner_id = ?", (owner_id,))
        conn.execute("DELETE FROM course_members WHERE device_id = ?", (owner_id,))
        conn.execute("DELETE FROM blocks WHERE blocker_id = ?", (owner_id,))
        conn.execute(
            "UPDATE reports SET reporter_id = NULL WHERE reporter_id = ?", (owner_id,)
        )
        conn.execute("DELETE FROM users WHERE id = ?", (user["id"],))
    if user["apple_refresh_token"]:
        apple.revoke(user["apple_refresh_token"])
    return _account_out(None)


ACCELERATION_TEXT_FIELDS = ("vehicle", "driver", "notes")
ACCELERATION_TIME_FIELDS = (
    "zero_to_30_seconds",
    "zero_to_60_seconds",
    "quarter_mile_seconds",
    "eighth_mile_seconds",
)


def _get_acceleration(conn, entry_id: int, actor: Actor):
    entry = conn.execute(
        "SELECT * FROM acceleration_entries WHERE id = ?", (entry_id,)
    ).fetchone()
    if entry is None or (entry["hidden"] and not actor.is_admin):
        raise HTTPException(
            status_code=404, detail=f"Acceleration entry {entry_id} not found"
        )
    return entry


def _require_acceleration_owner(entry, actor: Actor) -> None:
    if not (actor.is_admin or _owns(entry, actor)):
        raise HTTPException(
            status_code=403, detail="Only the entry's poster can change it"
        )


@app.get("/api/acceleration")
def list_acceleration(actor: ActorDep):
    with db.session() as conn:
        blocked = _blocked_ids(conn, actor)
        rows = [
            row
            for row in conn.execute("SELECT * FROM acceleration_entries")
            if (actor.is_admin or not row["hidden"]) and row["owner_id"] not in blocked
        ]
    rows.sort(key=db.acceleration_sort_key)
    # Every post is kept, but the board ranks a poster's best run per vehicle
    # and carries the rest inside it. The admin gets every row ranked, since
    # each one can be hidden on its own.
    entries, best = [], {}
    for row in rows:
        entry = db.acceleration_to_dict(row, actor.device_id)
        if row["owner_id"] is not None and not actor.is_admin:
            vehicle = (row["owner_id"], row["year"], row["vehicle"].casefold())
            if vehicle in best:
                best[vehicle]["other_runs"].append(entry)
                continue
            best[vehicle] = entry
        entry["other_runs"] = []
        entries.append(entry)
    return entries


def _acceleration_fields(entry: AccelerationIn, actor: Actor) -> dict:
    fields = entry.model_dump()
    for key in ACCELERATION_TEXT_FIELDS:
        fields[key] = _clean(fields[key])
    if not fields["vehicle"]:
        raise HTTPException(status_code=400, detail="Vehicle cannot be blank")
    _require_account(actor)
    _reject_blocked_words(actor, *(fields[key] for key in ACCELERATION_TEXT_FIELDS))
    if not actor.is_admin and all(
        fields[key] is None for key in ACCELERATION_TIME_FIELDS
    ):
        raise HTTPException(status_code=400, detail="An entry needs at least one time")
    return fields


@app.post("/api/acceleration", status_code=201)
def create_acceleration(entry: AccelerationIn, actor: WriterDep):
    fields = {**_acceleration_fields(entry, actor), "owner_id": actor.device_id}
    with db.session() as conn:
        if actor.device_id is not None:
            owned = conn.execute(
                "SELECT COUNT(*) FROM acceleration_entries WHERE owner_id = ?",
                (actor.device_id,),
            ).fetchone()[0]
            if owned >= MAX_ACCELERATION_PER_OWNER:
                raise HTTPException(
                    status_code=429,
                    detail=f"Limit of {MAX_ACCELERATION_PER_OWNER} acceleration entries per device",
                )
        entry_id = _insert_row(conn, "acceleration_entries", fields)
        return db.acceleration_to_dict(
            _get_acceleration(conn, entry_id, actor), actor.device_id
        )


@app.patch("/api/acceleration/{entry_id}")
def update_acceleration(entry_id: int, update: AccelerationUpdate, actor: WriterDep):
    fields = update.model_dump(exclude_unset=True)
    for key in ACCELERATION_TEXT_FIELDS:
        if key in fields:
            fields[key] = _clean(fields[key])
    if fields.get("vehicle", "x") is None:
        raise HTTPException(status_code=400, detail="Vehicle cannot be blank")
    for key in ("source", "hidden"):
        if key in fields and fields[key] is None:
            del fields[key]
    if "hidden" in fields:
        # Hiding is moderation, so a poster must not be able to undo it.
        if not actor.is_admin:
            raise HTTPException(
                status_code=403, detail="Only an admin can hide or unhide an entry"
            )
        fields["hidden"] = int(fields["hidden"])
    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")
    _reject_blocked_words(actor, *(fields.get(key) for key in ACCELERATION_TEXT_FIELDS))
    with db.session() as conn:
        _require_acceleration_owner(_get_acceleration(conn, entry_id, actor), actor)
        assignments = ", ".join(f"{name} = ?" for name in fields)
        conn.execute(
            f"UPDATE acceleration_entries SET {assignments} WHERE id = ?",
            (*fields.values(), entry_id),
        )
        return db.acceleration_to_dict(
            _get_acceleration(conn, entry_id, actor), actor.device_id
        )


@app.delete("/api/acceleration/{entry_id}")
def delete_acceleration(entry_id: int, actor: WriterDep):
    with db.session() as conn:
        _require_acceleration_owner(_get_acceleration(conn, entry_id, actor), actor)
        conn.execute("DELETE FROM acceleration_entries WHERE id = ?", (entry_id,))
        return {"deleted": entry_id}


def _decode_proof(encoded: str) -> tuple[bytes, str]:
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(
            status_code=400, detail="The proof photo did not upload correctly"
        ) from exc
    if len(data) > MAX_PROOF_BYTES:
        raise HTTPException(status_code=413, detail="The proof photo is too large")
    for magic, (extension, _) in PROOF_TYPES.items():
        if data.startswith(magic):
            return data, extension
    raise HTTPException(status_code=400, detail="The proof must be a JPEG or PNG image")


def _unlink_proof(name: str | None) -> None:
    if name:
        (db.proof_dir() / name).unlink(missing_ok=True)


# Rows go through here rather than a bare DELETE (or the cascade from their
# course) so their photos go with them.
def _delete_submissions(conn, where: str, params: tuple) -> int:
    rows = conn.execute(
        f"SELECT id, proof_file FROM submissions WHERE {where}", params
    ).fetchall()
    for row in rows:
        conn.execute("DELETE FROM submissions WHERE id = ?", (row["id"],))
        _unlink_proof(row["proof_file"])
    return len(rows)


def _course_names(conn) -> dict[int, str]:
    return {
        row["id"]: row["name"] for row in conn.execute("SELECT id, name FROM courses")
    }


def _get_submission(conn, submission_id: int):
    row = conn.execute(
        "SELECT * FROM submissions WHERE id = ?", (submission_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=404, detail=f"Submission {submission_id} not found"
        )
    return row


def _pending_submission(conn, submission_id: int):
    row = _get_submission(conn, submission_id)
    if row["status"] != "pending":
        raise HTTPException(
            status_code=409,
            detail=f"Submission {submission_id} is already {row['status']}",
        )
    return row


# The photo is only kept while the admin still has to look at it.
def _close_submission(
    conn, row, status: str, note: str | None, result_id: int | None = None
) -> dict:
    conn.execute(
        """UPDATE submissions SET status = ?, review_note = ?, result_id = ?,
               proof_file = NULL, reviewed_at = datetime('now') WHERE id = ?""",
        (status, note, result_id, row["id"]),
    )
    _unlink_proof(row["proof_file"])
    return db.submission_to_dict(
        _get_submission(conn, row["id"]), _course_names(conn).get(row["course_id"])
    )


@app.post("/api/submissions", status_code=201)
def create_submission(body: SubmissionIn, actor: WriterDep):
    if actor.device_id is None:
        raise HTTPException(
            status_code=400,
            detail="Submissions come from the app; the admin posts directly",
        )
    if (body.run is None) == (body.acceleration is None):
        raise HTTPException(
            status_code=400, detail="Send either a run or an acceleration entry"
        )
    if body.run is not None:
        if body.course_id is None:
            raise HTTPException(status_code=400, detail="A run needs a course_id")
        kind, course_id = "run", body.course_id
        fields = _run_fields(body.run, actor)
    else:
        kind, course_id = "acceleration", None
        fields = _acceleration_fields(body.acceleration, actor)
    # A run carries its year inside the vehicle name, so only an acceleration
    # entry can be checked for one.
    required = ("vehicle", "hp") if kind == "run" else ("vehicle", "year", "hp")
    if any(fields[key] in (None, "") for key in required):
        raise HTTPException(
            status_code=400, detail="Enter the vehicle's year, name and HP"
        )
    fields["source"] = "photo"
    data, extension = _decode_proof(body.proof)
    with db.session() as conn:
        course = _get_course(conn, course_id, actor) if course_id is not None else None
        pending = conn.execute(
            "SELECT COUNT(*) FROM submissions WHERE owner_id = ? AND status = 'pending'",
            (actor.device_id,),
        ).fetchone()[0]
        if pending >= MAX_PENDING_SUBMISSIONS:
            raise HTTPException(
                status_code=429,
                detail=f"You already have {MAX_PENDING_SUBMISSIONS} times waiting for review",
            )
        name = f"{secrets.token_hex(16)}.{extension}"
        db.proof_dir().mkdir(exist_ok=True)
        (db.proof_dir() / name).write_bytes(data)
        try:
            submission_id = _insert_row(
                conn,
                "submissions",
                {
                    "kind": kind,
                    "course_id": course_id,
                    "payload": json.dumps(fields),
                    "proof_file": name,
                    "owner_id": actor.device_id,
                },
            )
        except sqlite3.Error:
            _unlink_proof(name)
            raise
        return db.submission_to_dict(
            _get_submission(conn, submission_id), course["name"] if course else None
        )


# What the caller is still waiting on, and what was turned down.
@app.get("/api/submissions")
def list_own_submissions(actor: ActorDep):
    if actor.device_id is None:
        return []
    with db.session() as conn:
        names = _course_names(conn)
        return [
            db.submission_to_dict(row, names.get(row["course_id"]))
            for row in conn.execute(
                """SELECT * FROM submissions WHERE owner_id = ? AND status != 'approved'
                   ORDER BY id DESC""",
                (actor.device_id,),
            )
        ]


@app.delete("/api/submissions/{submission_id}")
def delete_submission(submission_id: int, actor: ActorDep):
    with db.session() as conn:
        row = conn.execute(
            "SELECT * FROM submissions WHERE id = ?", (submission_id,)
        ).fetchone()
        if row is None or not (actor.is_admin or _owns(row, actor)):
            raise HTTPException(
                status_code=404, detail=f"Submission {submission_id} not found"
            )
        _delete_submissions(conn, "id = ?", (submission_id,))
        return {"deleted": submission_id}


@app.get("/api/admin/submissions")
def list_submissions(_: AdminDep, status: str = "pending"):
    with db.session() as conn:
        names = _course_names(conn)
        people = {person["owner"]: person for person in _people(conn)}
        out = []
        for row in conn.execute(
            """SELECT * FROM submissions WHERE ? IN ('all', status)
               ORDER BY status = 'pending' DESC, id DESC LIMIT 200""",
            (status,),
        ):
            submission = db.submission_to_dict(row, names.get(row["course_id"]))
            person = people.get(row["owner_id"])
            submission["submitter"] = person and {
                key: person[key] for key in ("kind", "id", "label", "name", "names")
            }
            out.append(submission)
        return out


@app.get("/api/admin/submissions/{submission_id}/proof")
def get_submission_proof(submission_id: int, _: AdminDep):
    with db.session() as conn:
        name = _get_submission(conn, submission_id)["proof_file"]
    path = db.proof_dir() / name if name else None
    if path is None or not path.is_file():
        raise HTTPException(
            status_code=404, detail=f"Submission {submission_id} has no proof photo"
        )
    media_type = next(
        mime for extension, mime in PROOF_TYPES.values() if extension == path.suffix[1:]
    )
    return FileResponse(
        path,
        media_type=media_type,
        headers={
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


# Approving posts the time exactly as an ordinary post by the submitter would
# have: theirs to edit or delete, and gone with their account.
@app.post("/api/admin/submissions/{submission_id}/approve")
def approve_submission(submission_id: int, _: AdminDep):
    with db.session() as conn:
        row = _pending_submission(conn, submission_id)
        fields = {**json.loads(row["payload"]), "owner_id": row["owner_id"]}
        if row["kind"] == "run":
            result_id = _insert_row(
                conn, "runs", {**fields, "course_id": row["course_id"]}
            )
        else:
            result_id = _insert_row(conn, "acceleration_entries", fields)
        return _close_submission(conn, row, "approved", None, result_id)


@app.post("/api/admin/submissions/{submission_id}/reject")
def reject_submission(submission_id: int, review: ReviewIn, _: AdminDep):
    with db.session() as conn:
        row = _pending_submission(conn, submission_id)
        return _close_submission(conn, row, "rejected", _clean(review.note))


@app.post("/api/trackaddict/parse")
async def parse_trackaddict(request: Request):
    body = (await request.body()).decode("utf-8", errors="replace")
    if not body.strip():
        raise HTTPException(status_code=400, detail="Empty request body")
    parsed = trackaddict.parse_log(body)
    if not parsed["laps"]:
        raise HTTPException(status_code=400, detail="No laps found in log")
    return parsed


@app.get("/", include_in_schema=False)
@app.get("/app", include_in_schema=False)
def landing():
    return FileResponse(STATIC_DIR / "app.html")


@app.get("/dev", include_in_schema=False)
def dev_console():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/privacy", include_in_schema=False)
def privacy():
    return FileResponse(STATIC_DIR / "privacy.html")


@app.get("/support", include_in_schema=False)
def support():
    return FileResponse(STATIC_DIR / "support.html")


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8321)
