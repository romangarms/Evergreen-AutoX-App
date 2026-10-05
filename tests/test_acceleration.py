import app
import db
import pytest
from conftest import ADMIN, READ_KEY

ENTRY = {"vehicle": "Nissan Xterra", "driver": "Sam", "zero_to_60_seconds": 12.22}


def _post(client, headers=None, auth=None, **overrides):
    return client.post(
        "/api/acceleration", json={**ENTRY, **overrides}, headers=headers, auth=auth
    )


def _listed_ids(client, headers=None, auth=None) -> list[int]:
    listing = client.get("/api/acceleration", headers=headers, auth=auth)
    return [entry["id"] for entry in listing.json()]


def _identity_strings() -> set[str]:
    with db.session() as conn:
        tokens = {row["token"] for row in conn.execute("SELECT token FROM devices")}
        accounts = {
            app._account_owner_id(row["apple_sub"])
            for row in conn.execute("SELECT apple_sub FROM users")
        }
    return tokens | accounts


@pytest.mark.parametrize(
    "headers", [None, {"X-Leaderboard-Key": READ_KEY}], ids=["anonymous", "read key"]
)
def test_writes_need_a_device_or_admin(client, device, headers):
    entry = _post(client, device("owner")).json()
    assert _post(client, headers).status_code == 401
    url = f"/api/acceleration/{entry['id']}"
    assert client.patch(url, json={"hp": 300}, headers=headers).status_code == 401
    assert client.delete(url, headers=headers).status_code == 401
    assert _listed_ids(client, headers) == [entry["id"]]


def test_device_without_an_account_cannot_post(client, device):
    assert _post(client, device("guest", signed_in=False)).status_code == 403


def test_owner_can_post_edit_and_delete(client, device):
    owner = device("owner")
    created = _post(client, owner, source="trackaddict")
    assert created.status_code == 201
    entry = created.json()
    assert entry["is_owner"] and entry["has_owner"]
    assert entry["source"] == "trackaddict"

    url = f"/api/acceleration/{entry['id']}"
    patched = client.patch(url, json={"hp": 261}, headers=owner)
    assert patched.status_code == 200
    assert patched.json()["hp"] == 261
    assert patched.json()["zero_to_60_seconds"] == 12.22

    assert client.delete(url, headers=owner).status_code == 200
    assert _listed_ids(client) == []


def test_another_device_cannot_change_an_entry(client, device):
    entry = _post(client, device("owner")).json()
    other = device("other")
    url = f"/api/acceleration/{entry['id']}"
    assert client.patch(url, json={"hp": 1}, headers=other).status_code == 403
    assert client.delete(url, headers=other).status_code == 403
    assert client.get("/api/acceleration", headers=other).json()[0]["is_owner"] is False


def test_only_admin_can_hide(client, device):
    owner = device("owner")
    entry = _post(client, owner).json()
    url = f"/api/acceleration/{entry['id']}"
    for hidden in (True, False):
        denied = client.patch(url, json={"hidden": hidden}, headers=owner)
        assert denied.status_code == 403

    assert client.patch(url, json={"hidden": True}, auth=ADMIN).json()["hidden"]
    assert _listed_ids(client, owner) == []
    assert _listed_ids(client, auth=ADMIN) == [entry["id"]]
    assert client.patch(url, json={"hp": 1}, headers=owner).status_code == 404
    assert client.delete(url, headers=owner).status_code == 404


def test_entry_needs_a_time_unless_admin(client, device):
    no_times = {"zero_to_60_seconds": None}
    assert _post(client, device("owner"), **no_times).status_code == 400
    assert _post(client, auth=ADMIN, **no_times).status_code == 201


def test_blocked_words_are_rejected_for_devices(client, device):
    owner = device("owner")
    assert _post(client, owner, notes="what a shit launch").status_code == 400
    entry = _post(client, owner).json()
    url = f"/api/acceleration/{entry['id']}"
    assert client.patch(url, json={"driver": "shit"}, headers=owner).status_code == 400
    assert _post(client, auth=ADMIN, notes="what a shit launch").status_code == 201


def test_entry_cap_per_owner(client, device):
    owner = device("owner")
    for _ in range(app.MAX_ACCELERATION_PER_OWNER):
        assert _post(client, owner).status_code == 201
    assert _post(client, owner).status_code == 429
    assert _post(client, device("other")).status_code == 201


def test_ranked_by_zero_to_sixty_then_thirty_with_missing_last(client):
    for vehicle, sixty, thirty in (
        ("no sixty", None, 2.0),
        ("slow", 9.0, None),
        ("quick, slow launch", 5.0, 2.5),
        ("quick", 5.0, 2.0),
        ("quick, no thirty", 5.0, None),
    ):
        _post(
            client,
            auth=ADMIN,
            vehicle=vehicle,
            zero_to_60_seconds=sixty,
            zero_to_30_seconds=thirty,
        )
    order = [entry["vehicle"] for entry in client.get("/api/acceleration").json()]
    assert order == [
        "quick",
        "quick, slow launch",
        "quick, no thirty",
        "slow",
        "no sixty",
    ]


def test_board_shows_a_posters_best_run_per_vehicle(client, device):
    owner, other = device("owner"), device("other")
    slow = _post(client, owner, zero_to_60_seconds=13.0).json()
    best = _post(client, owner, vehicle="nissan xterra", zero_to_60_seconds=12.0).json()
    second_car = _post(client, owner, vehicle="Miata", zero_to_60_seconds=14.0).json()
    older = _post(client, owner, year=2005, zero_to_60_seconds=15.0).json()
    rival = _post(client, other, zero_to_60_seconds=12.5).json()
    unowned = [
        _post(client, auth=ADMIN, zero_to_60_seconds=sixty).json()
        for sixty in (20.0, 21.0)
    ]

    board = [best["id"], rival["id"], second_car["id"], older["id"]]
    board += [entry["id"] for entry in unowned]
    for viewer in (None, owner, other):
        assert _listed_ids(client, viewer) == board
    assert slow["id"] in _listed_ids(client, auth=ADMIN)

    url = f"/api/acceleration/{slow['id']}"
    assert client.patch(url, json={"hp": 261}, headers=owner).status_code == 200
    client.delete(f"/api/acceleration/{best['id']}", headers=owner)
    assert _listed_ids(client)[:2] == [rival["id"], slow["id"]]


