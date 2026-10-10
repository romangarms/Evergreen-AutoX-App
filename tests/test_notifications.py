import copy
from datetime import date

import db
import gglc
import notify
import push
import pytest

TODAY = date(2026, 10, 10)
GGLC_ID = notify.gglc_event_id(TODAY)
APNS = "ab" * 32


@pytest.fixture(autouse=True)
def frozen_today(monkeypatch):
    monkeypatch.setattr(gglc, "today", lambda: TODAY)


def setup(device, client, name="phone", **overrides) -> dict:
    headers = device(name, signed_in=False)
    body = {
        "apns_token": APNS,
        "environment": "sandbox",
        "notify_me": True,
        "notify_friends": True,
        "watches": [
            {
                "event_id": GGLC_ID,
                "event_date": "2026-10-10",
                "me": "12",
                "friends": ["7"],
            }
        ],
    } | overrides
    response = client.put("/api/push", json=body, headers=headers)
    assert response.status_code == 200, response.text
    return headers


def gglc_run(number, total, cones=0):
    return {"run": number, "total": total, "cones": cones, "dnf": False, "best": False}


def gglc_page(runs_by_car):
    return {
        "classes": [
            {
                "name": "STS",
                "drivers": [
                    {"name": name, "car": car, "carClass": "STS", "runs": runs}
                    for car, (name, runs) in runs_by_car.items()
                ],
            }
        ]
    }


class FakeUpstream:
    def __init__(self):
        self.gglc = gglc_page({})
        self.sessions_by_event = {}
        self.results_by_session = {}
        self.laps_by_session = {}
        self.event_list = []

    def as_upstream(self):
        return notify.Upstream(
            sessions=lambda event_id: self.sessions_by_event.get(event_id, []),
            results=lambda sid: self.results_by_session.get(sid, []),
            laps=lambda sid: self.laps_by_session.get(sid, []),
            gglc_event=lambda day: copy.deepcopy(self.gglc),
            events=lambda org_id: self.event_list,
        )


def titles(notices):
    return sorted(n.payload["aps"]["alert"]["title"] for n in notices)


def test_push_setup_needs_a_device_token(client):
    response = client.put(
        "/api/push",
        json={
            "apns_token": APNS,
            "environment": "sandbox",
            "notify_me": True,
            "notify_friends": False,
        },
    )
    assert response.status_code == 401


def test_push_setup_keeps_only_live_events_and_forgets_when_off(client, device):
    headers = setup(
        device,
        client,
        watches=[
            {"event_id": GGLC_ID, "event_date": "2026-10-10", "me": "12"},
            {"event_id": 99, "event_date": "2026-09-01", "me": "3"},
            {"event_id": 98, "event_date": "2026-10-09", "friends": []},
        ],
    )
    with db.session() as conn:
        watches = conn.execute("SELECT event_id FROM push_watches").fetchall()
        assert [w["event_id"] for w in watches] == [GGLC_ID]
        assert (
            conn.execute("SELECT COUNT(*) FROM push_registrations").fetchone()[0] == 1
        )

    response = client.put(
        "/api/push",
        json={
            "apns_token": APNS,
            "environment": "sandbox",
            "notify_me": False,
            "notify_friends": False,
        },
        headers=headers,
    )
    assert response.json() == {"enabled": False, "watching": 0}
    with db.session() as conn:
        assert (
            conn.execute("SELECT COUNT(*) FROM push_registrations").fetchone()[0] == 0
        )
        assert conn.execute("SELECT COUNT(*) FROM push_watches").fetchone()[0] == 0


def test_a_token_follows_the_newest_phone(client, device):
    setup(device, client, name="old")
    setup(device, client, name="new")
    with db.session() as conn:
        rows = conn.execute(
            """SELECT devices.token FROM push_registrations
               JOIN devices ON devices.id = push_registrations.device_id"""
        ).fetchall()
    assert [r["token"] for r in rows] == ["test-device-new".ljust(24, "0")]


def test_new_gglc_runs_notify_me_and_friends(client, device):
    setup(device, client)
    fake = FakeUpstream()
    fake.gglc = gglc_page(
        {
            "12": ("Roman G", [gglc_run(1, 50.0)]),
            "7": ("Alex K", [gglc_run(1, 49.5)]),
            "3": ("Someone Else", [gglc_run(1, 48.0)]),
        }
    )
    watcher = notify.Watcher(fake.as_upstream(), org_id=1)
    assert watcher.poll(TODAY) == []  # the first look only records what is there

    fake.gglc["classes"][0]["drivers"][0]["runs"].append(gglc_run(2, 48.5, cones=1))
    fake.gglc["classes"][0]["drivers"][1]["runs"].append(gglc_run(2, 51.0))
    fake.gglc["classes"][0]["drivers"][2]["runs"].append(gglc_run(2, 47.0))
    notices = watcher.poll(TODAY)
    assert titles(notices) == ["Alex K · Run 2: 51.000", "Run 2: 48.500 (+1 cone)"]
    mine = next(
        n for n in notices if n.payload["aps"]["alert"]["title"].startswith("Run")
    )
    assert mine.payload["aps"]["alert"]["body"] == "New best! P2 in STS, P2 overall."
    assert mine.payload["event_id"] == GGLC_ID
    assert mine.apns_token == APNS and mine.environment == "sandbox"
    friend = next(n for n in notices if n is not mine)
    assert friend.payload["aps"]["alert"]["body"] == (
        "Best 49.500. 1.00 behind you. P3 in STS, P3 overall."
    )
    assert watcher.poll(TODAY) == []


