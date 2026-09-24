# App Store Connect copy — AutoX Live

Paste-ready text for App Store Connect. Character limits are Apple's; counts were checked when this was
written, so re-check after editing.

## Rename the app record first

App Store Connect → the app → **App Information** → Name. Testers see this name in the TestFlight app, not
the home-screen name from the build. App Store names must be unique, so if "AutoX Live" is taken:

1. AutoX Live Timing
2. AutoX Live: Autocross Timing

The bundle ID (`com.romangarms.Evergreen-AutoX-App-iOS`) stays; it is never shown to users.

---

## TestFlight → Test Information

**Beta App Description** (testers see this on the invite)

> AutoX Live puts autocross timing in your pocket. Open an event to see results as they post, star your
> friends to follow just their runs and the gaps between you, compare any two drivers head-to-head, and post
> your own best times to community leaderboards.
>
> This is an early beta from an independent developer. It is not affiliated with any event organizer, club,
> or timing provider. Results come from the organizers' public timing feeds, so an event shows up once its
> organizer publishes it.

**Feedback Email:** romangarms@gmail.com
**Marketing URL:** https://autox.romangarms.com/support
**Privacy Policy URL:** https://autox.romangarms.com/privacy

**What to Test** (per build; edit for each upload)

> Thanks for testing AutoX Live!
>
> - Live tab: open the latest event, switch sessions, pull down to refresh. Do times and positions match
>   what you saw at the event?
> - Star a few cars, mark one as "me" (Setup tab), then check the Friends tab and the head-to-head compare.
> - Events tab → Community: open a leaderboard, post a time (typed in, or imported from a TrackAddict CSV),
>   then delete it.
> - Anything confusing, slow, or wrong: screenshot it in TestFlight and send feedback, or email
>   romangarms@gmail.com.

### Beta App Review Information

- **Sign-in required:** No (uncheck it; the app has no accounts).
- **Contact:** Roman Garms, romangarms@gmail.com, plus a phone number Apple can reach.
- **Review Notes:**

> AutoX Live shows autocross (cone-course time trial) results and lets drivers post times to community
> leaderboards. There is no login; all features are available on first launch.
>
> Where to look: the app opens on the newest event (Live tab). The Events tab lists all events, and its
> "Community" section holds the user-created leaderboards.
>
> Data: event results are read from the organizers' publicly available timing results through our server
> (autox.romangarms.com). The app is independent and says so on the Setup tab; organizer names appear
> only as labels on their own events.
>
> User-generated content: before their first post, users must accept community guidelines (no offensive
> content, closed-course times only). Every leaderboard and run has a Report action (… menu), reports go to
> a moderation queue we review within 24 hours, and offending content is removed.
> Users can also hide any leaderboard on their device (… menu → Hide Leaderboard). Contact details are on
> the Support page linked from the Setup tab.
>
> The app requests no permissions in normal use. The local-network usage string exists only for a
> developer option that points the app at a development server on the LAN.

---

## App Store listing (not needed for TestFlight)

**Name** (30): AutoX Live
**Subtitle** (30): Autocross timing & results
**Primary category:** Sports. **Secondary:** Utilities.

**Promotional Text** (170)

> Follow autocross results as they post, pin your friends to see the gaps, compare runs head-to-head, and
> post your best times to community leaderboards.

**Description** (4000)

> AutoX Live puts autocross timing in your pocket. See results the moment they post, keep an eye on your
> friends and rivals, and find out exactly where the time went.
>
> LIVE RESULTS
> • Open an event and see every car's best time, position, and run count
> • Switch between sessions and pull to refresh between runs
> • Tap any car for its run-by-run breakdown: best, average, spread, and every run
>
> FRIENDS
> • Star the cars you care about to get a short list of just your people
> • Mark your own car to see your gap to everyone else
> • Give cars nicknames, because "Silver BMW Coupe" is not a name
>
> HEAD-TO-HEAD
> • Compare any two drivers side by side
> • Best, average, spread, and a chart of both drivers' times over the day
>
> COMMUNITY LEADERBOARDS
> • Create a leaderboard for your course, test day, or club
> • Post a time by hand or import it from a TrackAddict lap log
> • Per-car entries with average and top speed
> • Report or hide anything that doesn't belong
>
> NO ACCOUNT, NO ADS, NO TRACKING
> There is nothing to sign up for. Your pins, nicknames, and settings stay on your phone.
>
> AutoX Live is an independent app and is not affiliated with or endorsed by any event organizer, club,
> or timing provider. Event results come from organizers' publicly available timing feeds and appear
> when the organizer publishes them. Community leaderboards are for times set at sanctioned events or on
> closed courses only.

**Keywords** (100, comma-separated, no spaces; words already in the name are indexed for free)

```
autocross,solo,timing,results,laps,cones,racing,motorsport,leaderboard,pax,trackday,stopwatch
```

Do not add organizer or product names (Evergreen, Speedhive, MYLAPS, SCCA, TrackAddict) to keywords;
trademarked terms there are a common metadata rejection.

**Support URL:** https://autox.romangarms.com/support
**Marketing URL:** leave empty, or the support URL
**Privacy Policy URL:** https://autox.romangarms.com/privacy
**Copyright:** 2026 Roman Garms

### App Privacy answers

Data is collected (the server stores posts and the device token). Conservative answers:

| Data type | Collected | Linked to user | Tracking | Purpose |
| --- | --- | --- | --- | --- |
| User Content → Other User Content (leaderboards, times, notes) | Yes | Yes | No | App Functionality |
| Contact Info → Name (the name/nickname typed on a post) | Yes | Yes | No | App Functionality |
| Identifiers → Device ID (the random app-generated token) | Yes | Yes | No | App Functionality |

Everything else: not collected. The TrackAddict CSV is parsed in memory and not stored, so its GPS data
does not count as collected location.

### Age rating

Answer "Yes" to user-generated content. No other content flags apply.

### Screenshots

Required: one iPhone 6.9" set, 1320 × 2868 (Pro Max simulator); smaller sizes are scaled from it. No iPad
set, since the app is iPhone-only. The current set is `screenshots/appstore-6.9/`, numbered in upload order,
with a 1284 × 2778 copy in `screenshots/appstore-6.5/` for the 6.5" slot. The loose PNGs in `screenshots/`
are 1206 × 2622 and predate leaderboards. Order:

1. Live results list with the ME car and a few stars
2. Driver detail (run-by-run)
3. Friends with gaps
4. Head-to-head compare chart
5. Community leaderboard
6. Leaderboard driver (run history)
7. Events list
8. GGLC driver detail (official best, optional)

Shoot with an event whose entries are car descriptions rather than people's names, and with leaderboards
that are clearly closed-course. Every screen that singles someone out must single out the developer, never
another entrant: the 2026-09-21 set used the 2026-08-09 Speedhive event (ME #44, pins 44, 13, 72, 41, 23:
the developer's car and friends), the developer's own page from the 2026-04-19 GGLC event (car 186), and,
for the leaderboards, a local server on a scratch DB seeded with a fictional closed-course board where the
opened entry is "Roman" and every other driver is made-up initials. PNGs must have no alpha channel or App
Store Connect rejects them.
