import os
import re
import secrets
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Literal

import db
import gglc
import trackaddict
from fastapi import Depends, FastAPI, HTTPException, Request
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

app = FastAPI(title="Evergreen AutoX server")

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
)
client = SpeedhiveClient.create()

STATIC_DIR = Path(__file__).parent / "static"

ADMIN_USER = os.environ.get("LEADERBOARD_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("LEADERBOARD_ADMIN_PASSWORD")
basic_auth = HTTPBasic(auto_error=False)
bearer_auth = HTTPBearer(auto_error=False)

# The app identifies itself with a random token it generated on first launch;
# there are no accounts. The token is the only proof of ownership, so it is
# stored as-is and never echoed back.
DEVICE_TOKEN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
MAX_COURSES_PER_OWNER = 20


@dataclass(frozen=True)
class Actor:
    device_id: str | None = None
    is_admin: bool = False

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


def get_actor(
    basic: Annotated[HTTPBasicCredentials | None, Depends(basic_auth)],
    bearer: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_auth)],
) -> Actor:
    if basic is not None:
        _check_admin(basic)
        return Actor(is_admin=True)
    if bearer is not None:
        if not DEVICE_TOKEN.match(bearer.credentials):
            raise HTTPException(status_code=401, detail="Malformed device token")
        return Actor(device_id=bearer.credentials)
    return Actor()


def require_actor(actor: Annotated[Actor, Depends(get_actor)]) -> Actor:
    if actor.is_anonymous:
        raise HTTPException(
            status_code=401,
            detail="Authentication required: admin login or device token",
        )
    return actor


def require_admin(actor: Annotated[Actor, Depends(get_actor)]) -> Actor:
    if not actor.is_admin:
        raise HTTPException(status_code=401, detail="Admin login required")
    return actor


ActorDep = Annotated[Actor, Depends(get_actor)]
WriterDep = Annotated[Actor, Depends(require_actor)]
AdminDep = Annotated[Actor, Depends(require_admin)]


def _raw_laps(session_id: int) -> list:
    response = get_all_lap_times.sync_detailed(id=session_id, client=client.client)
    result = SpeedhiveClient._parse_response(response)
    if isinstance(result, dict):
        result = result.get("rows", result.get("laps", []))
    return result if isinstance(result, list) else []


@app.get("/api/orgs/{org_id}")
def get_org(org_id: int):
    org = client.get_organization(org_id)
    if org is None:
        raise HTTPException(status_code=404, detail=f"Organization {org_id} not found")
    return org


@app.get("/api/orgs/{org_id}/events")
def get_events(org_id: int, limit: int = 50, offset: int = 0):
    return client.get_events(org_id, limit=limit, offset=offset)


@app.get("/api/events/{event_id}/sessions")
def get_sessions(event_id: int):
    return client.get_sessions(event_id)


@app.get("/api/sessions/{session_id}/results")
def get_results(session_id: int):
    return client.get_results(session_id)


@app.get("/api/sessions/{session_id}/laps")
def get_laps(session_id: int):
    return _raw_laps(session_id)


@app.get("/api/sessions/{session_id}/drivers")
def get_drivers(session_id: int):
    drivers = []
    for row in client.get_results(session_id):
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
            for row in client.get_results(session_id)
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
    return gglc.list_events(year or gglc.today().year)


@app.get("/api/gglc/events/{event_date}")
def gglc_event(event_date: str):
    try:
        day = gglc.parse_date(event_date)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    event = gglc.fetch_event(day)
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


class CourseIn(BaseModel):
    name: NameStr
    distance_miles: Miles = None
    legacy_distance_miles: Miles = None
    description: LongStr = None
    created_by: ShortStr = None


class CourseUpdate(BaseModel):
    name: NameStr | None = None
    distance_miles: Miles = None
    legacy_distance_miles: Miles = None
    description: LongStr = None


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


class ReportIn(BaseModel):
    target_type: Literal["course", "run"]
    target_id: int
    reason: Annotated[str, Field(min_length=1, max_length=500)]


def _clean(value: str | None) -> str | None:
    if value is None:
        return None
    value = " ".join(value.split())
    return value or None


