import app as server
import db
import pytest
from conftest import ADMIN, READ_KEY

KEY = {server.READ_KEY_HEADER: READ_KEY}


def make_board(client, headers, name="Lot Day", unlisted=False):
    r = client.post(
        "/api/leaderboard/courses",
        json={"name": name, "unlisted": unlisted},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()


def post_run(client, headers, course_id, driver="Driver"):
    r = client.post(
        f"/api/leaderboard/courses/{course_id}/runs",
        json={"driver": driver, "time": 61.5},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()


def listed_ids(client, headers=None):
    return {
        c["id"] for c in client.get("/api/leaderboard/courses", headers=headers).json()
    }


def sign_in(token_headers, sub):
    token = token_headers["Authorization"].removeprefix("Bearer ")
    with db.session() as conn:
        conn.execute("INSERT OR IGNORE INTO users (apple_sub) VALUES (?)", (sub,))
        conn.execute(
            "UPDATE devices SET user_id = (SELECT id FROM users WHERE apple_sub = ?) WHERE token = ?",
            (sub, token),
        )
        server._adopt_device(conn, token, server._account_owner_id(sub))


def test_unlisted_board_does_not_exist_for_outsiders(client, device):
    owner, outsider, bare = (
        device("owner"),
        device("outsider"),
        device("bare", signed_in=False),
    )
    board = make_board(client, owner, unlisted=True)
    assert len(board["join_code"]) == server.JOIN_CODE_LENGTH

    for headers in (outsider, bare, None):
        assert (
            client.get(
                f"/api/leaderboard/courses/{board['id']}", headers=headers
            ).status_code
            == 404
        )
        assert board["id"] not in listed_ids(client, headers)
    target = {"target_type": "course", "target_id": board["id"]}
    writes = [
        (f"/api/leaderboard/courses/{board['id']}/runs", {"driver": "X", "time": 60}),
        ("/api/leaderboard/reports", target | {"reason": "x"}),
        ("/api/leaderboard/blocks", target),
    ]
    for path, body in writes:
        assert client.post(path, json=body, headers=outsider).status_code == 404


def test_read_key_reads_unlisted_boards_and_nothing_else(client, device):
    board = make_board(client, device("owner"), unlisted=True)

    r = client.get(f"/api/leaderboard/courses/{board['id']}", headers=KEY)
    assert r.status_code == 200
    assert r.json()["course"]["join_code"] is None
    assert board["id"] in listed_ids(client, KEY)
    assert (
        client.get(
            "/api/leaderboard/courses", headers={server.READ_KEY_HEADER: "wrong"}
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/api/leaderboard/join", json={"code": board["join_code"]}, headers=KEY
        ).status_code
        == 401
    )
    assert client.get("/api/leaderboard/reports", headers=KEY).status_code == 401


def test_join_and_leave(client, device):
    owner, member = device("owner"), device("member")
    board = make_board(client, owner, unlisted=True)
    code = board["join_code"]

    assert (
        client.post(
            "/api/leaderboard/join", json={"code": "WRONGCOD"}, headers=member
        ).status_code
        == 404
    )
    r = client.post(
        "/api/leaderboard/join",
        json={"code": f"{code[:4].lower()}-{code[4:]}"},
        headers=member,
    )
    assert r.status_code == 200
    assert r.json()["is_member"] and r.json()["join_code"] == code
    assert board["id"] in listed_ids(client, member)
    run = post_run(client, member, board["id"])
    assert (
        client.patch(
            f"/api/leaderboard/courses/{board['id']}",
            json={"name": "Mine"},
            headers=member,
        ).status_code
        == 403
    )

    assert (
        client.delete(
            f"/api/leaderboard/courses/{board['id']}/membership", headers=member
        ).status_code
        == 200
    )
    assert (
        client.get(
            f"/api/leaderboard/courses/{board['id']}", headers=member
        ).status_code
        == 404
    )
    assert (
        client.patch(
            f"/api/leaderboard/runs/{run['id']}", json={"notes": "x"}, headers=member
        ).status_code
        == 404
    )
    assert (
        client.delete(
            f"/api/leaderboard/courses/{board['id']}/membership", headers=member
        ).status_code
        == 404
    )


def test_join_code_only_works_while_unlisted(client, device):
    owner, other = device("owner"), device("other")
    board = make_board(client, owner, unlisted=True)
    code = board["join_code"]

    client.patch(
        f"/api/leaderboard/courses/{board['id']}",
        json={"unlisted": False},
        headers=owner,
    )
    assert (
        client.post(
            "/api/leaderboard/join", json={"code": code}, headers=other
        ).status_code
        == 404
    )
    r = client.patch(
        f"/api/leaderboard/courses/{board['id']}",
        json={"unlisted": True},
        headers=owner,
    )
    assert r.json()["join_code"] == code


def test_block_hides_the_posters_boards_and_runs(client, device):
    owner, poster, blocker = device("owner"), device("poster"), device("blocker")
    shared = make_board(client, owner, "Shared")
    theirs = make_board(client, poster, "Theirs")
    post_run(client, poster, shared["id"], "Poster")

    r = client.post(
        "/api/leaderboard/blocks",
        json={"target_type": "course", "target_id": theirs["id"]},
        headers=blocker,
    )
    assert r.status_code == 201
    assert set(r.json()) == {"id", "label", "created_at"}
    assert theirs["id"] not in listed_ids(client, blocker)
    assert theirs["id"] in listed_ids(client, owner)
    drivers = lambda headers: [
        run["driver"]
        for run in client.get(
            f"/api/leaderboard/courses/{shared['id']}", headers=headers
        ).json()["runs"]
    ]
    assert "Poster" not in drivers(blocker)
    assert "Poster" in drivers(owner)
    reports = client.get("/api/leaderboard/reports", auth=ADMIN).json()
    assert [report["reason"] for report in reports] == ["Poster blocked"]
    assert "reporter_id" not in reports[0]

    block_id = client.get("/api/leaderboard/blocks", headers=blocker).json()[0]["id"]
    assert (
        client.delete(f"/api/leaderboard/blocks/{block_id}", headers=owner).status_code
        == 404
    )
    assert (
        client.delete(
            f"/api/leaderboard/blocks/{block_id}", headers=blocker
        ).status_code
        == 200
    )
    assert theirs["id"] in listed_ids(client, blocker)


def test_cannot_block_yourself_or_an_ownerless_board(client, device):
    owner = device("owner")
    mine = make_board(client, owner)
    client.post("/api/leaderboard/courses", json={"name": "Seeded"}, auth=ADMIN)
    seeded = next(
        c
        for c in client.get("/api/leaderboard/courses").json()
        if c["name"] == "Seeded"
    )

    for board in (mine, seeded):
        r = client.post(
            "/api/leaderboard/blocks",
            json={"target_type": "course", "target_id": board["id"]},
            headers=owner,
        )
        assert r.status_code == 400


def test_join_and_block_made_before_sign_in_follow_the_account(client, device):
    owner, poster = device("owner"), device("poster")
    late = device("late", signed_in=False)
    secret = make_board(client, owner, "Secret", unlisted=True)
    theirs = make_board(client, poster, "Theirs")
    assert (
        client.post(
            "/api/leaderboard/join", json={"code": secret["join_code"]}, headers=late
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/leaderboard/blocks",
            json={"target_type": "course", "target_id": theirs["id"]},
            headers=late,
        ).status_code
        == 201
    )

    sign_in(late, "late")

    ids = listed_ids(client, late)
    assert secret["id"] in ids and theirs["id"] not in ids
    assert len(client.get("/api/leaderboard/blocks", headers=late).json()) == 1


@pytest.fixture
def banned(client, device):
    owner, bad = device("owner"), device("bad")
    board = make_board(client, owner, "Open")
    secret = make_board(client, owner, "Secret", unlisted=True)
    bad_board = make_board(client, bad, "Bad Board")
    run = post_run(client, bad, board["id"], "Bad")
    r = client.post(
        "/api/acceleration",
        json={"vehicle": "Car", "zero_to_60_seconds": 5},
        headers=bad,
    )
    assert r.status_code == 201
    target = {"target_type": "run", "target_id": run["id"]}
    assert (
        client.post("/api/leaderboard/bans", json=target, headers=owner).status_code
        == 401
    )
    r = client.post("/api/leaderboard/bans", json=target | {"reason": "r"}, auth=ADMIN)
    assert r.status_code == 201
    return {
        "headers": bad, "owner": owner, "board": board, "secret": secret,
        "bad_board": bad_board, "run": run, "accel": client.get("/api/acceleration", auth=ADMIN).json()[0],
        "ban": r.json(),
    }  # fmt: skip


def test_ban_blocks_every_write(client, banned):
    board, bad_board, run, accel = (
        banned[key]["id"] for key in ("board", "bad_board", "run", "accel")
    )
    target = {"target_type": "course", "target_id": board}
    writes = [
        ("POST", f"/api/leaderboard/courses/{board}/runs", {"driver": "B", "time": 1}),
        ("POST", "/api/leaderboard/courses", {"name": "Another"}),
        ("PATCH", f"/api/leaderboard/courses/{bad_board}", {"name": "Renamed"}),
        ("DELETE", f"/api/leaderboard/courses/{bad_board}", None),
        ("PATCH", f"/api/leaderboard/runs/{run}", {"notes": "x"}),
        ("DELETE", f"/api/leaderboard/runs/{run}", None),
        ("POST", "/api/leaderboard/reports", target | {"reason": "x"}),
        ("POST", "/api/leaderboard/blocks", target),
        ("POST", "/api/leaderboard/join", {"code": banned["secret"]["join_code"]}),
        ("POST", "/api/acceleration", {"vehicle": "V", "zero_to_60_seconds": 5}),
        ("PATCH", f"/api/acceleration/{accel}", {"notes": "x"}),
        ("DELETE", f"/api/acceleration/{accel}", None),
    ]
    for method, path, body in writes:
        r = client.request(method, path, json=body, headers=banned["headers"])
        assert r.status_code == 403, f"{method} {path}: {r.status_code}"


def test_ban_hides_what_the_poster_posted_and_lifting_it_does_not_unhide(
    client, banned
):
    owner = banned["owner"]

    def visible():
        runs = client.get(
            f"/api/leaderboard/courses/{banned['board']['id']}", headers=owner
        ).json()["runs"]
        return (
            banned["bad_board"]["id"] in listed_ids(client, owner)
            or any(run["id"] == banned["run"]["id"] for run in runs)
            or bool(client.get("/api/acceleration").json())
        )

    assert not visible()
    assert set(banned["ban"]) == {"id", "label", "reason", "created_at"}
    assert (
        client.delete(
            f"/api/leaderboard/bans/{banned['ban']['id']}", auth=ADMIN
        ).status_code
        == 200
    )
    assert not visible()
    post_run(client, banned["headers"], banned["board"]["id"], "Back")


def test_ban_follows_the_account_to_another_phone(client, device, banned):
    assert device("bad") == banned["headers"]
    token = "second-phone-of-the-banned-account"
    with db.session() as conn:
        conn.execute(
            "INSERT INTO devices (token, user_id) SELECT ?, id FROM users WHERE apple_sub = 'bad'",
            (token,),
        )
    r = client.post(
        f"/api/leaderboard/courses/{banned['board']['id']}/runs",
        json={"driver": "B", "time": 1},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 403


def test_ban_on_a_device_token_moves_to_the_account_at_sign_in(client, device):
    owner = device("owner")
    sneaky = device("sneaky", signed_in=False)
    board = make_board(client, owner, "Open")
    client.post("/api/leaderboard/courses", json={"name": "Handed Over"}, auth=ADMIN)
    handed = next(
        c
        for c in client.get("/api/leaderboard/courses").json()
        if c["name"] == "Handed Over"
    )
    token = sneaky["Authorization"].removeprefix("Bearer ")
    client.put(
        f"/api/leaderboard/courses/{handed['id']}/owner",
        json={"device_token": token},
        auth=ADMIN,
    )
    client.post(
        "/api/leaderboard/bans",
        json={"target_type": "course", "target_id": handed["id"]},
        auth=ADMIN,
    )

    sign_in(sneaky, "sneaky")

    r = client.post(
        f"/api/leaderboard/courses/{board['id']}/runs",
        json={"driver": "S", "time": 1},
        headers=sneaky,
    )
    assert r.status_code == 403


def test_word_filter_applies_to_devices_and_not_admins(client, device):
    owner = device("owner")
    board = make_board(client, owner)
    path = f"/api/leaderboard/courses/{board['id']}/runs"

    ok = {"driver": "Dick Hooker", "time": 55, "notes": "damn drag strip"}
    assert client.post(path, json=ok, headers=owner).status_code == 200
    assert (
        client.post(
            path, json={"driver": "fuck", "time": 55}, headers=owner
        ).status_code
        == 400
    )
    assert (
        client.post(path, json={"driver": "fuck", "time": 55}, auth=ADMIN).status_code
        == 200
    )
