"""Back up (and restore) the leaderboard SQLite database.

Usage:
    python3 server/backup_db.py                 # snapshot the DB if it changed
    python3 server/backup_db.py list            # show existing snapshots
    python3 server/backup_db.py restore FILE    # replace the live DB with FILE

Snapshots are written with SQLite's online backup API, so it's safe to run
while the server is up. A new snapshot is only kept when the database content
differs from the most recent snapshot, and the oldest snapshots are pruned once
there are more than KEEP of them. The destination directory must sit on a
mounted drive (see BACKUP_DIR) so a missing HDD doesn't silently fill the root
disk with backups that aren't where you think they are.
"""

import hashlib
import os
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent / "leaderboard.db"
BACKUP_DIR = Path(
    os.environ.get("AUTOX_BACKUP_DIR", "/mnt/Data/Backups/autox-leaderboard")
)
KEEP = int(os.environ.get("AUTOX_BACKUP_KEEP", "365"))
PREFIX = "leaderboard-"


def log(msg: str) -> None:
    print(f"{datetime.now().astimezone():%Y-%m-%d %H:%M:%S} {msg}", flush=True)


def require_mounted(path: Path) -> None:
    # Walk up until we hit a mountpoint; refuse if the only mountpoint is /.
    for parent in [path, *path.parents]:
        if parent.is_mount():
            if parent == Path("/"):
                sys.exit(
                    f"{path} is not on a mounted drive; refusing to back up to the root disk"
                )
            return


def snapshots(directory: Path) -> list[Path]:
    return sorted(directory.glob(f"{PREFIX}*.db"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def backup() -> None:
    if not DB_PATH.exists():
        sys.exit(f"no database at {DB_PATH}")
    require_mounted(BACKUP_DIR)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    tmp = BACKUP_DIR / f".{PREFIX}tmp-{os.getpid()}.db"
    try:
        src = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        dst = sqlite3.connect(tmp)
        with dst:
            src.backup(dst)
        src.close()
        dst.close()

        existing = snapshots(BACKUP_DIR)
        if existing and sha256(existing[-1]) == sha256(tmp):
            tmp.unlink()
            return  # unchanged since the last snapshot; stay quiet for cron

        target = BACKUP_DIR / f"{PREFIX}{datetime.now().astimezone():%Y%m%d-%H%M%S}.db"
        tmp.replace(target)
        log(f"saved {target} ({target.stat().st_size} bytes)")
    finally:
        tmp.unlink(missing_ok=True)

    for old in snapshots(BACKUP_DIR)[:-KEEP]:
        old.unlink()
        log(f"pruned {old}")


def list_snapshots() -> None:
    files = snapshots(BACKUP_DIR) if BACKUP_DIR.exists() else []
    if not files:
        print(f"no snapshots in {BACKUP_DIR}")
        return
    for f in files:
        print(f"{f}  {f.stat().st_size} bytes")


def restore(source: str) -> None:
    src = Path(source)
    if not src.is_absolute() and not src.exists():
        src = BACKUP_DIR / source
    if not src.exists():
        sys.exit(f"no such snapshot: {source}")
    conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    ok = conn.execute("PRAGMA integrity_check").fetchone()[0]
    conn.close()
    if ok != "ok":
        sys.exit(f"{src} failed integrity check: {ok}")

    if DB_PATH.exists():
        safety = DB_PATH.with_name(
            f"leaderboard.pre-restore-{datetime.now().astimezone():%Y%m%d-%H%M%S}.db"
        )
        shutil.copy2(DB_PATH, safety)
        log(f"kept the current DB as {safety}")
    shutil.copy2(src, DB_PATH)
    log(f"restored {src} -> {DB_PATH}")
    log("restart the server (./start.sh) so it reopens the database")


def main(argv: list[str]) -> None:
    cmd = argv[1] if len(argv) > 1 else "backup"
    if cmd == "backup":
        backup()
    elif cmd == "list":
        list_snapshots()
    elif cmd == "restore" and len(argv) == 3:
        restore(argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
