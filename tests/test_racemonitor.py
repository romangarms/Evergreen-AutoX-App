from datetime import datetime
from types import SimpleNamespace

import app
import cache
import db
import pytest
import racemonitor
import rmonitor
from conftest import ADMIN
from test_rmonitor import FEED

LIVE_PAGE = """
<div class="raceItem clickableRace" onclick="raceClicked(171162, true);">
    <span class="largeRaceText"><a href="/Live/Race/171162">AutoX - Powered by 425 Motorsports</a></span><br />
    <span class="smallRaceText">
        @ <a href="/Live/Race/171162">Evergreen Speedway</a><br />
    </span>
    <script>addCurrentDate(171162, 1792944000, 1792982700);</script>
</div>
<div class="raceItem clickableRace" onclick="raceClicked(171290, true);">
    <span class="largeRaceText"><a href="/Live/Race/171290">VDCA&#39;s Historics</a></span><br />
    <span class="smallRaceText">
        @ <a href="/Live/Race/171290">Buttonwillow Raceway</a><br />
    </span>
    <script>addCurrentDate(171290, 1794065400, 1794189600);</script>
</div>
"""

RACE_PAGE = """
<script>function addCurrentDate(startEpoch, endEpoch) {}
addCurrentDate(1792944000, 1792982700); </script>
<h2 style="margin-bottom: 4px;"> AutoX - Powered by 425 Motorsports </h2>
<div><span style="color: #2a2a2a;">@ Evergreen Speedway</span><br /></div>
"""

# How a crossing arrives live: $J before the $G that counts it.
LIVE_LAP = """\
$J,"R12","00:01:00.500","00:31:01.600"
$G,1,"R12",25,"00:31:01.600"
$H,1,"R12",25,"00:01:00.500"
"""

DAY = datetime(2026, 10, 25, 10, 0, tzinfo=racemonitor.TZ)


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    cache.clear()
    monkeypatch.setattr(racemonitor, "now_local", lambda: DAY)
    racemonitor._live.clear()
    yield
    racemonitor._live.clear()
    cache.clear()


def record(feed: str = FEED) -> racemonitor.Race:
    race = racemonitor.Race(171162, "AutoX - Powered by 425 Motorsports", "Evergreen")
    race.feed(feed)
    race.save()
    return race


def speedhive(monkeypatch, events: list):
    monkeypatch.setattr(
        app,
        "client",
        SimpleNamespace(get_events=lambda org_id, limit, offset: events),
    )


def test_live_page_lists_races_with_their_window():
    races = racemonitor.parse_live_page(LIVE_PAGE)
    assert races[0] == {
        "id": 171162,
        "name": "AutoX - Powered by 425 Motorsports",
        "track": "Evergreen Speedway",
        "starts_at": 1792944000,
        "ends_at": 1792982700,
    }
    assert races[1]["name"] == "VDCA's Historics"


def test_race_page_gives_name_track_and_window():
    race = racemonitor.parse_race_page(171162, RACE_PAGE)
    assert race["name"] == "AutoX - Powered by 425 Motorsports"
    assert race["track"] == "Evergreen Speedway"
    assert (race["starts_at"], race["ends_at"]) == (1792944000, 1792982700)


def test_discovery_keeps_only_matching_races(client, monkeypatch):
    monkeypatch.setattr(
        racemonitor.httpx,
        "get",
        lambda url, timeout: SimpleNamespace(
            text=LIVE_PAGE, raise_for_status=lambda: None
        ),
    )
    racemonitor.discover()
    with db.session() as conn:
        ids = [row["id"] for row in conn.execute("SELECT id FROM racemonitor_races")]
    assert ids == [171162]


def test_a_race_is_watched_only_around_its_schedule(client):
    row = {"starts_at": 1792944000, "ends_at": 1792982700, "created_at": ""}
    tz = racemonitor.TZ
    assert racemonitor.wanted(row, datetime(2026, 10, 25, 7, 30, tzinfo=tz))
    assert not racemonitor.wanted(row, datetime(2026, 10, 25, 6, 30, tzinfo=tz))
    assert racemonitor.wanted(row, datetime(2026, 10, 25, 21, 0, tzinfo=tz))
    assert not racemonitor.wanted(row, datetime(2026, 10, 26, 9, 0, tzinfo=tz))
    assert not racemonitor.wanted(None, DAY)


def test_live_crossing_pairs_last_lap_with_its_count():
    session = rmonitor.Session()
    session.feed(FEED)
    session.feed(LIVE_LAP)
    car = next(c for c in session.competitors.values() if c.number == "12")
    assert car.lap_times[24] == "00:01:02.052"
    assert car.lap_times[25] == "00:01:00.500"
    assert session.results()[0]["startNumber"] == "12"


def test_state_round_trips():
    session = rmonitor.Session()
    session.feed(FEED)
    restored = rmonitor.Session.from_state(session.to_state())
    assert restored.results() == session.results()
    assert restored.laps() == session.laps()


def test_lines_before_the_session_header_are_kept(client):
    race = record()
    race.rejoin()
    race.feed(LIVE_LAP)
    race.feed('$B,8789638,"AutoX - 10/25 Powered by 425 Motorsports"')
    race.save()
    (session,) = race.sessions.values()
    assert session.results()[0]["startNumber"] == "12"


