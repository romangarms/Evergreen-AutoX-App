# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

FastAPI server (`server/app.py`) wrapping the Speedhive/MYLAPS API for Evergreen AutoX race results. An iOS app will be added to this repo later; until then the server is the whole project.

## Running

- `./start.sh` — prompts for a leaderboard admin password if `.env` lacks one, then runs `docker compose up -d --build` if Docker Compose is available (the public server's deploy path) or otherwise creates `.venv`, sources `.env`, and runs the server in the foreground. `./start.sh local` forces the venv path (use this for dev on the Mac, which has Docker installed); `./start.sh set-password` changes the credentials. Running `./.venv/bin/python server/app.py` directly skips `.env`.
- Serves on port 8321, bound to `0.0.0.0` intentionally so an iPhone on the same LAN can reach the Mac during development — do not change it to `127.0.0.1`.

## Lint/format

- `./.venv/bin/ruff check .` and `./.venv/bin/ruff format .` (config in `ruff.toml`). No tests exist yet.

## Gotchas

- **Laps are keyed by finish position, not driver ID.** The Speedhive payload identifies drivers only by their position within a session; `/api/sessions/{id}/drivers/{position}` filters classification rows and laps on `position`.
- `speedhive-tools` is pinned to a commit in `requirements.txt`, and `app.py` reaches into its private internals (`speedhive.generated.api.session_controller`, `SpeedhiveClient._parse_response`) — verify those still work before bumping the pin.
- `server/static/index.html` is a single-file dev console (vanilla JS, tabs for Leaderboard/Speedhive/GGLC) and the test harness: when adding or changing API endpoints, keep it able to exercise them. It hardcodes org ID `151294` as the test org. Number inputs must use `step="any"` — a mismatched `step` silently blocks form submission.
- Leaderboard write endpoints (POST/PATCH/DELETE under `/api/leaderboard`) require HTTP Basic auth from `LEADERBOARD_ADMIN_USER`/`LEADERBOARD_ADMIN_PASSWORD`; with no password set they return 503. `start.sh` writes them to `.env` in single quotes, so passwords cannot contain `'`. Reads are public.
- The custom leaderboard lives in `server/leaderboard.db` (SQLite, gitignored, auto-created by `server/db.py`). `server/import_sheet.py` seeds it from the "HWY 9 Leaderboard" Google Sheet snapshot embedded in the script; it's idempotent. **Adjusted times are computed, not stored**: legacy runs (set on the old, longer course) are scaled by `distance_miles / legacy_distance_miles`. Average speed is likewise computed in `run_to_dict` (course distance ÷ raw time, legacy distance for legacy runs) whenever the distance is known, overriding any stored value. TrackAddict CSV logs carry lap times only in `# Lap N: HH:MM:SS.mmm` comment lines; `/api/trackaddict/parse` takes the raw CSV as the request body (no multipart) and lap 0 is the pre-start segment, not a run.
