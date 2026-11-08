"""Release notes for the /updates page, read from the repo's GitHub releases.

`deploy.sh` publishes one release per build (tag `ios-v2.0-3`, name
`iOS 2.0 (3)`) whose body is written in the editor from a draft of the
commits since the last one (`./deploy.sh notes TAG` rewrites it later). The page
shows one post per version, so builds are grouped by version and the lines
that only make sense to a developer (merges, version bumps, screenshots,
App Store Connect copy) are dropped. Edit a release's body on GitHub to
change what the page says.
"""

import re

import httpx

RELEASES_URL = "https://api.github.com/repos/romangarms/Evergreen-AutoX-App/releases"
TAG = re.compile(r"^(ios|android)-v(\d+(?:\.\d+)*)-(\d+)$")
# Lines the page leaves out, matched against the start of each line.
SKIP = re.compile(
    r"^(merge\b|ios \d|android \d|app store connect\b|testflight build\b"
    r"|(updated |marketing )?screenshots\b|xcscheme\b|goals\b|md updates\b)",
    re.IGNORECASE,
)


def fetch() -> list[dict]:
    response = httpx.get(
        RELEASES_URL,
        params={"per_page": 100},
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "autox-live-server",
        },
        timeout=10,
    )
    response.raise_for_status()
    return response.json()


def _notes(body: str | None) -> list[str]:
    notes = []
    for line in (body or "").splitlines():
        line = re.sub(r"^\s*[-*]\s+", "", line).strip()
        if line and not SKIP.match(line):
            notes.append(line)
    return notes


def _version_key(version: str) -> tuple:
    return tuple(int(part) for part in version.split("."))


def group(releases: list[dict]) -> list[dict]:
    """One entry per version, newest version first; within it the newest
    build's notes come first and each line appears once."""
    versions: dict[str, dict] = {}
    for release in releases:
        match = TAG.match(release.get("tag_name") or "")
        if not match or release.get("draft") or release.get("prerelease"):
            continue
        version, build = match.group(2), int(match.group(3))
        published = release.get("published_at") or ""
        entry = versions.setdefault(
            version,
            {
                "version": version,
                "builds": [],
                "released_at": published,
                "updated_at": published,
            },
        )
        entry["builds"].append(
            (build, published, release.get("html_url"), _notes(release.get("body")))
        )
        entry["released_at"] = min(entry["released_at"], published)
        entry["updated_at"] = max(entry["updated_at"], published)

    result = []
    for version in sorted(versions, key=_version_key, reverse=True):
        entry = versions[version]
        builds = sorted(entry.pop("builds"), key=lambda b: (b[1], b[0]), reverse=True)
        notes: list[str] = []
        for _, _, _, lines in builds:
            notes.extend(line for line in lines if line not in notes)
        entry["notes"] = notes
        entry["url"] = builds[0][2]
        result.append(entry)
    return result
