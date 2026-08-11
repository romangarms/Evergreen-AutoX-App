# Evergreen AutoX App

Server (and eventually iOS app) around the MyLaps Speedhive results API, using
[speedhive-tools](https://github.com/cosmoslab58/speedhive-tools).

## Server

```bash
./start.sh
```

Creates the virtualenv and installs dependencies on first run, then starts the
server on port 8321. With the venv already set up, `python server/app.py` works
too.

Open http://localhost:8321/ — enter a Speedhive org ID (it's the number in the
org's URL on speedhive.mylaps.com), then click through events → sessions →
drivers to see the raw JSON for a driver (classification row + laps).

### API endpoints

- `GET /api/orgs/{org_id}` — org info
- `GET /api/orgs/{org_id}/events?limit=&offset=` — events
- `GET /api/events/{event_id}/sessions` — sessions for an event
- `GET /api/sessions/{session_id}/results` — raw classification
- `GET /api/sessions/{session_id}/laps` — raw laps (grouped per finish position)
- `GET /api/sessions/{session_id}/drivers` — distilled driver list
- `GET /api/sessions/{session_id}/drivers/{position}` — one driver's raw result + laps

Laps in the Speedhive API are keyed only by finish position within a session,
so drivers are addressed by `position`.