def test_report(client, device):
    entry = _post(client, device("owner")).json()
    target = {"target_type": "acceleration", "target_id": entry["id"]}
    reporter = device("reporter", signed_in=False)
    filed = client.post(
        "/api/leaderboard/reports", json={**target, "reason": "fake"}, headers=reporter
    )
    assert filed.status_code == 201
    missing = client.post(
        "/api/leaderboard/reports",
        json={"target_type": "acceleration", "target_id": 999, "reason": "fake"},
        headers=reporter,
    )
    assert missing.status_code == 404

    (report,) = client.get("/api/leaderboard/reports", auth=ADMIN).json()
    assert report["target_type"] == "acceleration"
    assert report["target"] == {
        "id": entry["id"],
        "vehicle": "Nissan Xterra",
        "driver": "Sam",
        "hidden": 0,
        "has_owner": 1,
    }


def test_block_hides_the_poster_from_the_blocker_only(client, device):
    owner, blocker, bystander = device("owner"), device("blocker"), device("bystander")
    entry = _post(client, owner).json()
    unowned = _post(client, auth=ADMIN, vehicle="Sheet import").json()
    target = {"target_type": "acceleration", "target_id": entry["id"]}

    block = client.post("/api/leaderboard/blocks", json=target, headers=blocker)
    assert block.status_code == 201
    assert block.json()["label"] == "Sam"

    assert _listed_ids(client, blocker) == [unowned["id"]]
    for viewer in (bystander, owner, None):
        assert entry["id"] in _listed_ids(client, viewer)
    reasons = [
        r["reason"] for r in client.get("/api/leaderboard/reports", auth=ADMIN).json()
    ]
    assert reasons == ["Poster blocked"]

    own = client.post("/api/leaderboard/blocks", json=target, headers=owner)
    assert own.status_code == 400
    ownerless = client.post(
        "/api/leaderboard/blocks",
        json={"target_type": "acceleration", "target_id": unowned["id"]},
        headers=blocker,
    )
    assert ownerless.status_code == 400


def test_ban_hides_the_posters_entries_and_stops_writes(client, device):
    owner = device("owner")
    first = _post(client, owner).json()
    second = _post(client, owner, vehicle="Second car").json()
    other = _post(client, device("other")).json()

    ban = client.post(
        "/api/leaderboard/bans",
        json={"target_type": "acceleration", "target_id": first["id"]},
        auth=ADMIN,
    )
    assert ban.status_code == 201
    assert _listed_ids(client) == [other["id"]]
    assert set(_listed_ids(client, auth=ADMIN)) == {
        first["id"],
        second["id"],
        other["id"],
    }
    assert _post(client, owner).status_code == 403
    assert (
        client.delete(f"/api/acceleration/{second['id']}", headers=owner).status_code
        == 403
    )


def test_sign_in_moves_a_devices_entries_to_the_account(client, device):
    phone = device("phone", signed_in=False)
    token = phone["Authorization"].removeprefix("Bearer ")
    with db.session() as conn:
        conn.execute(
            "INSERT INTO acceleration_entries (vehicle, owner_id) VALUES ('Old', ?)",
            (token,),
        )
        app._adopt_device(conn, token, app._account_owner_id("phone"))
    device("phone")
    (entry,) = client.get("/api/acceleration", headers=phone).json()
    assert entry["is_owner"]


def test_deleting_an_account_deletes_its_entries(client, device):
    owner = device("owner")
    _post(client, owner)
    kept = _post(client, device("other")).json()
    assert client.delete("/api/account", headers=owner).status_code == 200
    assert _listed_ids(client) == [kept["id"]]


def test_users_panel_counts_entries(client, device):
    owner = device("owner")
    _post(client, owner)
    _post(client, owner, vehicle="Second car")
    (person,) = client.get("/api/admin/users", auth=ADMIN).json()
    assert person["acceleration"] == 2
    assert person["names"] == ["Sam"]


def test_no_response_carries_an_owner(client, device):
    owner, other = device("owner"), device("other")
    created = _post(client, owner)
    url = f"/api/acceleration/{created.json()['id']}"
    target = {"target_type": "acceleration", "target_id": created.json()["id"]}
    responses = [
        created,
        client.patch(url, json={"hp": 261}, headers=owner),
        client.get("/api/acceleration"),
        client.get("/api/acceleration", headers=owner),
        client.get("/api/acceleration", auth=ADMIN),
        client.post(
            "/api/leaderboard/reports", json={**target, "reason": "x"}, headers=other
        ),
        client.post("/api/leaderboard/blocks", json=target, headers=other),
        client.get("/api/leaderboard/blocks", headers=other),
        client.get("/api/leaderboard/reports", auth=ADMIN),
        client.post("/api/leaderboard/bans", json=target, auth=ADMIN),
        client.get("/api/leaderboard/bans", auth=ADMIN),
        client.get("/api/admin/users", auth=ADMIN),
    ]
    secrets = _identity_strings()
    assert len(secrets) == 4
    for response in responses:
        assert response.status_code in (200, 201)
        assert "owner_id" not in response.text
        assert not any(secret in response.text for secret in secrets)
