# API endpoints

Everything the server in `server/app.py` answers. Reads are public unless noted; who may write is covered in the README's [Leaderboard auth](README.md#leaderboard-auth). Responses never carry a device token or an Apple identifier: a device is named by its row id, an account by its user id, and ownership shows up only as `is_owner` and `has_owner`.

Writes are rate limited per caller address (`rate_limit` in `server/app.py`): 30 a minute, 20 photo submissions an hour, and 10 logins (`POST /api/admin/session`, `POST /api/account/apple`, or a wrong admin password anywhere) per 15 minutes. Past that the answer is 429 with `Retry-After`. Reads, the admin, and Apple's notifications are not limited.

## Speedhive

- `GET /api/orgs/{org_id}` — org info
- `GET /api/orgs/{org_id}/events?limit=&offset=` — events
- `GET /api/events/{event_id}/sessions` — sessions for an event
- `GET /api/sessions/{session_id}/results` — raw classification
- `GET /api/sessions/{session_id}/laps` — raw laps (grouped per finish position)
- `GET /api/sessions/{session_id}/drivers` — distilled driver list
- `GET /api/sessions/{session_id}/drivers/{position}` — one driver's raw result + laps

Laps in the Speedhive API are keyed only by finish position within a session, so drivers are addressed by `position`.

Every Speedhive and GGLC answer is cached in memory (`server/cache.py`): results, laps and a GGLC event for 10 seconds, the org, event and session lists for 60. The app reloads an open event every 10 seconds, so upstream sees one request per page per window however many phones are watching.

## GGLC

Scraped from gglotus.org result pages.

- `GET /api/gglc/events?year=` — GGLC autocross events that have results, for the given year (default: this year). GGLC sometimes publishes title-only pages; those are skipped unless the event is today
- `GET /api/gglc/events/{event_date}` — full results for one event (`YYYY-MM-DD` or `YYYYMMDD`)

## Community leaderboards

SQLite in `server/leaderboard.db`. Hidden rows are omitted from every non-admin response and 404 for non-admin writes. An unlisted course exists only for its owner, its members, the admin and the website's read key; for everyone else it is missing from the list and 404s.

Courses:

- `GET /api/leaderboard/courses?region=` — courses the caller can see, optionally only one region (`CA`, `WA`)
- `POST /api/leaderboard/courses` — create a course (`name`, optional `distance_miles`, `legacy_distance_miles`, `description`, `created_by`, `unlisted`; `region` is admin only). A device needs an account and can own at most 20
- `GET /api/leaderboard/courses/{course_id}` — course plus its runs sorted by adjusted time. The owner, members and admin also get its `join_code`
- `PATCH` / `DELETE /api/leaderboard/courses/{course_id}` — edit or delete a course (owner or admin; deleting removes its runs)
- `PUT /api/leaderboard/courses/{course_id}/owner` — admin only: hand a course to someone from the users list (`person`: `{kind, id}`) or to a device (`device_token`); neither means no owner
- `PUT /api/leaderboard/courses/{course_id}/hidden` — admin only: hide or unhide (`hidden`: `true`/`false`)

Unlisted courses:

- `POST /api/leaderboard/join` — add an unlisted course to this device's list (`code`, the course's join code)
- `DELETE /api/leaderboard/courses/{course_id}/membership` — leave a course joined that way
- `GET` / `POST /api/leaderboard/courses/{course_id}/members` and `DELETE …/members/{kind}/{id}` — admin only: list, add (`kind` of `user`/`device`, `id`) or remove the people an unlisted course exists for, without their needing the join code

Runs:

- `POST /api/leaderboard/courses/{course_id}/runs` — add a run to any course the caller can see (`driver`, `time` as seconds or `m:ss.mmm`, optional `vehicle`, `hp`, `top_speed_mph`, `run_date`, `time_of_day`, `conditions`, `legacy`, `notes`, `source`). A device needs an account
- `PATCH` / `DELETE /api/leaderboard/runs/{run_id}` — edit or delete a run (its poster, the course owner, or admin)
- `PUT /api/leaderboard/runs/{run_id}/hidden` — admin only: hide or unhide

Legacy runs were set on the old, longer course; their adjusted time is scaled by `distance_miles / legacy_distance_miles`. Average speed is computed from the course distance whenever it is known.

## Acceleration board