def _parse_time(value: float | str) -> float:
    try:
        seconds = db.parse_time(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not 0 < seconds < 24 * 3600:
        raise HTTPException(status_code=400, detail="Time must be under 24 hours")
    return seconds


def _get_course(conn, course_id: int):
    course = conn.execute("SELECT * FROM courses WHERE id = ?", (course_id,)).fetchone()
    if course is None:
        raise HTTPException(status_code=404, detail=f"Course {course_id} not found")
    return course


def _get_run(conn, run_id: int):
    run = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
    if run is None:
        raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
    return run


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


def _owns(row, actor: Actor) -> bool:
    return row["owner_id"] is not None and row["owner_id"] == actor.device_id


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
def list_courses(actor: ActorDep):
    with db.session() as conn:
        return [
            db.course_to_dict(row, actor.device_id)
            for row in conn.execute("SELECT * FROM courses ORDER BY id")
        ]


@app.post("/api/leaderboard/courses")
def create_course(course: CourseIn, actor: WriterDep):
    name = _clean(course.name)
    if not name:
        raise HTTPException(status_code=400, detail="Name cannot be blank")
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
                    description, owner_id, created_by, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, datetime('now'))""",
                (
                    name,
                    course.distance_miles,
                    course.legacy_distance_miles,
                    _clean(course.description),
                    actor.device_id,
                    _clean(course.created_by),
                ),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(
                status_code=409, detail=f"A leaderboard named {name!r} already exists"
            ) from exc
        return db.course_to_dict(_get_course(conn, cur.lastrowid), actor.device_id)


@app.patch("/api/leaderboard/courses/{course_id}")
def update_course(course_id: int, update: CourseUpdate, actor: WriterDep):
    fields = update.model_dump(exclude_unset=True)
    for key in ("name", "description"):
        if key in fields:
            fields[key] = _clean(fields[key])
    if fields.get("name", "x") is None:
        raise HTTPException(status_code=400, detail="Name cannot be blank")
    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")
    with db.session() as conn:
        _require_course_owner(_get_course(conn, course_id), actor)
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
        return db.course_to_dict(_get_course(conn, course_id), actor.device_id)


@app.delete("/api/leaderboard/courses/{course_id}")
def delete_course(course_id: int, actor: WriterDep):
    with db.session() as conn:
        _require_course_owner(_get_course(conn, course_id), actor)
        conn.execute("DELETE FROM courses WHERE id = ?", (course_id,))
        return {"deleted": course_id}


@app.get("/api/leaderboard/courses/{course_id}")
def get_leaderboard(course_id: int, actor: ActorDep):
    with db.session() as conn:
        course = _get_course(conn, course_id)
        runs = [
            db.run_to_dict(row, course, actor.device_id)
            for row in conn.execute(
                "SELECT * FROM runs WHERE course_id = ?", (course_id,)
            )
        ]
        runs.sort(key=lambda r: r["adjusted_seconds"])
        return {"course": db.course_to_dict(course, actor.device_id), "runs": runs}


@app.post("/api/leaderboard/courses/{course_id}/runs")
def create_run(course_id: int, run: RunIn, actor: WriterDep):
    time_seconds = _parse_time(run.time)
    driver = _clean(run.driver)
    if not driver:
        raise HTTPException(status_code=400, detail="Driver cannot be blank")
    with db.session() as conn:
        course = _get_course(conn, course_id)
        cur = conn.execute(
            """INSERT INTO runs (course_id, driver, vehicle, hp, time_seconds,
                avg_speed_mph, top_speed_mph, run_date, time_of_day, conditions,
                legacy, notes, source, owner_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                course_id,
                driver,
                _clean(run.vehicle),
                run.hp,
                time_seconds,
                run.avg_speed_mph,
                run.top_speed_mph,
                _clean(run.run_date),
                _clean(run.time_of_day),
                _clean(run.conditions),
                int(run.legacy),
                _clean(run.notes),
                run.source,
                actor.device_id,
            ),
        )
        return db.run_to_dict(_get_run(conn, cur.lastrowid), course, actor.device_id)


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
    with db.session() as conn:
        row = _get_run(conn, run_id)
        course = _get_course(conn, row["course_id"])
        _require_run_owner(row, course, actor)
        assignments = ", ".join(f"{name} = ?" for name in fields)
        conn.execute(
            f"UPDATE runs SET {assignments} WHERE id = ?",
            (*fields.values(), run_id),
        )
        return db.run_to_dict(_get_run(conn, run_id), course, actor.device_id)


@app.delete("/api/leaderboard/runs/{run_id}")
def delete_run(run_id: int, actor: WriterDep):
    with db.session() as conn:
        row = _get_run(conn, run_id)
        _require_run_owner(row, _get_course(conn, row["course_id"]), actor)
        conn.execute("DELETE FROM runs WHERE id = ?", (run_id,))
        return {"deleted": run_id}


@app.post("/api/leaderboard/reports", status_code=201)
def create_report(report: ReportIn, actor: WriterDep):
    table = "courses" if report.target_type == "course" else "runs"
    with db.session() as conn:
        exists = conn.execute(
            f"SELECT 1 FROM {table} WHERE id = ?", (report.target_id,)
        ).fetchone()
        if exists is None:
            raise HTTPException(
                status_code=404,
                detail=f"{report.target_type.capitalize()} {report.target_id} not found",
            )
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
                    "SELECT id, name FROM courses WHERE id = ?", (row["target_id"],)
                ).fetchone()
                report["target"] = dict(target) if target else None
            else:
                target = conn.execute(
                    """SELECT runs.id, runs.driver, runs.time_seconds, runs.course_id,
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


@app.post("/api/trackaddict/parse")
async def parse_trackaddict(request: Request):
    body = (await request.body()).decode("utf-8", errors="replace")
    if not body.strip():
        raise HTTPException(status_code=400, detail="Empty request body")
    parsed = trackaddict.parse_log(body)
    if not parsed["laps"]:
        raise HTTPException(status_code=400, detail="No laps found in log")
    return parsed


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8321)
