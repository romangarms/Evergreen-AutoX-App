import os
import secrets
import sqlite3
from pathlib import Path
from typing import Annotated

import db
import gglc
import trackaddict
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
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


def require_admin(
    credentials: Annotated[HTTPBasicCredentials | None, Depends(basic_auth)],
):
    if not ADMIN_PASSWORD:
        raise HTTPException(
            status_code=503,
            detail="Leaderboard edits are disabled: set LEADERBOARD_ADMIN_PASSWORD",
        )
    if credentials is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    user_ok = secrets.compare_digest(credentials.username.encode(), ADMIN_USER.encode())
    password_ok = secrets.compare_digest(
        credentials.password.encode(), ADMIN_PASSWORD.encode()
    )
    if not (user_ok and password_ok):
        raise HTTPException(status_code=401, detail="Invalid credentials")


admin_only = {"dependencies": [Depends(require_admin)]}


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


class CourseIn(BaseModel):
    name: str
    distance_miles: float | None = None
    legacy_distance_miles: float | None = None


class CourseUpdate(BaseModel):
    name: str | None = None
    distance_miles: float | None = None
    legacy_distance_miles: float | None = None


class RunIn(BaseModel):
    driver: str
    time: float | str
    vehicle: str | None = None
    hp: int | None = None
    avg_speed_mph: float | None = None
    top_speed_mph: float | None = None
    run_date: str | None = None
    time_of_day: str | None = None
    conditions: str | None = None
    legacy: bool = False
    notes: str | None = None
    source: str = "manual"


class RunUpdate(BaseModel):
    driver: str | None = None
    time: float | str | None = None
    vehicle: str | None = None
    hp: int | None = None
    avg_speed_mph: float | None = None
    top_speed_mph: float | None = None
    run_date: str | None = None
    time_of_day: str | None = None
    conditions: str | None = None
    legacy: bool | None = None
    notes: str | None = None
    source: str | None = None


def _get_course(conn, course_id: int):
    course = conn.execute("SELECT * FROM courses WHERE id = ?", (course_id,)).fetchone()
    if course is None:
        raise HTTPException(status_code=404, detail=f"Course {course_id} not found")
    return course


@app.get("/api/leaderboard/courses")
def list_courses():
    with db.session() as conn:
        return [dict(row) for row in conn.execute("SELECT * FROM courses ORDER BY id")]


@app.post("/api/leaderboard/courses", **admin_only)
def create_course(course: CourseIn):
    with db.session() as conn:
        try:
            cur = conn.execute(
                "INSERT INTO courses (name, distance_miles, legacy_distance_miles) VALUES (?, ?, ?)",
                (course.name, course.distance_miles, course.legacy_distance_miles),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(
                status_code=409, detail=f"Course {course.name!r} already exists"
            ) from exc
        return dict(_get_course(conn, cur.lastrowid))


@app.patch("/api/leaderboard/courses/{course_id}", **admin_only)
def update_course(course_id: int, update: CourseUpdate):
    fields = update.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")
    with db.session() as conn:
        _get_course(conn, course_id)
        assignments = ", ".join(f"{name} = ?" for name in fields)
        try:
            conn.execute(
                f"UPDATE courses SET {assignments} WHERE id = ?",
                (*fields.values(), course_id),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(
                status_code=409, detail=f"Course {update.name!r} already exists"
            ) from exc
        return dict(_get_course(conn, course_id))


@app.delete("/api/leaderboard/courses/{course_id}", **admin_only)
def delete_course(course_id: int):
    with db.session() as conn:
        _get_course(conn, course_id)
        conn.execute("DELETE FROM courses WHERE id = ?", (course_id,))
        return {"deleted": course_id}


@app.get("/api/leaderboard/courses/{course_id}")
def get_leaderboard(course_id: int):
    with db.session() as conn:
        course = _get_course(conn, course_id)
        runs = [
            db.run_to_dict(row, course)
            for row in conn.execute(
                "SELECT * FROM runs WHERE course_id = ?", (course_id,)
            )
        ]
        runs.sort(key=lambda r: r["adjusted_seconds"])
        return {"course": dict(course), "runs": runs}


@app.post("/api/leaderboard/courses/{course_id}/runs", **admin_only)
def create_run(course_id: int, run: RunIn):
    try:
        time_seconds = db.parse_time(run.time)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    with db.session() as conn:
        course = _get_course(conn, course_id)
        cur = conn.execute(
            """INSERT INTO runs (course_id, driver, vehicle, hp, time_seconds,
                avg_speed_mph, top_speed_mph, run_date, time_of_day, conditions,
                legacy, notes, source)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                course_id,
                run.driver,
                run.vehicle,
                run.hp,
                time_seconds,
                run.avg_speed_mph,
                run.top_speed_mph,
                run.run_date,
                run.time_of_day,
                run.conditions,
                int(run.legacy),
                run.notes,
                run.source,
            ),
        )
        row = conn.execute(
            "SELECT * FROM runs WHERE id = ?", (cur.lastrowid,)
        ).fetchone()
        return db.run_to_dict(row, course)


@app.patch("/api/leaderboard/runs/{run_id}", **admin_only)
def update_run(run_id: int, update: RunUpdate):
    fields = update.model_dump(exclude_unset=True)
    if "time" in fields:
        try:
            fields["time_seconds"] = db.parse_time(fields.pop("time"))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    if "legacy" in fields:
        fields["legacy"] = int(fields["legacy"])
    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")
    with db.session() as conn:
        row = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
        assignments = ", ".join(f"{name} = ?" for name in fields)
        conn.execute(
            f"UPDATE runs SET {assignments} WHERE id = ?",
            (*fields.values(), run_id),
        )
        row = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
        course = _get_course(conn, row["course_id"])
        return db.run_to_dict(row, course)


@app.delete("/api/leaderboard/runs/{run_id}", **admin_only)
def delete_run(run_id: int):
    with db.session() as conn:
        cur = conn.execute("DELETE FROM runs WHERE id = ?", (run_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
        return {"deleted": run_id}


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
