import app
import ratelimit
from conftest import ADMIN


def test_admin_login_is_limited_and_wrong_passwords_count_everywhere(client):
    wrong = ("admin", "guess")
    for _ in range(app.LOGIN_LIMIT[0] - 1):
        assert client.post("/api/admin/session", auth=wrong).status_code == 401
    # A wrong password on any other endpoint is a guess too.
    assert client.get("/api/leaderboard/courses", auth=wrong).status_code == 401
    blocked = client.post("/api/admin/session", auth=ADMIN)
    assert blocked.status_code == 429
    assert int(blocked.headers["Retry-After"]) > 0


def test_writes_are_limited_per_address_but_not_for_admin(client, device):
    sam = device("sam")
    for _ in range(app.WRITE_LIMIT[0]):
        assert (
            client.delete("/api/leaderboard/runs/999", headers=sam).status_code == 404
        )
    assert client.delete("/api/leaderboard/runs/999", headers=sam).status_code == 429
    # Reads and the admin carry on.
    assert client.get("/api/leaderboard/courses", headers=sam).status_code == 200
    assert client.delete("/api/leaderboard/runs/999", auth=ADMIN).status_code == 404
    # Another address has its own allowance.
    other = {**sam, "X-Forwarded-For": "203.0.113.9"}
    assert client.delete("/api/leaderboard/runs/999", headers=other).status_code == 404


def test_apple_notifications_are_not_limited(client):
    for _ in range(app.WRITE_LIMIT[0] + 1):
        response = client.post(
            "/api/account/apple/notifications", json={"payload": "x"}
        )
        assert response.status_code == 401


def test_client_key_trusts_only_the_proxys_entry():
    # Behind the proxy, the last forwarded entry is the one the proxy added.
    assert ratelimit.client_key("172.17.0.1", "1.2.3.4, 198.51.100.7") == "198.51.100.7"
    assert ratelimit.client_key("127.0.0.1", None) == "127.0.0.1"
    # A caller reaching the port directly cannot claim another address.
    assert ratelimit.client_key("8.8.8.8", "1.2.3.4") == "8.8.8.8"
    # An IPv6 caller is its /64.
    assert ratelimit.client_key("10.0.0.2", "2001:db8:1:2::5") == "2001:db8:1:2::/64"
    assert ratelimit.client_key("10.0.0.2", "garbage") == "10.0.0.2"
