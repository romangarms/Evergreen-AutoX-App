# Goals

Roadmap for the Evergreen AutoX app and server. Items are grouped by area, not by priority; see
[Suggested order](#suggested-order) at the bottom for a sequencing proposal. Items marked **(proposed)**
were not on the original wishlist and are up for debate.

## Where things stand (Sept 2026)

- **App** (iOS 26, TestFlight 1.1): Live / Friends / Events / Setup tabs. Pins, nicknames, and the ME car
  are stored per event in `UserDefaults` on the device only. Data refreshes on pull-to-refresh; there is
  no background polling. The custom leaderboard is read-only in the app.
- **Server** (FastAPI, Docker on https://autox.romangarms.com): Speedhive proxy, GGLC scraper, SQLite
  leaderboard with a single shared admin password (HTTP Basic), TrackAddict CSV parser, hourly DB backups.
  No accounts, no tests, no schema migrations beyond `CREATE TABLE IF NOT EXISTS`.
- **Design concept**: `Evergreen AutoX Timing.html` includes mockups for the Watch app and the CarPlay
  Now Playing card, referenced below.

## Guiding principles

1. **Race day first.** Every feature should be usable one-handed in a paddock with bad LTE. Prefer glanceable
   surfaces (Watch, CarPlay, notifications, widgets) over more screens to tap through.
2. **Speedhive stays the source of truth for timing.** The server caches and reshapes it; we never store
   corrected timing that could drift from the official results. The custom leaderboard is the exception and is
   explicitly community data.
3. **Shared state needs identity.** Anything "for everyone" (synced nicknames, public leaderboards, uploads,
   admin) hangs off one account model, built once.
4. **Cheap to run.** One small server, SQLite, no paid services unless a feature truly needs one (APNs is free).

---

## App

### Apple Watch

Companion watchOS app per the design concept: two pages, swipe between them.

- **Page 1, Last run**: latest time, cone/penalty string, best time, current position.
- **Page 2, Friends**: pinned list with each friend's best and gap to you; red when they're ahead.
- Follows the ME car and pins set on the phone.
- Data path: start with `WatchConnectivity` pushing the phone's already-fetched session data (no separate
  auth or network on the wrist). Independent networking on the Watch can come later if the phone tether is
  unreliable at the track.
- **(proposed)** A complication / Smart Stack widget showing last time and position, so the Watch face is the
  first glance and the app is the second.
- **(proposed)** Haptic tap when a new run for the ME car lands.

Depends on: [auto-refresh](#auto-refresh-and-live-session-detection-proposed) so the phone has fresh data
to push.

### CarPlay via Now Playing

Per the design concept: no CarPlay entitlement. The app registers as an audio source, plays a silent track,
and writes the current run into `MPNowPlayingInfoCenter`. CarPlay renders it in the stock Now Playing card
next to Maps.

We own four strings and one 600x600 image:

| Field | Carries | Constraint |
| --- | --- | --- |
| Title | Run time, penalty appended | Centered and truncated; keep under ~22 chars |
| Artist | Context: best, delta, class position | Tightest line, abbreviate hard |
| Album | Friend gap (only visible on the full-screen Now Playing view) | Dropped on the dashboard card |
| Artwork | Repeats the time as a glance-level mark | ~135px on the dashboard card, so no fine detail |

Work items:

- Background audio session + silent looping track; confirm it survives phone lock and Maps in the foreground.
- Artwork generator (rendered SwiftUI view to `UIImage`) that updates per run.
- Toggle in Setup so the silent track only plays when the user opts in for the day.
- Verify behaviour when the user also plays music: this approach takes over Now Playing, so the toggle
  needs to make that trade-off obvious.
- Side benefit: an active audio session keeps the app alive in the background, which is also the cheapest
  way to keep polling for new runs while driving to grid.

### Notifications

- **New run for the ME car**: time, penalty, position, delta to best.
- **A pinned friend beat your best** (or set a new PB).
- **Session went live / results posted** for an org you follow.
- **Leaderboard**: someone took the top spot on a course you have a time on.

Two delivery options; pick one deliberately:

1. **Local notifications** from the app while it polls in the background (audio session or Background App
   Refresh). Zero server work, but unreliable once iOS suspends the app.
2. **APNs push** from the server. The server polls Speedhive for sessions people are subscribed to and
   pushes on change. Reliable and works with the app closed, but needs device-token registration, an APNs
   key, and per-user subscriptions on the server (see [Identity](#identity-and-accounts-prerequisite)).
   No extra hosting: APNs is Apple's delivery gateway, and the existing server is the provider that sends to
   it. All it needs is an APNs auth key (`.p8` + Key ID + Team ID from the developer portal, same style as
   the App Store Connect key `deploy.sh` uses), a JWT signed with that key, an HTTP/2 client (`httpx[http2]`
   or `aioapns`), and outbound HTTPS to `api.push.apple.com`.

Recommendation: ship (1) alongside the CarPlay work since the audio session makes it nearly free, then move
to (2) once accounts exist.

### TrackAddict upload to the leaderboard

Today `/api/trackaddict/parse` exists but the app has no way to use it.

- Accept a TrackAddict CSV via the share sheet (`.csv` UTI / Files picker) and from the TrackAddict app's
  export flow.
- Show the parsed laps (lap 0 is the pre-start segment, not a run) and let the user pick which laps to submit,
  which course they belong to, and fill in vehicle/hp/conditions with sensible defaults from their last run.
- Submit as leaderboard runs with `source = 'trackaddict'`, attributed to the uploader.
- **(proposed)** Keep the raw CSV on the server next to the run so admins can verify a claimed time and so
  a future feature can render the GPS trace / speed graph.
- **(proposed)** Uploads land in a pending state until an admin approves, or go live immediately with a
  visible "unverified" tag. Decide which; the first is safer, the second is more fun.

Depends on: [Identity](#identity-and-accounts-prerequisite) for attribution, and on the leaderboard write
API accepting per-user tokens rather than the shared admin password.

### Custom leaderboards for everyone

Let any user create a course/leaderboard that everyone can see, not just the admin-seeded HWY 9 board.

- Create a course from the app: name, distance, optional description and location.
- Anyone can submit runs (manual or TrackAddict); the creator can edit/delete runs on their board.
- Boards are public by default; **(proposed)** optional unlisted boards shared by link for a private group.
- **(proposed)** Vehicle classes / filters (stock vs. modified, hp brackets) so one board can host mixed cars.
- **(proposed)** Per-driver detail in the app: all their runs on the course, PB progression over time.

Depends on: [Identity](#identity-and-accounts-prerequisite), ownership on `courses`, and
[Admin](#admin-features) for cleanup.

### Other app goals (proposed)

- **Auto-refresh and live session detection.** Poll the selected session on a timer while the Live tab is
  open, and auto-select "today's" session for the followed org so race day starts with zero taps. This is
  the prerequisite for Watch, CarPlay, and notifications all being useful.
- **Widgets and Live Activities.** A Lock Screen / Dynamic Island Live Activity with the latest run is the
  most on-brand glance surface Apple offers and uses the same data as the Watch page 1.
- **Driver profile across events.** Car numbers repeat, so pins and nicknames are per event today. With
  accounts, link a Speedhive driver name to a user and show their history: PBs, cone counts, results by
  event.
- **Season standings.** Points across an org's events (Evergreen and GGLC) for a class or for the friends
  list.
- **GGLC parity.** The server already scrapes GGLC results; surface them in the app as another org.
- **Share links.** Deep links to a session, driver, or leaderboard course so results can be posted in a group
  chat and opened in the app.
- **Offline resilience.** Cache the last-loaded session and leaderboard so the app still shows something
  when Speedhive or LTE is down.
- **App Store release.** Move off TestFlight: privacy policy, App Store screenshots, review notes about the
  silent-audio CarPlay approach (Apple may push back; have a fallback of removing the toggle).

---

## Server

### Identity and accounts (prerequisite)

Almost every shared feature needs to know who a request is from. Build this once, small:

- **Sign in with Apple** in the app, exchanged for a server-issued token. No passwords to manage.
- `users` table: id, Apple subject, display name, created_at, role (`user` / `admin`).
- Bearer-token auth on the API; keep HTTP Basic working for the dev console and `curl`.
- Device registration (`devices` table with APNs token) for push.
- Everything today keeps working unauthenticated for reads.

### Nickname sync

Nicknames, pins, and the ME car sync across everyone's devices.

- Model: a **group** (default: "Evergreen AutoX") that users belong to. Nicknames are group-scoped, so the
  whole run group sees "Dave (Miata)" for car 42 without each person typing it.
- Keep per-user overrides local: my nickname for you wins over the group one on my phone.
- Conflict handling is last-write-wins with `updated_at`; this is nicknames, not bank transfers.
- Scope by driver identity rather than car number where possible, since numbers repeat across events; fall
  back to (event, number) as today.
- Sync transport: simple `GET /api/groups/{id}/nicknames?since=` + `PUT`, polled on app foreground. No
  websockets needed.

### Admin features

- Roles: `admin` on `users`. Replace the single shared password with per-user admin rights, keeping the
  `.env` password as a break-glass login.
- **Approval queue** for uploaded runs and user-created courses (if the pending model is chosen).
- **Edit / merge / delete** any run or course; merge duplicate driver names ("R. Garms" vs "Roman Garms").
- **Audit log**: who changed what, when. Cheap to add now, painful to retrofit.
- **Group management**: invite links, remove members, promote admins.
- **Dev console becomes the admin UI**: `server/static/index.html` already exercises every endpoint; extend
  it with sign-in, the queue, and the audit log rather than building a second web app.
- **Backups**: keep the existing hourly snapshot job; add a `verify` command that opens the newest snapshot
  and counts rows, and alert (log line is fine) if a backup run fails.

### Other server goals (proposed)

- **Speedhive caching and polling.** Once the server polls sessions for push, serve those cached results to
  the app too. This cuts Speedhive calls when ten phones refresh at once and makes the app faster.
- **Schema migrations.** Move from `CREATE TABLE IF NOT EXISTS` to numbered migrations before adding the
  users/groups/nicknames tables; the backup script gives a safety net but not a rollback.
- **Tests.** The leaderboard math (legacy scaling, avg speed) and the TrackAddict parser are pure functions
  with zero tests today. Add pytest with recorded Speedhive fixtures so the `speedhive-tools` pin can be bumped
  with confidence.
- **Rate limiting and abuse protection** on write endpoints once they're open to all users.
- **Observability.** Structured request logs, a `/healthz` endpoint for the reverse proxy and Docker
  healthcheck, and error reporting (even just a log tail cron that emails).
- **API versioning.** Prefix new endpoints with `/api/v1` before the App Store release so old app versions
  keep working.

---

## Suggested order

1. **Auto-refresh + live session detection** in the app. Small, and everything else builds on it.
2. **Identity** (Sign in with Apple, users table, tokens) on the server. Nothing shared ships without it.
3. **Nickname sync** and **per-user admin roles**, since they're the smallest features on top of identity and
   prove the model.
4. **TrackAddict upload** and **custom leaderboards**, sharing the same upload + ownership work.
5. **CarPlay Now Playing** with the background audio session, and **local notifications** riding on it.
6. **Apple Watch** app, fed from the phone.
7. **APNs push** and server-side Speedhive polling.
8. Admin queue, audit log, tests, migrations, App Store release: spread through the above as each feature
   makes them necessary.

## Open questions

- Pending-approval vs. instant-publish for uploaded runs and new courses?
- Is one group enough (everyone in the app is Evergreen AutoX), or do GGLC users need their own?
- Does the silent-audio CarPlay trick pass App Store review? If not, the fallback is Live Activities and the
  Watch, with CarPlay dropped or done properly with the entitlement.
- Should the Watch talk to the server directly (works without the phone) or only via the phone (simpler)?
