"""
library_db.py - SQLite index of the Hi-Fi catalog plus the play log.

Why: the catalog is a nested JSON (artists > albums > tracks) that every lookup re-read and walked. The index gives
instant full-text search (FTS5, prefix matching), album/decade views, and - with the play log - the signals a good
"keep playing" needs: play counts, skips, last played, favourites.

    tracks   one row per track (denormalised artist/album, year parsed from the album name, added_ts)
    plays    one row per play event: completed (reached the end), skipped (user moved on early), listened_s
    meta     catalog mtime so a changed catalog rebuilds the index automatically
"""
import json, os, re, sqlite3, threading, time
from typing import Any, Dict, List, Optional, Tuple

DB_PATH = "/data/library.db" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "library.db")
_lock = threading.RLock()
_conn: Optional[sqlite3.Connection] = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS tracks (
  track_id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT, album_key TEXT, track_num INTEGER,
  format TEXT, bit_depth INTEGER, sample_rate_hz INTEGER, duration_s REAL, year INTEGER,
  rel_path TEXT, gdrive_file_id TEXT, file_name TEXT, size_mb REAL, added_ts REAL
);
CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album_key, track_num);
CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
CREATE INDEX IF NOT EXISTS idx_tracks_year ON tracks(year);
CREATE TABLE IF NOT EXISTS plays (
  id INTEGER PRIMARY KEY AUTOINCREMENT, track_id TEXT, ts REAL, completed INTEGER DEFAULT 0,
  skipped INTEGER DEFAULT 0, listened_s REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_plays_track ON plays(track_id, ts);
CREATE INDEX IF NOT EXISTS idx_plays_ts ON plays(ts);
"""
FTS = "CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(track_id UNINDEXED, title, artist, album, tokenize='unicode61 remove_diacritics 2')"


def _db() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        _conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.execute("PRAGMA synchronous=NORMAL")
        _conn.executescript(SCHEMA)
        try:
            _conn.execute(FTS)
            _fts_ok = True
        except sqlite3.OperationalError:
            _fts_ok = False
        _conn.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('fts', ?)", ("1" if _fts_ok else "0",))
        _conn.commit()
    return _conn


def _has_fts() -> bool:
    r = _db().execute("SELECT v FROM meta WHERE k='fts'").fetchone()
    return bool(r and r["v"] == "1")


def _year_of(album: str) -> Optional[int]:
    m = re.search(r"(19|20)\d\d", album or "")
    return int(m.group(0)) if m else None


def album_key(artist: str, album: str) -> str:
    return f"{artist}_{album}".replace("/", "_").replace("\\", "_")


# ------------------------------------------------------------------ index ---
def rebuild(catalog: Dict[str, Any], catalog_mtime: float) -> int:
    """Replace the tracks table from the catalog. Keeps added_ts for tracks that were already known."""
    with _lock:
        c = _db()
        known = {r["track_id"]: r["added_ts"] for r in c.execute("SELECT track_id, added_ts FROM tracks")}
        now = time.time()
        rows = []
        for artist in catalog.get("artists", []):
            an = artist.get("name", "Unknown Artist")
            for album in artist.get("albums", []):
                aln = album.get("name", "Unknown Album")
                key = album_key(an, aln)
                year = _year_of(aln)
                for t in album.get("tracks", []):
                    tid = str(t.get("track_id") or t.get("id") or "")
                    if not tid:
                        continue
                    rows.append((tid, t.get("title") or t.get("file_name") or tid, an, aln, key, t.get("track_num"),
                                 t.get("format"), t.get("bit_depth"), t.get("sample_rate_hz"), t.get("duration_s"), year,
                                 t.get("rel_path"), t.get("gdrive_file_id"), t.get("file_name"), t.get("size_mb"),
                                 known.get(tid, now if known else (t.get("added_ts") or now))))
        c.execute("DELETE FROM tracks")
        c.executemany("INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
        if _has_fts():
            c.execute("DELETE FROM tracks_fts")
            c.executemany("INSERT INTO tracks_fts(track_id, title, artist, album) VALUES (?,?,?,?)",
                          [(r[0], r[1], r[2], r[3]) for r in rows])
        c.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('catalog_mtime', ?)", (str(catalog_mtime),))
        c.commit()
        return len(rows)


def needs_rebuild(catalog_mtime: float) -> bool:
    with _lock:
        r = _db().execute("SELECT v FROM meta WHERE k='catalog_mtime'").fetchone()
        n = _db().execute("SELECT COUNT(*) AS n FROM tracks").fetchone()["n"]
        return (not r) or abs(float(r["v"]) - catalog_mtime) > 0.5 or n == 0


def _row(r: sqlite3.Row) -> Dict[str, Any]:
    d = dict(r)
    d["cover_rel"] = f"covers/{d.get('album_key')}.jpg"
    return d


def count() -> int:
    with _lock:
        return _db().execute("SELECT COUNT(*) AS n FROM tracks").fetchone()["n"]


# ----------------------------------------------------------------- search ---
def search(q: str, limit: int = 50) -> List[Dict[str, Any]]:
    q = (q or "").strip()
    if not q:
        return []
    with _lock:
        c = _db()
        if _has_fts():
            terms = [w for w in re.findall(r"\w+", q) if w]
            if not terms:
                return []
            match = " ".join(f'"{w}"*' for w in terms)
            try:
                rows = c.execute(
                    "SELECT t.* FROM tracks_fts f JOIN tracks t ON t.track_id = f.track_id WHERE tracks_fts MATCH ? "
                    "ORDER BY bm25(tracks_fts, 0, 2.0, 1.5, 1.0) LIMIT ?", (match, limit)).fetchall()
                return [_row(r) for r in rows]
            except sqlite3.OperationalError:
                pass
        like = f"%{q.lower()}%"
        rows = c.execute("SELECT * FROM tracks WHERE lower(title) LIKE ? OR lower(artist) LIKE ? OR lower(album) LIKE ? LIMIT ?",
                         (like, like, like, limit)).fetchall()
        return [_row(r) for r in rows]


# ------------------------------------------------------------- browse views ---
def albums(sort: str = "name", limit: int = 2000) -> List[Dict[str, Any]]:
    order = {"name": "album COLLATE NOCASE", "artist": "artist COLLATE NOCASE, year", "year": "year DESC, album", "added": "added DESC"}.get(sort, "album COLLATE NOCASE")
    with _lock:
        rows = _db().execute(
            "SELECT album_key, album, artist, year, COUNT(*) AS track_count, MAX(added_ts) AS added, MIN(track_id) AS first_track "
            f"FROM tracks GROUP BY album_key ORDER BY {order} LIMIT ?", (limit,)).fetchall()
    return [{**dict(r), "cover_rel": f"covers/{r['album_key']}.jpg"} for r in rows]


def album_tracks(key: str) -> List[Dict[str, Any]]:
    with _lock:
        rows = _db().execute("SELECT * FROM tracks WHERE album_key = ? ORDER BY track_num, title", (key,)).fetchall()
    return [_row(r) for r in rows]


def decades() -> List[Dict[str, Any]]:
    with _lock:
        rows = _db().execute(
            "SELECT (year/10)*10 AS decade, COUNT(*) AS track_count, COUNT(DISTINCT album_key) AS album_count "
            "FROM tracks WHERE year IS NOT NULL GROUP BY decade ORDER BY decade DESC").fetchall()
    return [dict(r) for r in rows]


def decade_tracks(decade: int, limit: int = 60, shuffle: bool = True) -> List[Dict[str, Any]]:
    with _lock:
        rows = _db().execute(
            f"SELECT * FROM tracks WHERE year >= ? AND year < ? ORDER BY {'RANDOM()' if shuffle else 'artist, album, track_num'} LIMIT ?",
            (decade, decade + 10, limit)).fetchall()
    return [_row(r) for r in rows]


# --------------------------------------------------------------- play log ---
def record_play(track_id: str, completed: bool = False, skipped: bool = False, listened_s: float = 0.0) -> None:
    tid = str(track_id).replace("hifi_", "")
    with _lock:
        c = _db()
        c.execute("INSERT INTO plays(track_id, ts, completed, skipped, listened_s) VALUES (?,?,?,?,?)",
                  (tid, time.time(), 1 if completed else 0, 1 if skipped else 0, float(listened_s or 0)))
        c.commit()


def stats(track_id: str) -> Dict[str, Any]:
    tid = str(track_id).replace("hifi_", "")
    with _lock:
        r = _db().execute(
            "SELECT COUNT(*) AS plays, SUM(completed) AS completed, SUM(skipped) AS skipped, MAX(ts) AS last_ts, SUM(listened_s) AS listened_s "
            "FROM plays WHERE track_id = ?", (tid,)).fetchone()
    return {k: (r[k] or 0) for k in r.keys()}


def affinity(track_id: str) -> float:
    """Multiplier for the autoplay weights: finished plays lift, recent skips sink, never-heard is neutral."""
    s = stats(track_id)
    plays, done, skipped = int(s["plays"]), int(s["completed"]), int(s["skipped"])
    if plays == 0:
        return 1.0
    f = 1.0 + 0.25 * min(done, 6) - 0.45 * min(skipped, 4)
    return max(0.15, min(2.5, f))


def affinity_map() -> Dict[str, float]:
    """affinity() for every track with a play log entry, in one query (used by the autoplay weighting)."""
    with _lock:
        rows = _db().execute("SELECT track_id, SUM(completed) AS done, SUM(skipped) AS skipped FROM plays GROUP BY track_id").fetchall()
    out = {}
    for r in rows:
        f = 1.0 + 0.25 * min(int(r["done"] or 0), 6) - 0.45 * min(int(r["skipped"] or 0), 4)
        out[r["track_id"]] = max(0.15, min(2.5, f))
    return out


def heavy_rotation(days: int = 30, limit: int = 50) -> List[Dict[str, Any]]:
    since = time.time() - days * 86400
    with _lock:
        rows = _db().execute(
            "SELECT t.*, COUNT(p.id) AS n FROM plays p JOIN tracks t ON t.track_id = p.track_id "
            "WHERE p.ts > ? AND p.skipped = 0 GROUP BY t.track_id ORDER BY n DESC, MAX(p.ts) DESC LIMIT ?", (since, limit)).fetchall()
    return [_row(r) for r in rows]


def rediscover(quiet_days: int = 45, limit: int = 50) -> List[Dict[str, Any]]:
    """Tracks you clearly liked (2+ finished plays) but have not heard for a while."""
    cutoff = time.time() - quiet_days * 86400
    with _lock:
        rows = _db().execute(
            "SELECT t.*, SUM(p.completed) AS done, MAX(p.ts) AS last_ts FROM plays p JOIN tracks t ON t.track_id = p.track_id "
            "GROUP BY t.track_id HAVING done >= 2 AND last_ts < ? ORDER BY done DESC, RANDOM() LIMIT ?", (cutoff, limit)).fetchall()
    return [_row(r) for r in rows]


def never_played(limit: int = 50) -> List[Dict[str, Any]]:
    with _lock:
        rows = _db().execute(
            "SELECT t.* FROM tracks t LEFT JOIN plays p ON p.track_id = t.track_id WHERE p.id IS NULL ORDER BY RANDOM() LIMIT ?", (limit,)).fetchall()
    return [_row(r) for r in rows]


def listening_summary(days: int = 30) -> Dict[str, Any]:
    since = time.time() - days * 86400
    with _lock:
        c = _db()
        tot = c.execute("SELECT COUNT(*) AS plays, SUM(listened_s) AS secs, SUM(skipped) AS skips FROM plays WHERE ts > ?", (since,)).fetchone()
        artists = c.execute(
            "SELECT t.artist, COUNT(*) AS n FROM plays p JOIN tracks t ON t.track_id = p.track_id WHERE p.ts > ? AND p.skipped = 0 "
            "GROUP BY t.artist ORDER BY n DESC LIMIT 5", (since,)).fetchall()
    return {"days": days, "plays": tot["plays"] or 0, "hours": round((tot["secs"] or 0) / 3600.0, 1), "skips": tot["skips"] or 0,
            "top_artists": [dict(a) for a in artists]}