def test_a_new_session_header_starts_a_new_session(client):
    race = record()
    race.feed('$I,"14:00:00.000","25 Oct 26"\n$B,8789700,"Fun runs"\n')
    race.feed('$A,"R7","7",1001,"Red","MR2","USA",1\n')
    race.save()
    names = [s.session_name for s in race.sessions.values()]
    assert names == ["AutoX - 10/25 Powered by 425 Motorsports", "Fun runs"]


def test_a_restart_carries_on_with_the_saved_laps(client):
    record()
    restarted = racemonitor.Race(171162, "AutoX", "Evergreen")
    restarted.feed('$B,8789638,"AutoX - 10/25 Powered by 425 Motorsports"\n')
    (session,) = restarted.sessions.values()
    laps = session.laps()[0]["laps"]
    assert [lap["lap"] for lap in laps] == [24, 25]


def test_recorded_events_join_the_speedhive_list(client, monkeypatch):
    record()
    speedhive(
        monkeypatch, [{"id": 3746381, "name": "AutoX", "startDate": "2026-10-10"}]
    )
    events = client.get(f"/api/orgs/{app.SPEEDHIVE_ORG_ID}/events?limit=200").json()
    assert [e["id"] for e in events] == [racemonitor.ID_OFFSET + 1, 3746381]
    live = events[0]
    assert live["name"] == "AutoX - Powered by 425 Motorsports"
    assert live["startDate"] == "2026-10-25"
    assert live["location"]["name"] == racemonitor.LOCATION


def test_speedhive_upload_replaces_the_live_copy(client, monkeypatch):
    record()
    speedhive(
        monkeypatch, [{"id": 3765573, "name": "AutoX", "startDate": "2026-10-25"}]
    )
    events = client.get(f"/api/orgs/{app.SPEEDHIVE_ORG_ID}/events").json()
    assert [e["id"] for e in events] == [3765573]


def test_other_orgs_get_no_live_events(client, monkeypatch):
    record()
    speedhive(monkeypatch, [])
    assert client.get("/api/orgs/1/events").json() == []


def test_sessions_results_and_laps_read_like_speedhive(client):
    record()
    event_id = racemonitor.ID_OFFSET + 1
    (session,) = client.get(f"/api/events/{event_id}/sessions").json()
    assert session["name"] == "AutoX - 10/25 Powered by 425 Motorsports"
    assert session["type"] == "qualify"
    assert session["startTime"] == "2026-10-25T10:00:00"
    results = client.get(f"/api/sessions/{session['id']}/results").json()
    assert results[0]["bestTime"] == "01:01.809"
    driver = client.get(f"/api/sessions/{session['id']}/drivers/1").json()
    assert driver["result"]["startNumber"] == "7"
    assert [lap["lapTime"] for lap in driver["laps"][0]["laps"]] == [
        "01:02.300",
        "01:01.809",
    ]


def test_live_race_answers_from_memory(client):
    race = record()
    racemonitor._live[race.race_id] = race
    race.feed(LIVE_LAP)
    session_id = racemonitor.ID_OFFSET + next(iter(race.sessions))
    results = client.get(f"/api/sessions/{session_id}/results").json()
    assert results[0]["startNumber"] == "12"


def test_unknown_live_ids_are_not_found(client):
    assert (
        client.get(f"/api/events/{racemonitor.ID_OFFSET + 9}/sessions").status_code
        == 404
    )
    assert (
        client.get(f"/api/sessions/{racemonitor.ID_OFFSET + 9}/results").status_code
        == 404
    )


def test_admin_adds_lists_and_removes_races(client, monkeypatch):
    monkeypatch.setattr(
        racemonitor,
        "fetch_race_info",
        lambda race_id: racemonitor.parse_race_page(race_id, RACE_PAGE),
    )
    assert (
        client.post(
            "/api/admin/racemonitor/races", json={"race_id": 171162}
        ).status_code
        == 401
    )
    added = client.post(
        "/api/admin/racemonitor/races", json={"race_id": 171162}, auth=ADMIN
    )
    assert added.status_code == 201
    status = client.get("/api/admin/racemonitor", auth=ADMIN).json()
    assert status["races"][0]["id"] == 171162
    assert status["races"][0]["manual"] is True
    assert status["races"][0]["watching"] is True
    assert (
        client.delete("/api/admin/racemonitor/races/171162", auth=ADMIN).status_code
        == 200
    )
    assert client.get("/api/admin/racemonitor", auth=ADMIN).json()["races"] == []


def test_admin_deletes_a_recorded_event(client):
    record()
    event_id = racemonitor.ID_OFFSET + 1
    assert (
        client.get("/api/admin/racemonitor", auth=ADMIN).json()["events"][0]["cars"]
        == 3
    )
    assert (
        client.delete(
            f"/api/admin/racemonitor/events/{event_id}", auth=ADMIN
        ).status_code
        == 200
    )
    assert client.get(f"/api/events/{event_id}/sessions").status_code == 404
