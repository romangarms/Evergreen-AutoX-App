# AutoX Live

Autocross timing and results in your pocket, built around the autocross events at Evergreen Speedway. An independent project, not affiliated with any event organizer or timing provider. A SwiftUI iOS app backed by a small FastAPI server that wraps the MyLaps Speedhive API (via [speedhive-tools](https://github.com/cosmoslab58/speedhive-tools)), with bonus support for Golden Gate Lotus Club autocross results scraped from gglotus.org.

## Screenshots

| Live timing | Friends | Head-to-head |
| :---: | :---: | :---: |
| ![Live timing](screenshots/appstore-6.9/1%20Live.png) | ![Friends](screenshots/appstore-6.9/3%20Friends.png) | ![Head-to-head compare](screenshots/appstore-6.9/4%20Compare.png) |

| Events | Leaderboard | Leaderboard driver |
| :---: | :---: | :---: |
| ![Event browser](screenshots/appstore-6.9/7%20Events.png) | ![Community leaderboard](screenshots/appstore-6.9/5%20Leaderboard.png) | ![A driver's runs on a leaderboard](screenshots/appstore-6.9/6%20Leaderboard%20Driver.png) |

## The app

Five tabs:

- **Live** — the leaderboard for the selected session: position, car number, best time, and run count for every entry. Your own car gets a **ME** tag and highlight, and you can star cars to keep an eye on them. Pull to refresh.
- **Friends** — the cars you starred, with everyone's gap to your best time. Mark which car is you and give cars nicknames from a driver's ••• menu, and pick any two for a head-to-head: best/average/spread stats, a times-over-the-day chart, and a run-by-run gap breakdown.
- **Events** — browse and search events from Speedhive and GGLC, then drill into sessions and individual drivers.
- **Boards** — community leaderboards. Anyone can browse them; creating one or posting a time needs Sign in with Apple, so your boards and times follow you to a new phone. Times are posted from a TrackAddict CSV export (the time and top speed come from the log, not from typing). A board can be unlisted, which keeps it out of the list until someone adds it with the join code its creator shares. The **Acceleration** board at the top ranks 0-60, 0-30 and drag strip times, posted from a TrackAddict drag-mode log. Any board or entry can be reported or hidden, and a poster can be blocked. Creators can edit and delete their own boards and any run on them.
- **Setup** — sign in or out, change your username, delete your account, manage blocked posters, and find the support and privacy links. Tapping the version line seven times reveals dev mode, which unlocks pointing the app at your own server and switching Speedhive organizations (Events → ⋯ menu).

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

The site root is the public landing page with the TestFlight link; `/support` and `/privacy` are the pages the app links to.

Open http://localhost:8321/dev for a bare-bones dev console: a leaderboard editor, the acceleration board, a Speedhive browser (enter an org ID, the number in the org's URL on speedhive.mylaps.com, then click through events → sessions → drivers), and a GGLC results browser. Without an admin login it is read-only: the editing controls, the TrackAddict importer, and the Moderation tab (reports, bans, and the list of users and their devices) only appear after signing in with the credentials from `.env`, and hidden boards and runs are never listed.

### Leaderboard auth

Reading the leaderboards is public, except for unlisted boards (below). Writes accept these callers:

- **Device token** (`Authorization: Bearer <token>`): the app mints a random token on first launch and keeps it in the Keychain. A token owns what it created and can edit or delete that, plus any run on a course it owns.
- **Account**: once a device signs in with Apple, everything it posted moves to the account, and every device signed in to that account acts as the same owner. Creating a course or posting a run or acceleration entry needs an account; editing does not. An account can own at most 20 courses and 20 acceleration entries. Text a device posts goes through a profanity filter.
- **Admin** (HTTP Basic auth with the credentials from `.env`, or the dev console's session cookie): can edit or delete anything, is the only one who can read or dismiss reports, ban a poster, and hide a course or a run (the dev console's "hidden" checkboxes). Hidden rows stay in the database but no longer exist for anyone else, their owner included. Courses and runs created by the admin have no owner until the admin assigns one.

An **unlisted** board exists only for its owner, the devices that joined it with its join code, and the admin. Everyone else, requests with no credentials included, gets a 404 and never sees it in the list. The website reads unlisted boards with a separate read-only key (`X-Leaderboard-Key`); that key ships in a public bundle, so it never returns a join code and cannot write.

Settings in `.env`:

| Variable | Meaning |
| --- | --- |
| `LEADERBOARD_ADMIN_USER` | Admin username, defaults to `admin` |
| `LEADERBOARD_ADMIN_PASSWORD` | Required; with it unset, admin Basic auth returns 503 |
| `LEADERBOARD_READ_KEY` | The website's read key; `./start.sh` generates one if it is missing |
| `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` | Optional Sign in with Apple key, so deleting an account also revokes its Apple sign-in |

To change them:

```bash
./start.sh set-password            # admin username and password
./start.sh read-key                # print the website's read key
./start.sh new-read-key            # replace it; rebuild the website with the new one
./start.sh apple-key AuthKey_XXXXXXXXXX.p8
./start.sh                         # restart so the server picks them up
```

The dev console's Sign in button posts the login once and gets back a 30-day HttpOnly cookie; the page never stores the password, and changing the password signs every browser out. From the command line, use `curl -u admin:PASSWORD`.

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

Listed in [API.md](API.md).

`server/import_sheet.py` seeds the leaderboards from spreadsheet snapshots embedded in the script (the HWY 9 Leaderboard sheet, the WA Cannonball and Disco sheets, and the acceleration sheet) and is safe to re-run.

## Tests and lint

```bash
./.venv/bin/python -m pytest
./.venv/bin/ruff check .
./.venv/bin/ruff format .
```
