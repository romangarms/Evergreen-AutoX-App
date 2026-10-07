import hashlib
import json
import time
from types import SimpleNamespace

import app as server
import apple
import jwt
import pytest
from conftest import ADMIN, bearer
from cryptography.hazmat.primitives.asymmetric import rsa

NONCE = "a-nonce-made-up-by-the-app"

_apple_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def apple_jwt(key=_apple_key, **claims) -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": apple.ISSUER, "aud": apple.CLIENT_ID, "iat": now, "exp": now + 600}
        | claims,
        key,
        algorithm="RS256",
    )


def identity_token(sub: str, nonce: str = NONCE, **claims) -> str:
    return apple_jwt(
        sub=sub, nonce=hashlib.sha256(nonce.encode()).hexdigest(), **claims
    )


def device_token(name: str) -> str:
    return f"device-token-{name}".ljust(32, "0")


# A local key stands in for Apple's, so tokens signed above verify.
@pytest.fixture(autouse=True)
def local_apple_key(monkeypatch):
    monkeypatch.setattr(server, "_last_prune", time.monotonic())
    monkeypatch.setattr(
        apple,
        "_keys",
        SimpleNamespace(
            get_signing_key_from_jwt=lambda token: SimpleNamespace(
                key=_apple_key.public_key()
            )
        ),
    )


@pytest.fixture
def sign_in(client):
    def _sign_in(device: str, sub: str, name: str | None = "Test User") -> dict:
        headers = bearer(device_token(device))
        response = client.post(
            "/api/account/apple",
            json={"identity_token": identity_token(sub), "nonce": NONCE, "name": name},
            headers=headers,
        )
        assert response.status_code == 200, response.text
        return headers

    return _sign_in


def admin_people(client) -> list[dict]:
    response = client.get("/api/admin/users", auth=ADMIN)
    assert response.status_code == 200, response.text
    return response.json()


def person(client, kind: str, name: str | None = None) -> dict:
    return next(
        p
        for p in admin_people(client)
        if p["kind"] == kind and (name is None or p["name"] == name)
    )


