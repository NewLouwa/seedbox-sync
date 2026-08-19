#!/usr/bin/env python3
"""seedbox-db - local ledger of what is synced between the seedbox and this host.

Read-only audit layer on top of the lftp mirror: it records the real state of
both sides in a SQLite database and reports the differences. It never downloads,
deletes, or moves anything.

Identity of a file = relative path + size + a *partial* SHA-256 (first 4 MiB +
last 4 MiB + size). The partial hash reads only 8 MiB whatever the file size, so
a full library scan takes seconds, yet it still catches truncation and
same-name re-releases. A full SHA-256 is available on demand via `verify --full`.

Configuration is passed through the environment by the `sbs db` wrapper (single
source of truth = config.sh + /etc/seedbox-sync.env):
    LOCAL_BASE          local destination root (e.g. /mnt/dl)
    SEEDBOX_MAPPINGS    one "remote_key<TAB>local_folder" per line
    SEEDBOX_DB          path to the SQLite file
    REMOTE_USER/HOST    seedbox SSH target
    SSH_KEY / SSH_PORT  optional SSH key + port
"""

import hashlib
import os
import sqlite3
import subprocess
import sys
import time

HEAD_TAIL = 4 * 1024 * 1024  # 4 MiB sampled at each end for the partial hash
VIDEO_EXT = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".ts", ".m2ts"}


# --------------------------------------------------------------------------- #
# Config / helpers
# --------------------------------------------------------------------------- #
def env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"[seedbox-db] missing required env {name} (run via 'sbs db')")
    return val


def load_mappings():
    """Return [(remote_key, local_folder), ...], longest remote_key first."""
    raw = env("SEEDBOX_MAPPINGS", "")
    pairs = []
    for line in raw.splitlines():
        line = line.rstrip("\n")
        if not line or "\t" not in line:
            continue
        rk, lf = line.split("\t", 1)
        pairs.append((rk, lf))
    # longest first so "media/Movies" wins over a hypothetical "media"
    pairs.sort(key=lambda p: len(p[0]), reverse=True)
    return pairs


def human(n):
    n = float(n or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}"
        n /= 1024


def ssh_cmd():
    user = env("REMOTE_USER", required=True)
    host = env("REMOTE_HOST", required=True)
    port = env("SSH_PORT", "22")
    key = env("SSH_KEY", "")
    base = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
            "-p", str(port)]
    if key and os.path.isfile(key):
        base += ["-i", key]
    base.append(f"{user}@{host}")
    return base


