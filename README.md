# Evergreen AutoX App

Live timing and results for Evergreen AutoX in your pocket. A SwiftUI iOS app backed by a small FastAPI server that wraps the MyLaps Speedhive API (via [speedhive-tools](https://github.com/cosmoslab58/speedhive-tools)), with bonus support for Golden Gate Lotus Club autocross results scraped from gglotus.org.

## Screenshots

| Live timing | Friends | Head-to-head |
| :---: | :---: | :---: |
| ![Live timing](screenshots/Live%20Events.png) | ![Friends](screenshots/Friends.png) | ![Head-to-head compare](screenshots/Compare.png) |

| Events | Settings |
| :---: | :---: |
| ![Event browser](screenshots/Events.png) | ![Settings](screenshots/Settings.png) |

## The app

Four tabs:

- **Live** — the leaderboard for the selected session: position, car number, best time, and run count for every entry. Your own car gets a **ME** tag and highlight, and you can star cars to keep an eye on them. Pull to refresh.
- **Friends** — pin the cars you care about, see everyone's gap to your best time, and pick any two for a head-to-head: best/average/spread stats, a times-over-the-day chart, and a run-by-run gap breakdown.
- **Events** — browse and search an organization's events, then drill into sessions and individual drivers.
- **Setup** — mark which car is you (drives the ME tag and the gaps on the Friends tab), give cars nicknames, switch Speedhive organizations, and point the app at your server.

## Running the server

```bash
./start.sh
```

Creates the virtualenv and installs dependencies on first run, then starts the server on port 8321. With the venv already set up, `python server/app.py` works too.

The server binds to `0.0.0.0` on purpose: when developing, set the app's server URL (Setup tab) to your Mac's LAN IP so your iPhone can reach it.

Open http://localhost:8321/ for a bare-bones debug UI — enter a Speedhive org ID (the number in the org's URL on speedhive.mylaps.com), then click through events → sessions → drivers to see the raw JSON.

### Docker

```bash
docker compose up -d
```

Builds the server image and runs it on port 8321.

## API endpoints

Speedhive-backed:

- `GET /api/orgs/{org_id}` — org info
- `GET /api/orgs/{org_id}/events?limit=&offset=` — events
- `GET /api/events/{event_id}/sessions` — sessions for an event
- `GET /api/sessions/{session_id}/results` — raw classification
- `GET /api/sessions/{session_id}/laps` — raw laps (grouped per finish position)
- `GET /api/sessions/{session_id}/drivers` — distilled driver list
- `GET /api/sessions/{session_id}/drivers/{position}` — one driver's raw result + laps

GGLC (scraped from gglotus.org result pages):

- `GET /api/gglc/events` — list of GGLC autocross events
- `GET /api/gglc/events/{event_date}` — full results for one event (`YYYY-MM-DD` or `YYYYMMDD`)

Laps in the Speedhive API are keyed only by finish position within a session, so drivers are addressed by `position`.
