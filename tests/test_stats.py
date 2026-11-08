import app
import appstore
import cache
import db

TOKEN = "test-device-stats-000000"


def call_as_device(client, token: str = TOKEN):
    """Any endpoint that reads the token records the device; the app's launch
    path (AppModel.start -> loadAccount) hits this one."""
    return client.get("/api/account", headers={"Authorization": f"Bearer {token}"})


def go_idle_and_prune():
    with db.session() as conn:
        conn.execute(
            "UPDATE devices SET last_seen = datetime('now', ?)",
            (f"-{app.IDLE_DEVICE_DAYS + 1} days",),
        )
        app._prune_devices(conn)


def test_stats_are_public_and_count_devices(client, device):
    assert client.get("/api/stats").json() == {
        "users": 0,
        "devices": 0,
        "installs": 0,
        "android": 0,
    }

    device("alice")
    device("bob", signed_in=False)

    assert client.get("/api/stats").json()["devices"] == 2


def test_a_device_added_behind_the_server_is_remembered_by_the_next_prune(
    client, device
):
    # _people backfills device rows for tokens it finds on old posts, so a row
    # can appear without _record_device ever seeing it.
    device("alice", signed_in=False)
    go_idle_and_prune()

    assert client.get("/api/stats").json() == {
        "users": 0,
        "devices": 0,
        "installs": 1,
        "android": 0,
    }


def test_stats_carry_nothing_but_counts(client):
    call_as_device(client)

    assert set(client.get("/api/stats").json()) == {
        "users",
        "devices",
        "installs",
        "android",
    }


def test_installs_survive_pruning(client):
    call_as_device(client)
    assert client.get("/api/stats").json() == {
        "users": 1,
        "devices": 1,
        "installs": 1,
        "android": 0,
    }

    go_idle_and_prune()

    # The live table forgets the phone; the lifetime count does not.
    assert client.get("/api/stats").json() == {
        "users": 0,
        "devices": 0,
        "installs": 1,
        "android": 0,
    }


def test_a_pruned_device_coming_back_is_not_counted_twice(client):
    call_as_device(client)
    go_idle_and_prune()

    call_as_device(client)

    assert client.get("/api/stats").json() == {
        "users": 1,
        "devices": 1,
        "installs": 1,
        "android": 0,
    }


def test_installs_count_distinct_devices(client):
    call_as_device(client, "test-device-stats-aaaaaa")
    call_as_device(client, "test-device-stats-aaaaaa")
    call_as_device(client, "test-device-stats-bbbbbb")

    assert client.get("/api/stats").json()["installs"] == 2


def test_known_devices_holds_a_digest_not_the_token(client):
    call_as_device(client)

    with db.session() as conn:
        stored = [
            row["token_hash"] for row in conn.execute("SELECT * FROM known_devices")
        ]

    assert stored == [db.device_fingerprint(TOKEN)]
    assert TOKEN not in stored


def test_users_is_the_testflight_count_when_app_store_connect_answers(
    client, monkeypatch
):
    call_as_device(client)
    monkeypatch.setattr(appstore, "configured", lambda: True)
    monkeypatch.setattr(appstore, "tester_count", lambda: 23)
    cache._entries.clear()

    assert client.get("/api/stats").json() == {
        "users": 23,
        "devices": 1,
        "installs": 1,
        "android": 0,
    }


def test_users_falls_back_to_devices_when_app_store_connect_fails(client, monkeypatch):
    def down():
        raise OSError("unreachable")

    call_as_device(client)
    monkeypatch.setattr(appstore, "configured", lambda: True)
    monkeypatch.setattr(appstore, "tester_count", down)
    cache._entries.clear()

    assert client.get("/api/stats").json()["users"] == 1


ANDROID = {"User-Agent": "okhttp/4.12.0"}
IOS = {"User-Agent": "AutoX%20Live/42 CFNetwork/3826.400.120 Darwin/25.1.0"}


def call_with(client, token, headers):
    return client.get(
        "/api/account", headers={"Authorization": f"Bearer {token}", **headers}
    )


def test_android_phones_are_counted_from_their_user_agent(client):
    call_with(client, "test-device-stats-android1", ANDROID)
    call_with(client, "test-device-stats-android2", ANDROID)
    call_with(client, "test-device-stats-iphone01", IOS)
    call_with(client, "test-device-stats-unknown1", {"User-Agent": "curl/8"})

    assert client.get("/api/stats").json()["android"] == 2


def test_a_request_without_a_platform_keeps_the_one_recorded(client):
    call_with(client, "test-device-stats-android1", ANDROID)
    call_with(client, "test-device-stats-android1", {"User-Agent": "curl/8"})

    assert client.get("/api/stats").json()["android"] == 1


def test_a_quiet_android_phone_drops_out_of_the_count(client):
    call_with(client, "test-device-stats-android1", ANDROID)
    with db.session() as conn:
        conn.execute(
            "UPDATE devices SET last_seen = datetime('now', ?)",
            (f"-{app.ANDROID_ACTIVE_DAYS + 1} days",),
        )

    assert client.get("/api/stats").json()["android"] == 0


def test_users_adds_android_phones_to_the_testflight_count(client, monkeypatch):
    call_with(client, "test-device-stats-android1", ANDROID)
    call_with(client, "test-device-stats-iphone01", IOS)
    monkeypatch.setattr(appstore, "configured", lambda: True)
    monkeypatch.setattr(appstore, "tester_count", lambda: 23)
    cache._entries.clear()

    assert client.get("/api/stats").json()["users"] == 24
