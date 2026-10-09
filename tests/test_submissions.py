import base64

import app
import db
import pytest
from conftest import ADMIN, READ_KEY

JPEG = b"\xff\xd8\xff\xe0" + b"proof" * 20
PNG = b"\x89PNG\r\n\x1a\n" + b"proof" * 20
RUN = {"driver": "Sam", "time": "1:17.967", "vehicle": "1999 Miata", "hp": 140}
ACCEL = {
    "vehicle": "Nissan Xterra",
    "driver": "Sam",
    "year": 2012,
    "hp": 261,
    "weight_lb": 4400,
    "zero_to_60_seconds": 12.22,
}


def _encode(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _course(client, **fields) -> int:
    created = client.post(
        "/api/leaderboard/courses", json={"name": "Airfield", **fields}, auth=ADMIN
    )
    return created.json()["id"]


def _submit(client, headers=None, auth=None, proof=JPEG, **body):
    return client.post(
        "/api/submissions",
        json={"proof": _encode(proof), **body},
        headers=headers,
        auth=auth,
    )


def _proofs() -> list:
    return list(db.proof_dir().glob("*")) if db.proof_dir().exists() else []


def _pending(client) -> list[dict]:
    return client.get("/api/admin/submissions", auth=ADMIN).json()


def test_run_waits_for_approval_then_belongs_to_its_submitter(client, device):
    course_id = _course(client)
    sam = device("sam")
    created = _submit(client, sam, course_id=course_id, run=RUN)
    assert created.status_code == 201
    submission = created.json()
    assert submission["status"] == "pending"
    assert submission["course_name"] == "Airfield"
    assert submission["summary"] == "1:17.967 · Sam · 1999 Miata"

    board = f"/api/leaderboard/courses/{course_id}"
    assert client.get(board).json()["runs"] == []
    assert [s["id"] for s in client.get("/api/submissions", headers=sam).json()] == [
        submission["id"]
    ]

    url = f"/api/admin/submissions/{submission['id']}"
    proof = client.get(f"{url}/proof", auth=ADMIN)
    assert proof.content == JPEG
    assert proof.headers["content-type"] == "image/jpeg"
    assert proof.headers["x-content-type-options"] == "nosniff"

    approved = client.post(f"{url}/approve", auth=ADMIN)
    assert approved.status_code == 200
    assert approved.json()["status"] == "approved"
    runs = client.get(board, headers=sam).json()["runs"]
    assert [(r["driver"], r["time"], r["source"]) for r in runs] == [
        ("Sam", "1:17.967", "photo")
    ]
    assert runs[0]["is_owner"] and runs[0]["id"] == approved.json()["result_id"]

    assert _proofs() == []
    assert client.get(f"{url}/proof", auth=ADMIN).status_code == 404
    assert client.get("/api/submissions", headers=sam).json() == []
    assert client.post(f"{url}/approve", auth=ADMIN).status_code == 409
    assert len(client.get(board).json()["runs"]) == 1


def test_acceleration_submission_is_approved_onto_the_board(client, device):
    sam = device("sam")
    no_weight = {key: value for key, value in ACCEL.items() if key != "weight_lb"}
    submission = _submit(client, sam, acceleration=no_weight, proof=PNG).json()
    assert submission["summary"] == "0-60 12.22s · 2012 Nissan Xterra"
    assert client.get("/api/acceleration").json() == []
    proof = client.get(f"/api/admin/submissions/{submission['id']}/proof", auth=ADMIN)
    assert proof.headers["content-type"] == "image/png"

    client.post(f"/api/admin/submissions/{submission['id']}/approve", auth=ADMIN)
    entries = client.get("/api/acceleration", headers=sam).json()
    assert [(e["vehicle"], e["source"], e["is_owner"]) for e in entries] == [
        ("Nissan Xterra", "photo", True)
    ]


def test_rejection_reaches_the_submitter_and_posts_nothing(client, device):
    course_id = _course(client)
    sam = device("sam")
    submission = _submit(client, sam, course_id=course_id, run=RUN).json()
    url = f"/api/admin/submissions/{submission['id']}"
    rejected = client.post(
        f"{url}/reject", json={"note": "Photo is unreadable"}, auth=ADMIN
    )
    assert rejected.json()["status"] == "rejected"
    assert _proofs() == []
    assert _pending(client) == []
    assert client.get(f"/api/leaderboard/courses/{course_id}").json()["runs"] == []

    mine = client.get("/api/submissions", headers=sam).json()
    assert [(s["status"], s["review_note"]) for s in mine] == [
        ("rejected", "Photo is unreadable")
    ]
    assert client.post(f"{url}/approve", auth=ADMIN).status_code == 409
    assert client.delete(
        f"/api/submissions/{submission['id']}", headers=sam
    ).json() == {"deleted": submission["id"]}
    assert client.get("/api/submissions", headers=sam).json() == []


@pytest.mark.parametrize(
    "headers", [None, {"X-Leaderboard-Key": READ_KEY}], ids=["anonymous", "read key"]
)
def test_only_the_admin_reaches_the_queue_and_the_photo(client, device, headers):
    course_id = _course(client)
    submission = _submit(client, device("sam"), course_id=course_id, run=RUN).json()
    url = f"/api/admin/submissions/{submission['id']}"
    other = device("other")
    for caller in (headers, other):
        assert client.get("/api/admin/submissions", headers=caller).status_code == 401
        assert client.get(f"{url}/proof", headers=caller).status_code == 401
        assert client.post(f"{url}/approve", headers=caller).status_code == 401
        assert client.post(f"{url}/reject", json={}, headers=caller).status_code == 401
        deleted = client.delete(f"/api/submissions/{submission['id']}", headers=caller)
        assert deleted.status_code == 404
        assert client.get("/api/submissions", headers=caller).json() == []
    assert _submit(client, headers, course_id=course_id, run=RUN).status_code == 401
    assert len(_pending(client)) == 1 and len(_proofs()) == 1


def test_submitting_follows_the_posting_rules(client, device):
    course_id = _course(client)
    sam = device("sam")
    guest = device("guest", signed_in=False)
    assert _submit(client, guest, course_id=course_id, run=RUN).status_code == 403
    assert _submit(client, auth=ADMIN, course_id=course_id, run=RUN).status_code == 400
    assert _submit(client, sam, run=RUN).status_code == 400
    assert _submit(client, sam, course_id=course_id).status_code == 400
    both = _submit(client, sam, course_id=course_id, run=RUN, acceleration=ACCEL)
    assert both.status_code == 400
    assert _submit(client, sam, course_id=999, run=RUN).status_code == 404
    rude = _submit(client, sam, course_id=course_id, run={**RUN, "notes": "shit"})
    assert rude.status_code == 400
    car = {"vehicle": "Miata", "year": 1999, "hp": 140, "weight_lb": 2300}
    no_time = _submit(client, sam, acceleration=car)
    assert no_time.status_code == 400
    for missing in ("vehicle", "hp"):
        run = {key: value for key, value in RUN.items() if key != missing}
        assert _submit(client, sam, course_id=course_id, run=run).status_code == 400
    for missing in ("year", "hp"):
        entry = {key: value for key, value in ACCEL.items() if key != missing}
        assert _submit(client, sam, acceleration=entry).status_code == 400

    unlisted = _course(client, name="Private", unlisted=True)
    assert _submit(client, sam, course_id=unlisted, run=RUN).status_code == 404
    assert _pending(client) == [] and _proofs() == []


def test_proof_must_be_a_real_image_of_a_sane_size(client, device, monkeypatch):
    sam = device("sam")
    html = b"<html><script>alert(1)</script></html>"
    assert _submit(client, sam, acceleration=ACCEL, proof=html).status_code == 400
    garbled = client.post(
        "/api/submissions",
        json={"proof": "not base64!", "acceleration": ACCEL},
        headers=sam,
    )
    assert garbled.status_code == 400
    monkeypatch.setattr(app, "MAX_PROOF_BYTES", 50)
    assert _submit(client, sam, acceleration=ACCEL).status_code == 413
    assert _proofs() == []


def test_pending_submissions_are_capped_per_account(client, device):
    sam = device("sam")
    for _ in range(app.MAX_PENDING_SUBMISSIONS):
        assert _submit(client, sam, acceleration=ACCEL).status_code == 201
    assert _submit(client, sam, acceleration=ACCEL).status_code == 429
    assert _submit(client, device("other"), acceleration=ACCEL).status_code == 201
    first = _pending(client)[-1]["id"]
    client.post(f"/api/admin/submissions/{first}/reject", json={}, auth=ADMIN)
    assert _submit(client, sam, acceleration=ACCEL).status_code == 201


def test_queue_names_the_submitter_without_leaking_an_identity(client, device):
    sam = device("sam")
    _submit(client, sam, acceleration=ACCEL)
    listing = client.get("/api/admin/submissions", auth=ADMIN)
    [submission] = listing.json()
    assert submission["submitter"]["kind"] == "user"
    assert submission["submitter"]["name"] == "sam"
    with db.session() as conn:
        secrets = {row["token"] for row in conn.execute("SELECT token FROM devices")}
        secrets |= {
            app._account_owner_id(row["apple_sub"])
            for row in conn.execute("SELECT apple_sub FROM users")
        }
    own = client.get("/api/submissions", headers=sam)
    for text in (listing.text, own.text):
        assert not any(secret in text for secret in secrets)


def test_photos_go_when_their_submission_does(client, device):
    sam, owner = device("sam"), device("owner")
    board = client.post(
        "/api/leaderboard/courses", json={"name": "Owned"}, headers=owner
    ).json()["id"]
    _submit(client, sam, course_id=board, run=RUN)
    _submit(client, sam, acceleration=ACCEL)
    assert len(_proofs()) == 2

    assert client.delete(f"/api/leaderboard/courses/{board}", headers=owner).json()
    assert len(_proofs()) == 1 and len(_pending(client)) == 1

    assert client.delete("/api/account", headers=sam).status_code == 200
    assert _proofs() == [] and _pending(client) == []


def test_deleting_an_account_drops_submissions_to_its_boards(client, device):
    sam, owner = device("sam"), device("owner")
    board = client.post(
        "/api/leaderboard/courses", json={"name": "Owned"}, headers=owner
    ).json()["id"]
    _submit(client, sam, course_id=board, run=RUN)
    assert client.delete("/api/account", headers=owner).status_code == 200
    assert _proofs() == [] and _pending(client) == []


def test_ban_clears_what_was_waiting(client, device):
    sam = device("sam")
    entry = client.post("/api/acceleration", json=ACCEL, headers=sam).json()
    _submit(client, sam, acceleration=ACCEL)
    banned = client.post(
        "/api/leaderboard/bans",
        json={"target_type": "acceleration", "target_id": entry["id"]},
        auth=ADMIN,
    )
    assert banned.status_code == 201
    assert _pending(client) == [] and _proofs() == []
    assert _submit(client, sam, acceleration=ACCEL).status_code == 403


def test_signing_in_carries_a_devices_submissions_to_the_account(client, device):
    sam = device("sam")
    submission = _submit(client, sam, acceleration=ACCEL).json()
    token = sam["Authorization"].removeprefix("Bearer ")
    with db.session() as conn:
        conn.execute("UPDATE submissions SET owner_id = ?", (token,))
        app._adopt_device(conn, token, app._account_owner_id("sam"))
    mine = client.get("/api/submissions", headers=sam).json()
    assert [s["id"] for s in mine] == [submission["id"]]
