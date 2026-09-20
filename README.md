# AutoX Live

Autocross timing and results in your pocket, built around the autocross events at Evergreen Speedway. An independent project, not affiliated with any event organizer or timing provider. A SwiftUI iOS app backed by a small FastAPI server that wraps the MyLaps Speedhive API (via [speedhive-tools](https://github.com/cosmoslab58/speedhive-tools)), with bonus support for Golden Gate Lotus Club autocross results scraped from gglotus.org.

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
- **Events** — browse and search an organization's events, then drill into sessions and individual drivers. The **Leaderboards** section holds community leaderboards: anyone can create one from the app, post times to any board from a TrackAddict CSV export (the time and top speed come from the log, not from typing), and report or hide a board or run. Creators can edit and delete their own boards and any run on them.
- **Setup** — set the name you post under, mark which car is you (drives the ME tag and the gaps on the Friends tab), give cars nicknames, find the support and privacy links, and turn on dev mode (tap the version line seven times to reveal it), which unlocks pointing the app at your own server and switching Speedhive organizations (Events → ⋯ menu).

## Running the server

```bash
./start.sh
```

One command for both development and deployment. The first run asks you to choose a leaderboard admin username and password (saved to `.env`, which is gitignored). Then, if Docker Compose is installed, it builds the image and starts the server detached on port 8321 with `restart: unless-stopped`; otherwise it creates a virtualenv, installs dependencies, and runs the server in the foreground. Redeploying is `git pull && ./start.sh`.

```bash
./start.sh local
```

Forces the virtualenv path even when Docker is installed, which is faster for iterating on the server code. `python server/app.py` also works once `.venv` exists, but it does not read `.env`, so export the variables yourself.

The public server is https://autox.romangarms.com, which is what the app uses by default. The server itself speaks plain HTTP on port 8321; TLS is terminated by a reverse proxy in front of it, so the app's transport security settings only allow insecure HTTP for local-network addresses.

The server binds to `0.0.0.0` on purpose: when developing, set the app's server URL (Setup tab) to your Mac's LAN IP so your iPhone can reach it.

Open http://localhost:8321/ for a bare-bones dev console: a leaderboard editor, a Speedhive browser (enter an org ID, the number in the org's URL on speedhive.mylaps.com, then click through events → sessions → drivers), and a GGLC results browser.

### Leaderboard auth

Reading the leaderboard is public. Writes accept two kinds of caller:

- **Device token** (`Authorization: Bearer <token>`): the app mints a random token on first launch and keeps it in the Keychain. A token owns the courses and runs it created and can edit or delete those, plus any run on a course it owns. Each token can create at most 20 courses.
- **Admin** (HTTP Basic auth with the credentials from `.env`): can edit or delete anything, is the only one who can read or dismiss reports, and can hide a course or a run (the dev console's "hidden" checkboxes). Hidden rows stay in the database but no longer exist for anyone else, their owner included. Courses and runs created by the admin have no owner, so only the admin can change them.

Admin credentials:

| Variable | Meaning |
| --- | --- |
| `LEADERBOARD_ADMIN_USER` | Username, defaults to `admin` |
| `LEADERBOARD_ADMIN_PASSWORD` | Required; with it unset every write endpoint returns 503 |

To change them:

```bash
./start.sh set-password
./start.sh             # restart so the server picks them up
```

The dev console asks for the login in a dialog on the first edit (or via the Sign in button in the header) and keeps it for the browser session. From the command line, use `curl -u admin:PASSWORD`.

`./start.sh help` lists all commands.

### Leaderboard backups

`server/backup_db.py` snapshots `server/leaderboard.db` with SQLite's online backup API (safe while the server runs) into `/mnt/Data/Backups/autox-leaderboard/` (override with `AUTOX_BACKUP_DIR`). It only writes a new timestamped file when the database content changed since the last snapshot, keeps the newest 365 snapshots (`AUTOX_BACKUP_KEEP`), and refuses to run if the destination isn't on a mounted drive.

On the public server it runs hourly from the user crontab (`crontab -l`), logging to `~/.local/state/autox-backup.log`.

```bash
python3 server/backup_db.py            # snapshot now
python3 server/backup_db.py list       # show snapshots
python3 server/backup_db.py restore leaderboard-20260904-121417.db
./start.sh                             # restart so the server reopens the restored DB
```

Restoring keeps the DB it replaced next to it as `server/leaderboard.pre-restore-*.db`.

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

- `GET /api/gglc/events` — list of GGLC autocross events that have results (GGLC sometimes publishes title-only pages; those are skipped unless the event is today)
- `GET /api/gglc/events/{event_date}` — full results for one event (`YYYY-MM-DD` or `YYYYMMDD`)

Community leaderboard (SQLite in `server/leaderboard.db`; writes need a device token or admin login, see [Leaderboard auth](#leaderboard-auth)). Responses carry `is_owner` for the caller and never expose owner tokens:

- `GET /api/leaderboard/courses` — courses
- `POST /api/leaderboard/courses` — create a course (`name`, optional `distance_miles`, `legacy_distance_miles`, `description`, `created_by`)
- `GET /api/leaderboard/courses/{course_id}` — course plus its runs sorted by adjusted time
- `PATCH` / `DELETE /api/leaderboard/courses/{course_id}` — edit or delete a course (owner or admin; deleting removes its runs)
- `PUT /api/leaderboard/courses/{course_id}/owner` — admin only: hand a course to a device (`device_token`, or `null` for no owner)
- `PUT /api/leaderboard/courses/{course_id}/hidden` and `PUT /api/leaderboard/runs/{run_id}/hidden` — admin only: hide or unhide (`hidden`: `true`/`false`); hidden rows are omitted from every non-admin response and 404 for non-admin writes
- `POST /api/leaderboard/courses/{course_id}/runs` — add a run to any course (`driver`, `time` as seconds or `m:ss.mmm`, optional `vehicle`, `hp`, `top_speed_mph`, `run_date`, `time_of_day`, `conditions`, `legacy`, `notes`, `source`)
- `PATCH` / `DELETE /api/leaderboard/runs/{run_id}` — edit or delete a run (its poster, the course owner, or admin)
- `POST /api/leaderboard/reports` — flag a course or run (`target_type` of `course`/`run`, `target_id`, `reason`)
- `GET` / `DELETE /api/leaderboard/reports[/{report_id}]` — admin: list reports with their targets, or dismiss one

Legacy runs were set on the old, longer course; their adjusted time is scaled by `distance_miles / legacy_distance_miles`. Average speed is computed from the course distance.

TrackAddict:

- `POST /api/trackaddict/parse` — body is a raw TrackAddict CSV log; returns its laps with times and distances

`server/import_sheet.py` seeds the leaderboard from the HWY 9 Leaderboard spreadsheet snapshot embedded in the script and is safe to re-run.

Laps in the Speedhive API are keyed only by finish position within a session, so drivers are addressed by `position`.
