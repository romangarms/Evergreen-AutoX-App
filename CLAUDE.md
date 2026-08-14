# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

FastAPI server (`server/app.py`) wrapping the Speedhive/MYLAPS API for Evergreen AutoX race results. An iOS app will be added to this repo later; until then the server is the whole project.

## Running

- `./start.sh` — creates `.venv` and installs deps only if `.venv` is missing, then runs the server. If the venv exists: `./.venv/bin/python server/app.py`.
- Serves on port 8321, bound to `0.0.0.0` intentionally so an iPhone on the same LAN can reach the Mac during development — do not change it to `127.0.0.1`.

## Lint/format

- `./.venv/bin/ruff check .` and `./.venv/bin/ruff format .` (config in `ruff.toml`). No tests exist yet.

## Gotchas

- **Laps are keyed by finish position, not driver ID.** The Speedhive payload identifies drivers only by their position within a session; `/api/sessions/{id}/drivers/{position}` filters classification rows and laps on `position`.
- `speedhive-tools` is pinned to a commit in `requirements.txt`, and `app.py` reaches into its private internals (`speedhive.generated.api.session_controller`, `SpeedhiveClient._parse_response`) — verify those still work before bumping the pin.
- `server/static/index.html` is a throwaway debug UI, but it's the test harness: when adding or changing API endpoints, keep it able to exercise them. Don't polish it. It hardcodes org ID `151294` as the test org.
