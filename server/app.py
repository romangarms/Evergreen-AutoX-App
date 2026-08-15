from pathlib import Path

import gglc
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from speedhive.generated.api.session_controller import get_all_lap_times
from speedhive.wrapper import SpeedhiveClient

app = FastAPI(title="Evergreen AutoX server")
client = SpeedhiveClient.create()

STATIC_DIR = Path(__file__).parent / "static"


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


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8321)