- `GET /api/acceleration` — entries ranked by 0-60 then 0-30, missing times last. Everyone but the admin gets a poster's best entry per year and vehicle, with the rest in its `other_runs`
- `POST /api/acceleration` — add an entry (`vehicle`, optional `year`, `driver`, `hp`, `weight_lb`, `zero_to_30_seconds`, `zero_to_60_seconds`, `eighth_mile_seconds`, `eighth_mile_mph`, `quarter_mile_seconds`, `quarter_mile_mph`, `notes`, `source`). A device needs an account and at least one time, and is limited to 20 entries
- `PATCH` / `DELETE /api/acceleration/{entry_id}` — the poster or admin; only the admin can set `hidden`

## Submissions for review

A time typed in by hand, with a photo as proof. Nothing is posted until the admin approves it, and the photo is readable only by the admin.

- `POST /api/submissions` — signed-in device only: submit a run (`course_id` plus `run`, the same fields as posting a run) or an acceleration entry (`acceleration`, the same fields as posting one), with `proof`, a base64 JPEG or PNG of at most 4 MB. `vehicle` and `hp` are required here, and so is `year` on an acceleration entry. At most 5 can be waiting per account
- `GET /api/submissions` — this device's submissions that are waiting or were rejected, each with a one-line `summary`, its `status` and the admin's `review_note`
- `DELETE /api/submissions/{submission_id}` — its submitter withdraws it, or the admin removes it
- `GET /api/admin/submissions?status=` — admin only: the queue with each `submitter` (`status` of `pending`, the default, `approved`, `rejected` or `all`)
- `GET /api/admin/submissions/{submission_id}/proof` — admin only: the photo, while the submission is pending
- `POST /api/admin/submissions/{submission_id}/approve` — admin only: post it as the submitter's own run or entry, with `source` of `photo`
- `POST /api/admin/submissions/{submission_id}/reject` — admin only: turn it down (optional `note`, shown to the submitter)

Approving, rejecting or deleting a submission deletes its photo.

## Reports, blocks and bans

- `POST /api/leaderboard/reports` — flag a course, run, or acceleration entry (`target_type` of `course`/`run`/`acceleration`, `target_id`, `reason`)
- `GET` / `DELETE /api/leaderboard/reports[/{report_id}]` — admin only: list reports with their targets, or dismiss one
- `POST /api/leaderboard/blocks` — device only: stop seeing everything posted by whoever posted the target (`target_type`, `target_id`). Also files a "Poster blocked" report
- `GET /api/leaderboard/blocks` and `DELETE /api/leaderboard/blocks/{block_id}` — this device's blocks, or lift one
- `POST /api/leaderboard/bans` — admin only: ban whoever posted the target (`target_type`, `target_id`, optional `reason`). A ban stops every write and hides everything they posted
- `POST /api/admin/bans` — admin only: the same ban for someone from the users list (`kind`, `id`, optional `reason`)
- `GET /api/leaderboard/bans` and `DELETE /api/leaderboard/bans/{ban_id}` — admin only: list bans, or lift one. Lifting does not unhide what the ban hid

## Accounts

- `POST /api/account/apple` — sign this device in (`identity_token`, the `nonce` whose SHA-256 the app gave Apple, optional `authorization_code` and `name`)
- `GET` / `PATCH` / `DELETE /api/account` — whether this device is signed in, change the account's `name`, or delete the account and everything it posted
- `DELETE /api/account/session` — sign this device out
- `POST /api/account/apple/notifications` — Apple's server-to-server endpoint (`payload`, a token Apple signs); a revoked or deleted Apple ID is signed out on every device

## Admin

- `GET /api/admin/session` — who the caller is signed in as (`user`, or `null`)
- `POST /api/admin/session` — exchange HTTP Basic admin credentials for the dev console's 30-day `admin_session` cookie
- `DELETE /api/admin/session` — clear that cookie in this browser
- `GET /api/admin/users` — every account with its devices, and every device that has not signed in, with what each has posted, the boards it owns or has joined, and whether it is banned
- `PATCH /api/admin/users/{user_id}` and `PATCH /api/admin/devices/{device_id}` — set a `label`
- `POST /api/admin/devices/{device_id}/move` — file everything a signed-out device posted under an account (`user_id`)

## TrackAddict

- `POST /api/trackaddict/parse` — body is a raw TrackAddict CSV log (no multipart); returns its laps with times and distances. Lap 0 is the pre-start segment, not a run. A lap that starts from a standstill (a drag-mode run) also carries `acceleration`: 0-30 and 0-60 interpolated from the GPS speed trace, plus the 1/8 and 1/4 mile times and trap speeds from the log's 200 m and 400 m sector markers

## Pages

- `GET /` and `GET /app` — the public landing page
- `GET /dev` — the dev console
- `GET /support`, `GET /privacy` — the pages the app's Support and Privacy links open