def make_board(client, headers, name="Lot A", **fields) -> dict:
    response = client.post(
        "/api/leaderboard/courses", json={"name": name, **fields}, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()


def post_run(client, headers, course_id: int, driver="Sam"):
    return client.post(
        f"/api/leaderboard/courses/{course_id}/runs",
        json={"driver": driver, "time": 61.5},
        headers=headers,
    )


def test_posting_needs_an_account(client, sign_in):
    plain = bearer(device_token("plain"))
    assert (
        client.post(
            "/api/leaderboard/courses", json={"name": "Lot A"}, headers=plain
        ).status_code
        == 403
    )
    board = make_board(client, sign_in("phone", "sub-1"))
    assert post_run(client, plain, board["id"]).status_code == 403


@pytest.mark.parametrize(
    "body",
    [
        {"identity_token": identity_token("sub-1"), "nonce": "some-other-nonce-value"},
        {"identity_token": identity_token("sub-1")},
        {"identity_token": identity_token("sub-1", aud="another.app"), "nonce": NONCE},
        {"identity_token": identity_token("sub-1", exp=1), "nonce": NONCE},
        {"identity_token": apple_jwt(sub="sub-1"), "nonce": NONCE},
        {
            "identity_token": identity_token(
                "sub-1", key=rsa.generate_private_key(65537, 2048)
            ),
            "nonce": NONCE,
        },
    ],
    ids=["wrong nonce", "no nonce", "audience", "expired", "no nonce claim", "key"],
)
def test_bad_sign_in_is_refused(client, body):
    response = client.post(
        "/api/account/apple", json=body, headers=bearer(device_token("phone"))
    )
    assert response.status_code in (401, 422)
    account = client.get("/api/account", headers=bearer(device_token("phone")))
    assert account.json()["signed_in"] is False


def test_account_follows_the_person_across_devices(client, sign_in):
    first = sign_in("first", "sub-1", "Sam Driver")
    board = make_board(client, first)
    run = post_run(client, first, board["id"]).json()

    second = sign_in("second", "sub-1", "Name From Apple")
    assert client.get("/api/account", headers=second).json() == {
        "signed_in": True,
        "name": "Sam Driver",
    }
    assert (
        client.patch(
            f"/api/leaderboard/runs/{run['id']}", json={"hp": 200}, headers=second
        ).status_code
        == 200
    )

    stranger = sign_in("stranger", "sub-2")
    assert (
        client.patch(
            f"/api/leaderboard/courses/{board['id']}",
            json={"description": "mine now"},
            headers=stranger,
        ).status_code
        == 403
    )

    assert client.delete("/api/account/session", headers=first).status_code == 200
    detail = client.get(f"/api/leaderboard/courses/{board['id']}", headers=first)
    assert detail.json()["course"]["is_owner"] is False


def test_sign_in_adopts_what_the_device_did_before(client, sign_in):
    owner = sign_in("owner", "sub-1")
    board = make_board(client, owner, unlisted=True)
    phone = bearer(device_token("phone"))
    joined = client.post(
        "/api/leaderboard/join", json={"code": board["join_code"]}, headers=phone
    )
    assert joined.status_code == 200

    sign_in("phone", "sub-2")
    assert (
        client.get(f"/api/leaderboard/courses/{board['id']}", headers=phone).status_code
        == 200
    )
    other_phone = sign_in("tablet", "sub-2")
    assert (
        client.get(
            f"/api/leaderboard/courses/{board['id']}", headers=other_phone
        ).status_code
        == 200
    )


def test_account_name_can_be_changed(client, sign_in):
    headers = sign_in("phone", "sub-1")
    response = client.patch(
        "/api/account", json={"name": "  Sam   D "}, headers=headers
    )
    assert response.json() == {"signed_in": True, "name": "Sam D"}
    assert (
        client.patch(
            "/api/account", json={"name": "Sam"}, headers=bearer(device_token("x"))
        ).status_code
        == 401
    )


def test_deleting_the_account_removes_its_posts(client, sign_in):
    headers = sign_in("phone", "sub-1")
    board = make_board(client, headers)
    assert client.delete("/api/account", headers=headers).status_code == 200
    assert client.get(f"/api/leaderboard/courses/{board['id']}").status_code == 404
    assert client.get("/api/account", headers=headers).json()["signed_in"] is False


def test_apple_revocation_signs_every_device_out(client, sign_in):
    first = sign_in("first", "sub-1")
    second = sign_in("second", "sub-1")
    board = make_board(client, first)

    forged = apple_jwt(
        key=rsa.generate_private_key(65537, 2048),
        events=json.dumps({"type": "consent-revoked", "sub": "sub-1"}),
    )
    refused = client.post("/api/account/apple/notifications", json={"payload": forged})
    assert refused.status_code == 401
    assert client.get("/api/account", headers=first).json()["signed_in"] is True

    payload = apple_jwt(events=json.dumps({"type": "consent-revoked", "sub": "sub-1"}))
    sent = client.post("/api/account/apple/notifications", json={"payload": payload})
    assert sent.status_code == 200
    for headers in (first, second):
        assert client.get("/api/account", headers=headers).json()["signed_in"] is False

    again = sign_in("first", "sub-1")
    detail = client.get(f"/api/leaderboard/courses/{board['id']}", headers=again)
    assert detail.json()["course"]["is_owner"] is True


def test_users_list_groups_devices_under_accounts(client, sign_in):
    first = sign_in("first", "sub-1", "Sam Driver")
    sign_in("second", "sub-1")
    board = make_board(client, first, created_by="Sammy")
    post_run(client, first, board["id"], driver="Sammy")
    client.get("/api/leaderboard/courses", headers=bearer(device_token("lurker")))

    people = admin_people(client)
    account = person(client, "user")
    assert len(account["devices"]) == 2
    assert (account["courses"], account["runs"]) == (1, 1)
    assert account["names"] == ["Sammy"]
    assert [p["kind"] for p in people].count("device") == 1

    client.delete("/api/account/session", headers=first)
    client.delete("/api/account/session", headers=bearer(device_token("second")))
    account = person(client, "user")
    assert account["devices"] == []
    assert account["courses"] == 1

    text = client.get("/api/admin/users", auth=ADMIN).text
    assert "sub-1" not in text
    assert "device-token" not in text


def test_users_list_is_admin_only(client, sign_in):
    assert client.get("/api/admin/users").status_code == 401
    assert (
        client.get("/api/admin/users", headers=sign_in("phone", "sub-1")).status_code
        == 401
    )


def test_labels_for_accounts_and_devices(client, sign_in):
    sign_in("phone", "sub-1")
    account = person(client, "user")
    device = account["devices"][0]
    client.patch(
        f"/api/admin/users/{account['id']}", json={"label": "Sam from GGLC"}, auth=ADMIN
    )
    client.patch(
        f"/api/admin/devices/{device['id']}", json={"label": "iPhone"}, auth=ADMIN
    )
    account = person(client, "user")
    assert account["label"] == "Sam from GGLC"
    assert account["devices"][0]["label"] == "iPhone"
    assert (
        client.patch(
            "/api/admin/users/999", json={"label": "x"}, auth=ADMIN
        ).status_code
        == 404
    )


def test_admin_adds_and_removes_board_members(client, sign_in):
    owner = sign_in("owner", "sub-1")
    board = make_board(client, owner, unlisted=True)
    members_url = f"/api/leaderboard/courses/{board['id']}/members"
    board_url = f"/api/leaderboard/courses/{board['id']}"

    member = sign_in("member", "sub-2", "Mia Member")
    lurker = bearer(device_token("lurker"))
    client.get("/api/leaderboard/courses", headers=lurker)
    assert client.get(board_url, headers=member).status_code == 404
    assert client.get(members_url, headers=owner).status_code == 401

    mia = person(client, "user", "Mia Member")
    added = client.post(members_url, json={"kind": "user", "id": mia["id"]}, auth=ADMIN)
    assert [m["name"] for m in added.json()] == ["Mia Member"]
    seen = client.get(board_url, headers=member).json()["course"]
    assert seen["is_member"] is True
    assert seen["join_code"] == board["join_code"]
    assert post_run(client, member, board["id"]).status_code == 200
    assert person(client, "user", "Mia Member")["joined_course_ids"] == [board["id"]]
    owner_row = next(
        p
        for p in client.get("/api/admin/users", auth=ADMIN).json()
        if p["owned_course_ids"]
    )
    assert owner_row["owned_course_ids"] == [board["id"]]
    assert owner_row["joined_course_ids"] == [board["id"]]
    assert owner_row["joined"] == 1

    bare = person(client, "device")
    added = client.post(
        members_url, json={"kind": "device", "id": bare["id"]}, auth=ADMIN
    )
    assert len(added.json()) == 2
    assert client.get(board_url, headers=lurker).status_code == 200

    listing = client.get(members_url, auth=ADMIN).text
    assert "sub-2" not in listing and "device-token" not in listing

    left = client.delete(f"{members_url}/user/{mia['id']}", auth=ADMIN)
    assert [m["kind"] for m in left.json()] == ["device"]
    assert client.get(board_url, headers=member).status_code == 404
    assert (
        client.post(members_url, json={"kind": "user", "id": 999}, auth=ADMIN)
    ).status_code == 404


def test_member_added_by_device_keeps_access_after_signing_in(client, sign_in):
    board = make_board(client, sign_in("owner", "sub-1"), unlisted=True)
    phone = bearer(device_token("phone"))
    client.get("/api/leaderboard/courses", headers=phone)
    bare = person(client, "device")
    client.post(
        f"/api/leaderboard/courses/{board['id']}/members",
        json={"kind": "device", "id": bare["id"]},
        auth=ADMIN,
    )
    sign_in("phone", "sub-2")
    assert (
        client.get(f"/api/leaderboard/courses/{board['id']}", headers=phone).status_code
        == 200
    )


def test_admin_sets_owner_from_a_person(client, sign_in):
    headers = sign_in("phone", "sub-1", "Sam Driver")
    created = client.post(
        "/api/leaderboard/courses", json={"name": "Lot B"}, auth=ADMIN
    )
    board_id = created.json()["id"]
    sam = person(client, "user")
    client.put(
        f"/api/leaderboard/courses/{board_id}/owner",
        json={"person": {"kind": "user", "id": sam["id"]}},
        auth=ADMIN,
    )
    detail = client.get(f"/api/leaderboard/courses/{board_id}", headers=headers)
    assert detail.json()["course"]["is_owner"] is True
    client.put(f"/api/leaderboard/courses/{board_id}/owner", json={}, auth=ADMIN)
    detail = client.get(f"/api/leaderboard/courses/{board_id}", headers=headers)
    assert detail.json()["course"]["has_owner"] is False


def test_admin_bans_and_unbans_from_the_users_list(client, sign_in):
    headers = sign_in("phone", "sub-1", "Sam Driver")
    board = make_board(client, headers)
    sam = person(client, "user")
    banned = client.post(
        "/api/admin/bans",
        json={"kind": "user", "id": sam["id"], "reason": "spam"},
        auth=ADMIN,
    )
    assert banned.status_code == 201
    assert banned.json()["label"] == "Sam Driver"
    assert post_run(client, headers, board["id"]).status_code == 403
    assert client.get(f"/api/leaderboard/courses/{board['id']}").status_code == 404
    assert post_run(client, sign_in("tablet", "sub-1"), board["id"]).status_code == 403

    sam = person(client, "user")
    assert sam["banned"] is True
    client.delete(f"/api/leaderboard/bans/{sam['ban_id']}", auth=ADMIN)
    assert person(client, "user")["banned"] is False
    assert (
        client.patch("/api/account", json={"name": "Sam"}, headers=headers).status_code
        == 200
    )


def test_moving_a_lost_phones_posts_to_an_account(client, sign_in, monkeypatch):
    old = sign_in("old", "sub-old")
    board = make_board(client, old)
    run = post_run(client, old, board["id"]).json()
    with server.db.session() as conn:
        token = device_token("old")
        conn.execute("UPDATE devices SET user_id = NULL WHERE token = ?", (token,))
        conn.execute("DELETE FROM users")
        for table in ("courses", "runs"):
            conn.execute(f"UPDATE {table} SET owner_id = ?", (token,))

    new = sign_in("new", "sub-new", "Sam Driver")
    run_url = f"/api/leaderboard/runs/{run['id']}"
    assert client.patch(run_url, json={"hp": 150}, headers=new).status_code == 403

    lost = person(client, "device")
    assert (lost["courses"], lost["runs"]) == (1, 1)
    sam = person(client, "user")
    moved = client.post(
        f"/api/admin/devices/{lost['id']}/move", json={"user_id": sam["id"]}, auth=ADMIN
    )
    assert moved.status_code == 200
    assert client.patch(run_url, json={"hp": 150}, headers=new).status_code == 200
    assert person(client, "user")["courses"] == 1

    signed_in_device = person(client, "user")["devices"][0]
    assert (
        client.post(
            f"/api/admin/devices/{signed_in_device['id']}/move",
            json={"user_id": sam["id"]},
            auth=ADMIN,
        ).status_code
        == 400
    )


def test_idle_devices_are_pruned(client, sign_in, monkeypatch):
    poster = sign_in("poster", "sub-1")
    make_board(client, poster)
    client.delete("/api/account/session", headers=poster)
    reporter = bearer(device_token("joiner"))
    client.get("/api/leaderboard/courses", headers=reporter)
    for name in ("idle-1", "idle-2", "idle-3"):
        client.get("/api/leaderboard/courses", headers=bearer(device_token(name)))
    labelled = next(p for p in admin_people(client) if p["kind"] == "device")
    client.patch(
        f"/api/admin/devices/{labelled['id']}", json={"label": "keep"}, auth=ADMIN
    )

    def tokens() -> set[str]:
        with server.db.session() as conn:
            return {row["token"] for row in conn.execute("SELECT token FROM devices")}

    before = tokens()
    monkeypatch.setattr(server, "MAX_IDLE_DEVICES", 1)
    with server.db.session() as conn:
        server._prune_devices(conn)
    assert len(before - tokens()) == 3

    with server.db.session() as conn:
        conn.execute("UPDATE devices SET last_seen = datetime('now', '-91 days')")
        server._prune_devices(conn)
    with server.db.session() as conn:
        left = conn.execute("SELECT label, user_id FROM devices").fetchall()
    assert [row["label"] for row in left] == ["keep"]


def test_sign_in_needs_a_username_once(client, sign_in):
    headers = bearer(device_token("phone"))

    def attempt(name):
        return client.post(
            "/api/account/apple",
            json={
                "identity_token": identity_token("sub-1"),
                "nonce": NONCE,
                "name": name,
            },
            headers=headers,
        )

    for missing in (None, "   ", "shit"):
        assert attempt(missing).status_code == 428
        assert client.get("/api/account", headers=headers).json()["signed_in"] is False
    assert admin_people(client)[0]["kind"] == "device"

    assert attempt("sam").json() == {"signed_in": True, "name": "sam"}
    client.delete("/api/account/session", headers=headers)
    assert attempt(None).json() == {"signed_in": True, "name": "sam"}


def test_account_without_a_username_cannot_post(client, sign_in):
    headers = sign_in("phone", "sub-1")
    with server.db.session() as conn:
        conn.execute("UPDATE users SET name = NULL")
    refused = client.post(
        "/api/leaderboard/courses", json={"name": "Lot A"}, headers=headers
    )
    assert refused.status_code == 403
    assert "username" in refused.json()["detail"]
    client.patch("/api/account", json={"name": "sam"}, headers=headers)
    assert make_board(client, headers)["name"] == "Lot A"