# --------------------------------------------------------------------------- #
# Database
# --------------------------------------------------------------------------- #
def db_connect():
    path = env("SEEDBOX_DB", required=True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS remote_files (
            logical     TEXT PRIMARY KEY,
            remote_path TEXT NOT NULL,
            size        INTEGER NOT NULL,
            mtime       REAL,
            seen_at     INTEGER
        );
        CREATE TABLE IF NOT EXISTS local_files (
            logical      TEXT PRIMARY KEY,
            local_path   TEXT NOT NULL,
            size         INTEGER NOT NULL,
            mtime        REAL,
            partial_hash TEXT,
            full_hash    TEXT,
            hashed_size  INTEGER,
            hashed_mtime REAL,
            seen_at      INTEGER
        );
        CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
        """
    )
    return con


def set_meta(con, k, v):
    con.execute("INSERT INTO meta(k, v) VALUES(?, ?) "
                "ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))


def get_meta(con, k, default=None):
    row = con.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row[0] if row else default


# --------------------------------------------------------------------------- #
# Hashing
# --------------------------------------------------------------------------- #
def partial_hash(path, size):
    h = hashlib.sha256()
    h.update(str(size).encode())
    try:
        with open(path, "rb") as f:
            if size <= 2 * HEAD_TAIL:
                h.update(f.read())
            else:
                h.update(f.read(HEAD_TAIL))
                f.seek(-HEAD_TAIL, os.SEEK_END)
                h.update(f.read(HEAD_TAIL))
    except OSError as e:
        return f"ERR:{e.errno}"
    return h.hexdigest()


def full_hash(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    except OSError as e:
        return f"ERR:{e.errno}"
    return h.hexdigest()


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def match_mapping(remote_path, mappings):
    """Map a remote path (media/Cat/rel...) to (local_folder, rel)."""
    for rk, lf in mappings:
        if remote_path == rk or remote_path.startswith(rk + "/"):
            rel = remote_path[len(rk):].lstrip("/")
            return lf, rel
    return None, None


def cmd_scan_remote(con, args):
    mappings = load_mappings()
    if not mappings:
        sys.exit("[seedbox-db] no SEEDBOX_MAPPINGS configured")
    print("[scan-remote] querying seedbox via SSH ...")
    cmd = ssh_cmd() + ["find media -type f -printf '%s\\t%T@\\t%p\\n' 2>/dev/null"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        sys.exit("[scan-remote] SSH timed out")
    if out.returncode != 0 and not out.stdout:
        sys.exit(f"[scan-remote] SSH failed rc={out.returncode}: {out.stderr.strip()}")

    now = int(time.time())
    con.execute("DELETE FROM remote_files")
    n = skipped = 0
    for line in out.stdout.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        size_s, mtime_s, rpath = parts
        lf, rel = match_mapping(rpath, mappings)
        if lf is None:
            skipped += 1
            continue
        logical = f"{lf}/{rel}"
        try:
            size = int(size_s)
            mtime = float(mtime_s)
        except ValueError:
            continue
        con.execute(
            "INSERT OR REPLACE INTO remote_files"
            "(logical, remote_path, size, mtime, seen_at) VALUES(?,?,?,?,?)",
            (logical, rpath, size, mtime, now),
        )
        n += 1
    set_meta(con, "remote_scanned_at", now)
    con.commit()
    print(f"[scan-remote] {n} files recorded"
          f"{f', {skipped} outside mappings skipped' if skipped else ''}")


def cmd_scan_local(con, args):
    mappings = load_mappings()
    base = env("LOCAL_BASE", "/mnt/dl")
    now = int(time.time())
    # cache existing hashes to avoid re-reading unchanged files
    cache = {r[0]: r for r in con.execute(
        "SELECT logical, size, mtime, partial_hash, hashed_size, hashed_mtime "
        "FROM local_files")}
    con.execute("DELETE FROM local_files")

    n = hashed = 0
    for rk, lf in mappings:
        root = os.path.join(base, lf)
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                fpath = os.path.join(dirpath, fn)
                if fn.endswith(".lftp-tmp"):
                    continue  # in-flight partial, not a finished file
                try:
                    st = os.stat(fpath)
                except OSError:
                    continue
                rel = os.path.relpath(fpath, root)
                logical = f"{lf}/{rel}"
                size, mtime = st.st_size, st.st_mtime
                prev = cache.get(logical)
                ph = None
                if (prev and prev[4] == size and prev[5] == mtime
                        and prev[3] and not prev[3].startswith("ERR")):
                    ph = prev[3]  # unchanged -> reuse cached partial hash
                else:
                    ph = partial_hash(fpath, size)
                    hashed += 1
                con.execute(
                    "INSERT OR REPLACE INTO local_files"
                    "(logical, local_path, size, mtime, partial_hash,"
                    " full_hash, hashed_size, hashed_mtime, seen_at)"
                    " VALUES(?,?,?,?,?,?,?,?,?)",
                    (logical, fpath, size, mtime, ph, None, size, mtime, now),
                )
                n += 1
                if n % 200 == 0:
                    print(f"  ... {n} files ({hashed} hashed)", flush=True)
    set_meta(con, "local_scanned_at", now)
    con.commit()
    print(f"[scan-local] {n} files recorded ({hashed} (re)hashed)")


def _diff_rows(con):
    remote = {row[0]: row[1] for row in con.execute(
        "SELECT logical, size FROM remote_files")}
    local = {row[0]: row[1] for row in con.execute(
        "SELECT logical, size FROM local_files")}
    missing, incomplete, mismatch, ok, extra = [], [], [], [], []
    for logical, rsize in remote.items():
        if logical not in local:
            missing.append((logical, rsize))
            continue
        lsize = local[logical]
        if lsize == rsize:
            ok.append((logical, rsize))
        elif lsize < rsize:
            incomplete.append((logical, lsize, rsize))
        else:
            mismatch.append((logical, lsize, rsize))
    for logical, lsize in local.items():
        if logical not in remote:
            extra.append((logical, lsize))
    return missing, incomplete, mismatch, ok, extra


def cmd_diff(con, args):
    missing, incomplete, mismatch, ok, extra = _diff_rows(con)
    limit = 40

    def show(title, rows, fmt):
        print(f"\n== {title} ({len(rows)}) ==")
        for row in rows[:limit]:
            print("  " + fmt(row))
        if len(rows) > limit:
            print(f"  ... +{len(rows) - limit} more")

    show("MISSING - on seedbox, not local (to download)", missing,
         lambda r: f"{human(r[1]):>10}  {r[0]}")
    show("INCOMPLETE - local smaller, will resume", incomplete,
         lambda r: f"{human(r[1]):>10}/{human(r[2]):<10} {r[0]}")
    show("MISMATCH - local larger than remote (re-release/legacy?)", mismatch,
         lambda r: f"{human(r[1]):>10}/{human(r[2]):<10} {r[0]}")

    vids = [e for e in extra if os.path.splitext(e[0])[1].lower() in VIDEO_EXT]
    meta = [e for e in extra if e not in vids]
    show("EXTRA video - local only (legacy, never auto-removed)", vids,
         lambda r: f"{human(r[1]):>10}  {r[0]}")
    print(f"\n== EXTRA sidecars/other - local only ({len(meta)}) ==")
    print(f"  {len(meta)} non-video files (nfo, posters, subs...) - ignored by sync")
    print(f"\n== SYNCED OK: {len(ok)} files ==")


def cmd_status(con, args):
    rcount, rsize = con.execute(
        "SELECT COUNT(*), COALESCE(SUM(size),0) FROM remote_files").fetchone()
    lcount, lsize = con.execute(
        "SELECT COUNT(*), COALESCE(SUM(size),0) FROM local_files").fetchone()
    missing, incomplete, mismatch, ok, extra = _diff_rows(con)
    miss_size = sum(m[1] for m in missing) + sum(i[2] - i[1] for i in incomplete)
    print("seedbox-db status")
    print(f"  remote : {rcount:>6} files, {human(rsize)}"
          f"   (scanned {_ago(get_meta(con, 'remote_scanned_at'))})")
    print(f"  local  : {lcount:>6} files, {human(lsize)}"
          f"   (scanned {_ago(get_meta(con, 'local_scanned_at'))})")
    print(f"  synced OK    : {len(ok)}")
    print(f"  missing      : {len(missing)}")
    print(f"  incomplete   : {len(incomplete)}")
    print(f"  mismatch     : {len(mismatch)}")
    print(f"  extra (local): {len(extra)}")
    print(f"  ~ to fetch   : {human(miss_size)}")


def _ago(ts):
    if not ts:
        return "never"
    d = int(time.time()) - int(ts)
    if d < 60:
        return f"{d}s ago"
    if d < 3600:
        return f"{d // 60}m ago"
    if d < 86400:
        return f"{d // 3600}h ago"
    return f"{d // 86400}d ago"


def cmd_verify(con, args):
    full = "--full" in args
    pats = [a for a in args if not a.startswith("--")]
    rows = con.execute(
        "SELECT logical, local_path, size, partial_hash, full_hash FROM local_files"
    ).fetchall()
    if pats:
        rows = [r for r in rows if all(p.lower() in r[0].lower() for p in pats)]
    if not rows:
        print("[verify] no local files match")
        return
    kind = "full" if full else "partial"
    print(f"[verify] re-hashing {len(rows)} file(s) [{kind}] ...")
    changed = errors = 0
    for logical, path, size, ph, fh in rows:
        if not os.path.isfile(path):
            print(f"  GONE     {logical}")
            errors += 1
            continue
        if full:
            new = full_hash(path)
            old = fh
            if old and new != old:
                print(f"  CHANGED  {logical}")
                changed += 1
            con.execute("UPDATE local_files SET full_hash=? WHERE logical=?",
                        (new, logical))
        else:
            new = partial_hash(path, os.path.getsize(path))
            if ph and new != ph:
                print(f"  CHANGED  {logical}")
                changed += 1
    con.commit()
    print(f"[verify] done: {changed} changed, {errors} missing")


def cmd_resync(con, args):
    cmd_scan_remote(con, args)
    cmd_scan_local(con, args)
    print()
    cmd_status(con, args)


COMMANDS = {
    "scan-remote": cmd_scan_remote,
    "scan-local": cmd_scan_local,
    "resync": cmd_resync,
    "diff": cmd_diff,
    "status": cmd_status,
    "verify": cmd_verify,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("Usage: sbs db {scan-remote|scan-local|resync|diff|status|"
              "verify [pattern] [--full]}")
        sys.exit(1)
    con = db_connect()
    try:
        COMMANDS[sys.argv[1]](con, sys.argv[2:])
    finally:
        con.close()


if __name__ == "__main__":
    main()
