import cache
import httpx
import releases

RELEASES = [
    {
        "tag_name": "ios-v2.0-2",
        "published_at": "2026-11-03T22:25:43Z",
        "html_url": "u2",
        "body": "- Friends: share the list\n- Merge origin/main\n- Android 2.0 (2)",
    },
    {
        "tag_name": "ios-v2.0-1",
        "published_at": "2026-10-21T00:26:43Z",
        "html_url": "u1",
        "body": "- Pull to refresh everywhere\n- updated screenshots\n- xcscheme",
    },
    {
        "tag_name": "ios-v1.10-1",
        "published_at": "2026-10-09T18:03:46Z",
        "html_url": "u0",
        "body": "- Photo-proof submissions\n- App Store Connect copy for 1.5",
    },
    {
        "tag_name": "ios-v3.0-1",
        "published_at": "2026-12-01T00:00:00Z",
        "draft": True,
        "body": "- Secret",
    },
    {
        "tag_name": "something-else",
        "published_at": "2026-12-01T00:00:00Z",
        "body": "- Nope",
    },
]


def test_group_by_version_and_drop_developer_lines():
    grouped = releases.group(RELEASES)
    assert [v["version"] for v in grouped] == ["2.0", "1.10"]
    assert grouped[0] == {
        "version": "2.0",
        "released_at": "2026-10-21T00:26:43Z",
        "updated_at": "2026-11-03T22:25:43Z",
        "notes": ["Friends: share the list", "Pull to refresh everywhere"],
        "url": "u2",
    }
    assert grouped[1]["notes"] == ["Photo-proof submissions"]


def test_updates_endpoint_caches_and_reports_github_failure(client, monkeypatch):
    calls = []

    def fetch():
        calls.append(1)
        return RELEASES

    monkeypatch.setattr(releases, "fetch", fetch)
    cache.clear()
    assert client.get("/api/updates").json()[0]["version"] == "2.0"
    client.get("/api/updates")
    assert len(calls) == 1

    def fail():
        raise httpx.ConnectError("down")

    monkeypatch.setattr(releases, "fetch", fail)
    cache.clear()
    assert client.get("/api/updates").status_code == 502
    cache.clear()