def test_friend_notifications_can_be_turned_off(client, device):
    setup(device, client, notify_friends=False)
    fake = FakeUpstream()
    fake.gglc = gglc_page({"12": ("Roman G", []), "7": ("Alex K", [])})
    watcher = notify.Watcher(fake.as_upstream(), org_id=1)
    watcher.poll(TODAY)
    for driver in fake.gglc["classes"][0]["drivers"]:
        driver["runs"].append(gglc_run(1, 50.0))
    assert titles(watcher.poll(TODAY)) == ["Run 1: 50.000"]


def test_people_are_followed_by_name_into_an_unopened_event(client, device):
    setup(device, client, watches=[], me_name="Roman G", friend_names=["alex  k"])
    fake = FakeUpstream()
    fake.gglc = gglc_page(
        {"44": ("roman g", []), "8": ("Alex K", []), "9": ("Pat", [])}
    )
    watcher = notify.Watcher(fake.as_upstream(), org_id=1)
    watcher.poll(TODAY)
    for driver in fake.gglc["classes"][0]["drivers"]:
        driver["runs"].append(gglc_run(1, 50.0))
    assert titles(watcher.poll(TODAY)) == ["Alex K · Run 1: 50.000", "Run 1: 50.000"]


def test_speedhive_laps_in_grid_are_not_runs(client, device):
    setup(
        device,
        client,
        watches=[{"event_id": 500, "event_date": "2026-10-10", "me": "12"}],
    )
    fake = FakeUpstream()
    fake.sessions_by_event[500] = [{"id": 900}]
    fake.results_by_session[900] = [
        {
            "position": 1,
            "name": "Roman G",
            "startNumber": "12",
            "resultClass": "SS",
            "positionInClass": 1,
        },
    ]
    laps = [{"lap": 1, "lapTime": "1:02.500"}]
    fake.laps_by_session[900] = [{"position": 1, "laps": laps}]
    watcher = notify.Watcher(fake.as_upstream(), org_id=1)
    watcher.poll(TODAY)

    laps.append({"lap": 2, "lapTime": "4:10.000"})  # waiting in grid
    assert watcher.poll(TODAY) == []
    laps.append({"lap": 3, "lapTime": "1:01.250"})
    notices = watcher.poll(TODAY)
    assert titles(notices) == ["Run 2: 1:01.250"]
    assert (
        notices[0].payload["aps"]["alert"]["body"] == "New best! P1 in SS, P1 overall."
    )


def test_dead_tokens_are_dropped(client, device, monkeypatch):
    setup(device, client)
    with db.session() as conn:
        device_id = conn.execute("SELECT device_id FROM push_registrations").fetchone()[
            0
        ]
    sent = []

    def fake_send(token, environment, payload):
        sent.append(payload)
        raise push.Gone("Unregistered")

    monkeypatch.setattr(push, "send", fake_send)
    notice = notify.Notice(device_id, APNS, "sandbox", {"aps": {}})
    notify.deliver([notice, notice])
    assert len(sent) == 1
    with db.session() as conn:
        assert (
            conn.execute("SELECT COUNT(*) FROM push_registrations").fetchone()[0] == 0
        )


def test_apns_request_and_dead_token(monkeypatch):
    import httpx
    import jwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    monkeypatch.setattr(push, "TEAM_ID", "TEAM123456")
    monkeypatch.setattr(push, "KEY_ID", "KEY1234567")
    monkeypatch.setattr(push, "PRIVATE_KEY", pem)
    monkeypatch.setattr(push, "_token", None)
    requests = []

    def handler(request):
        requests.append(request)
        if request.url.path.endswith("/dead"):
            return httpx.Response(410, json={"reason": "Unregistered"})
        return httpx.Response(200)

    monkeypatch.setattr(
        push, "_http", httpx.Client(transport=httpx.MockTransport(handler))
    )
    push.send("live", "production", {"aps": {"alert": "hi"}})
    with pytest.raises(push.Gone):
        push.send("dead", "sandbox", {"aps": {}})

    first = requests[0]
    assert str(first.url) == "https://api.push.apple.com/3/device/live"
    assert str(requests[1].url).startswith("https://api.sandbox.push.apple.com/")
    assert first.headers["apns-topic"] == "com.romangarms.Evergreen-AutoX-App-iOS"
    provider = first.headers["authorization"].removeprefix("bearer ")
    assert jwt.get_unverified_header(provider)["kid"] == "KEY1234567"
    claims = jwt.decode(provider, key.public_key(), algorithms=["ES256"])
    assert claims["iss"] == "TEAM123456"


def test_admin_sees_who_has_notifications_and_can_test_them(
    client, device, monkeypatch
):
    from conftest import ADMIN

    setup(device, client, notify_friends=False)
    users = client.get("/api/admin/users", auth=ADMIN).json()
    phone = next(u for u in users if u["kind"] == "device")
    assert phone["notifications"] == ["me"]
    assert APNS not in str(users)

    sent = []
    monkeypatch.setattr(push, "configured", lambda: True)
    monkeypatch.setattr(push, "_post", lambda *args: sent.append(args) or (200, ""))
    response = client.post(f"/api/admin/devices/{phone['id']}/test-push", auth=ADMIN)
    assert response.json() == {"result": "Sent"}
    assert sent[0][:2] == (APNS, "sandbox")

    monkeypatch.setattr(push, "_post", lambda *args: (410, "Unregistered"))
    response = client.post(f"/api/admin/devices/{phone['id']}/test-push", auth=ADMIN)
    assert "removed" in response.json()["result"]
    response = client.post(f"/api/admin/devices/{phone['id']}/test-push", auth=ADMIN)
    assert response.status_code == 404
    assert client.post(f"/api/admin/devices/{phone['id']}/test-push").status_code == 401
