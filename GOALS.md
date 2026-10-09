# Goals

Roadmap for the AutoX Live app and server. Items are grouped by area, not by priority; see
[Suggested order](#suggested-order) at the bottom for a sequencing proposal. Items marked **(proposed)**
were not on the original wishlist and are up for debate.

## Where things stand (Oct 2026)

- **App** (iOS 18+, TestFlight 1.5): Live / Friends / Events / Boards / Setup tabs. Events come from
  Speedhive and GGLC. Pins, nicknames, and the ME car are stored per event in `UserDefaults` on the device
  only. Data refreshes on pull-to-refresh; there is no background polling. Community leaderboards live in
  the Boards tab: browsing is open, creating a board or posting needs Sign in with Apple, times come from
  a TrackAddict CSV only, boards can be unlisted behind a join code, and anything can be reported, hidden
  locally, or its poster blocked. The Acceleration board takes drag-mode logs the same way.
- **Server** (FastAPI, Docker on https://autox.romangarms.com): Speedhive proxy, GGLC scraper, SQLite
  leaderboard, Sign in with Apple accounts on top of per-device tokens, one admin login (HTTP Basic, or a
  session cookie in the dev console), a read-only key for the website, moderation (report queue, hide flag,
  blocks, bans, profanity filter), TrackAddict CSV parser, hourly DB backups, public landing, support and
  privacy pages. pytest covers accounts, moderation, unlisted boards, acceleration and the TrackAddict
  parser. Additive column migrations only.
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

Depends on: auto-refresh (under [Other app goals](#other-app-goals)) so the phone has fresh data to push.

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
- Side benefit: an active audio session keeps the app alive in the background, so the card keeps updating
  while driving to grid.

### Notifications

- **New run for the ME car**: time, penalty, position, delta to best.
- **A pinned friend beat your best** (or set a new PB).
- **Session went live / results posted** for an org you follow.
- **Leaderboard**: someone took the top spot on a course you have a time on.

Delivered by **APNs push** from the server, not local notifications: local delivery stops once iOS suspends
the app, which is exactly when a notification matters. The server polls Speedhive for sessions people are
subscribed to and pushes on change, so it works with the app closed.

- No extra hosting: APNs is Apple's delivery gateway, and the existing server is the provider that sends to
  it. It needs an APNs auth key (`.p8` + Key ID + Team ID from the developer portal, same style as the App
  Store Connect key `deploy.sh` uses), a JWT signed with that key, an HTTP/2 client (`httpx[http2]` or
  `aioapns`), and outbound HTTPS to `api.push.apple.com`.
- An APNs token on `devices`, registered by the app, and per-account subscriptions (which car is ME, which
  friends are pinned, which orgs to follow). The pins and ME car arrive with
  [account sync](#account-sync-for-pins-and-nicknames).
- Server-side Speedhive polling (see [Other server goals](#other-server-goals)).

### TrackAddict upload to the leaderboard

Done (Sept 2026): the Post a Time sheet imports a CSV through the Files picker, lists the parsed laps, and
fills in the time and top speed from the chosen lap with `source = 'trackaddict'`. The Acceleration board
posts the same way (Oct 2026) from a drag-mode log, which supplies 0-30, 0-60, and the 1/8 and 1/4 mile. Still open:

- Accept the CSV straight from the share sheet / TrackAddict's export flow, not only the Files picker.
- Keep the raw CSV on the server next to the run so admins can verify a claimed time and so a future
  feature can render the GPS trace / speed graph.

Posts go live immediately. There is no approval queue; reports, the admin hide flag, blocks, bans and the
profanity filter are the moderation.

### Custom leaderboards for everyone

Done (Sept 2026): create a board from the app (name, distance, description, creator name), anyone signed in
posts runs, the creator edits/deletes the board and any run on it, and every board or run can be reported
(admin sees the queue in the dev console) or hidden locally. Since then (Oct 2026):

- Ownership sits on Sign in with Apple accounts, so a board survives losing the phone.
- Unlisted boards for a private group, shared by join code rather than by link.
- A page per driver and car with all their runs on the course.

Still open:

- The seeded HWY 9 boards are still admin-owned developer content; recreate them under a user's account
  or keep them clearly labelled before App Store review.

### Other app goals

- **Auto-refresh and live session detection.** Poll the selected session on a timer while the Live tab is
  open, and auto-select "today's" session for the followed org so race day starts with zero taps. This is
  the prerequisite for Watch, CarPlay, and notifications all being useful.
- **Widgets and Live Activities.** A Lock Screen / Dynamic Island Live Activity with the latest run is the
  most on-brand glance surface Apple offers and uses the same data as the Watch page 1.
- **Driver profile across events.** Car numbers repeat, so pins and nicknames are per event today. Link a
  Speedhive driver name to an account and show their history: PBs, cone counts, results by event.
- ~~**GGLC parity.**~~ Done (Sept 2026): GGLC events sit in the Events tab next to Speedhive's, and the
  newest one is the launch default.
- **Share links.** Deep links to a session, driver, or leaderboard course so results can be posted in a group
  chat and opened in the app.
- **App Store release.** Move off TestFlight. The privacy and support pages, the App Store screenshots and
  the App Store Connect copy (`AppStoreConnect.md`) exist, and external TestFlight is open. Still open: the
  submission itself, plus review notes about the silent-audio CarPlay approach if that ships first (Apple
  may push back; have a fallback of removing the toggle).

---

## Server

### Identity and accounts (prerequisite)

Done (Oct 2026): Sign in with Apple in the app, verified by the server and attached to the device's
existing Bearer token; `users` and `devices` tables; HTTP Basic still works for `curl`, and the dev console
has its own session cookie; reads stay unauthenticated. Still open:

- An APNs token on `devices`, for [push](#notifications).
- Any admin rights beyond the `.env` login (see [Admin features](#admin-features)).

### Account sync for pins and nicknames

A signed-in user's pins, nicknames and ME car follow their account across their phones. They stay private
to that account: there are no groups and no shared nicknames.

- Stored per account, keyed as today by (event, car number), since numbers repeat across events.
- Signed-out devices keep everything in `UserDefaults` as now; signing in uploads what the device has.
- Conflict handling is last-write-wins with `updated_at`; this is nicknames, not bank transfers.
- Sync transport: a `GET` with `?since=` plus a `PUT`, polled on app foreground. No websockets needed.
- A new identity-keyed table, so it goes in `_adopt_device`, `delete_account` and `IDENTITY_COLUMNS`, and
  the privacy page has to say the app sends it.

### Admin features

Not planned yet. Admin today is the one `.env` login, with the dev console's Moderation tab (reports, bans,
users) as its UI, and it can edit, hide or delete anything. What more it should be is undecided; ideas
that have come up, none of them committed:

- Per-user admin rights, so someone else can moderate from their own account, with the `.env` password as
  a break-glass login.
- An audit log of who changed what, when.
- Merging duplicate driver names ("R. Garms" vs "Roman Garms").
- A backup `verify` command that opens the newest snapshot and counts rows, and a log line when a backup
  run fails.

Whatever is added goes in the dev console rather than a second web app.

### Other server goals

- **Speedhive caching and polling.** Once the server polls sessions for push, serve those cached results to
  the app too. This cuts Speedhive calls when ten phones refresh at once and makes the app faster.
- **Tests.** pytest is in (Oct 2026) for accounts, moderation, unlisted boards, acceleration and the
  TrackAddict parser. Still untested: the leaderboard math (legacy scaling, avg speed), and the Speedhive
  routes, which need recorded fixtures so the `speedhive-tools` pin can be bumped with confidence.
- **Rate limiting.** Writes need an account, bans stop a poster, and an account is capped at 20 boards and
  20 acceleration entries; add a per-request rate limit on the write endpoints.
- **Observability.** Structured request logs, a `/healthz` endpoint for the reverse proxy and Docker
  healthcheck, and error reporting (even just a log tail cron that emails).

---

## Suggested order

1. **Auto-refresh + live session detection** in the app. Small, and everything else builds on it.
2. ~~**Identity** (Sign in with Apple, users table, tokens) on the server.~~ Shipped Oct 2026.
3. **Account sync for pins and nicknames**, the smallest feature on top of identity, and what push
   subscriptions are built from.
4. ~~**TrackAddict upload** and **custom leaderboards**~~ shipped on device tokens, then moved onto accounts.
5. **Live Activity / widgets** and **CarPlay Now Playing** with the background audio session.
6. **Apple Watch** app, fed from the phone.
7. **APNs push** and server-side Speedhive polling.
8. Share links, driver profiles, tests, rate limiting, observability, App Store release: spread through the
   above as each feature makes them necessary.

## Open questions

- What should admin look like beyond the single login? See [Admin features](#admin-features).
- Does the silent-audio CarPlay trick pass App Store review? If not, the fallback is Live Activities and the
  Watch, with CarPlay dropped or done properly with the entitlement.
- Should the Watch talk to the server directly (works without the phone) or only via the phone (simpler)?
