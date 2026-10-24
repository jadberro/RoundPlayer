"""
similar.py - "keep playing music like this" for the Hi-Fi library.

Signals (no genre tags in the catalog, so we build them):
  * related artists from Deezer's public API (artist search -> /artist/{id}/related), cached on disk for 30 days,
    matched against the library by normalised name
  * same artist (other albums first), same decade (year parsed from the album name), same format family
  * a recently-played window so radio does not loop
Everything is cheap: one Deezer call per artist, ever; selection is a weighted draw over the flat catalog.
"""
import json, os, random, re, threading, time
from typing import Any, Dict, List, Optional, Tuple

import requests

import hifi_manager

RELATED_FILE = "/data/hifi_related.json"
RELATED_TTL = 30 * 86400
_lock = threading.Lock()
_related: Dict[str, Dict[str, Any]] = {}
_UA = {"User-Agent": "RoundPlayer/1.0 (+raspberry pi media player)"}


def _norm(name: str) -> str:
    n = re.sub(r"[^a-z0-9]+", " ", (name or "").lower()).strip()
    n = re.sub(r"^(the|a|an) ", "", n)
    return n


def _load():
    global _related
    if _related:
        return
    try:
        _related = json.load(open(RELATED_FILE))
    except Exception:
        _related = {}


def _save():
    try:
        tmp = RELATED_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_related, f)
        os.replace(tmp, RELATED_FILE)
    except Exception:
        pass


def related_artists(artist: str, fetch: bool = True) -> List[str]:
    """Names of related artists (Deezer), cached. Empty list when unknown/offline."""
    key = _norm(artist)
    if not key:
        return []
    with _lock:
        _load()
        ent = _related.get(key)
        if ent and time.time() - ent.get("ts", 0) < RELATED_TTL:
            return list(ent.get("names", []))
    if not fetch:
        return []
    names: List[str] = []
    try:
        r = requests.get("https://api.deezer.com/search/artist", params={"q": artist, "limit": 1}, headers=_UA, timeout=6)
        data = r.json().get("data", []) if r.ok else []
        if data:
            aid = data[0]["id"]
            r2 = requests.get(f"https://api.deezer.com/artist/{aid}/related", params={"limit": 40}, headers=_UA, timeout=6)
            if r2.ok:
                names = [x.get("name", "") for x in r2.json().get("data", []) if x.get("name")]
    except Exception as e:
        print(f"[Similar] related lookup failed for {artist!r}: {e}")
    with _lock:
        _related[key] = {"ts": time.time(), "names": names, "artist": artist}
        _save()
    return names


def _year_of(album: str) -> Optional[int]:
    m = re.search(r"(19|20)\d\d", album or "")
    return int(m.group(0)) if m else None


def _format_family(t: Dict[str, Any]) -> str:
    fmt = str(t.get("format") or "").upper()
    return "lossless" if fmt in ("FLAC", "ALAC", "WAV", "AIFF", "DSF", "DFF", "DSD") else "lossy"


def similar_tracks(seed_id: str, limit: int = 50, exclude: Optional[List[str]] = None, fetch: bool = True) -> Dict[str, Any]:
    """Weighted selection of library tracks that go with the seed. Returns {"name", "seed", "tracks"}."""
    seed = hifi_manager.find_track_by_id(seed_id.replace("hifi_", ""))
    flat = hifi_manager.get_flat_tracks()
    if not seed or not flat:
        return {"name": "Similar", "seed": None, "tracks": []}
    seed_artist = seed.get("artist", "")
    seed_norm = _norm(seed_artist)
    related = {_norm(n) for n in related_artists(seed_artist, fetch=fetch)}
    seed_year = _year_of(seed.get("album", ""))
    seed_fam = _format_family(seed)
    excl = {x.replace("hifi_", "") for x in (exclude or [])}
    excl.add(seed["track_id"])

    try:
        import library_db
        aff = library_db.affinity_map()   # finished plays lift a track, recent skips sink it
    except Exception:
        aff = {}
    weighted: List[Tuple[float, Dict[str, Any]]] = []
    for t in flat:
        tid = str(t.get("track_id") or "")
        if not tid or tid in excl:
            continue
        a = _norm(t.get("artist", ""))
        w = 0.0
        if a == seed_norm:
            w += 3.0 if t.get("album") != seed.get("album") else 1.5   # other albums of the same artist first
        if a in related:
            w += 4.0
        y = _year_of(t.get("album", ""))
        if seed_year and y and abs(y - seed_year) <= 7:
            w += 1.0
        if _format_family(t) == seed_fam:
            w += 0.5
        if w > 0:
            weighted.append((w * aff.get(tid, 1.0), t))

    # If the signals are thin (artist unknown to Deezer, odd library), widen to the same decade, then to everything
    if len(weighted) < limit:
        pool = [t for t in flat if str(t.get("track_id")) not in excl and all(t is not w[1] for w in weighted)]
        random.shuffle(pool)
        for t in pool[: max(0, limit * 2 - len(weighted))]:
            weighted.append((0.2, t))

    picks: List[Dict[str, Any]] = []
    seen_albums: Dict[str, int] = {}
    items = weighted[:]
    while items and len(picks) < limit:
        total = sum(w for w, _ in items)
        r = random.uniform(0, total)
        acc = 0.0
        for i, (w, t) in enumerate(items):
            acc += w
            if acc >= r:
                album = t.get("album", "")
                if seen_albums.get(album, 0) >= 3 and len(items) > 1:   # spread across albums
                    items.pop(i)
                    break
                seen_albums[album] = seen_albums.get(album, 0) + 1
                picks.append(t)
                items.pop(i)
                break
    if not picks and exclude:
        # Small library or long history: allow older repeats rather than returning nothing
        shorter = list(exclude)[-10:] if len(exclude) > 10 else []
        return similar_tracks(seed_id, limit=limit, exclude=shorter, fetch=fetch)
    name = f"Like {seed.get('title', 'this')}"
    return {"name": name, "seed": {"track_id": seed["track_id"], "title": seed.get("title"), "artist": seed_artist}, "tracks": picks}


def artist_radio(artist: str, limit: int = 50, exclude: Optional[List[str]] = None, fetch: bool = True) -> Dict[str, Any]:
    flat = hifi_manager.get_flat_tracks()
    own = [t for t in flat if _norm(t.get("artist", "")) == _norm(artist)]
    seed = own[0] if own else None
    if not seed:
        return {"name": f"{artist} radio", "seed": None, "tracks": []}
    out = similar_tracks(str(seed["track_id"]), limit=limit, exclude=exclude, fetch=fetch)
    out["name"] = f"{artist} radio"
    return out
