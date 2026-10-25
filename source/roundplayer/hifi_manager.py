#!/usr/bin/env python3
"""
Round Media Player - Hi-Fi Lossless Music Manager & On-Demand LRU Cache
Expanded 10 GB cache ceiling with 8 GB pruning trigger threshold.
Permanent local album artwork caching in /data/hifi_music/covers/.
Re-entrant lock (RLock) to prevent deadlocks.
Auto-locates local files on disk for instant zero-delay playback.
"""

import os
import sys
import re
import json
import time
import shutil
import hashlib
import requests
import subprocess
import threading
from urllib.parse import urljoin
from pathlib import Path
from typing import Dict, List, Optional, Any, Tuple
from collections import defaultdict
import numpy as np

# Storage & Directory Constants
HIFI_DIR = "/data/hifi_music"
CACHE_DIR = "/data/hifi_cache"
COVERS_DIR = os.path.join(HIFI_DIR, "covers")
MANIFEST_FILE = os.path.join(CACHE_DIR, "manifest.json")
CATALOG_FILE = os.path.join(HIFI_DIR, "remote_library.json")
LOCAL_LEGACY_CACHE = os.path.join(HIFI_DIR, "library_cache.json")

# Cache Limits (10 GB Maximum, 8 GB Pruning Trigger Watermark)
CACHE_MAX_BYTES = 10 * 1024 * 1024 * 1024       # 10.0 GB
PRUNE_TRIGGER_BYTES = 8 * 1024 * 1024 * 1024    # 8.0 GB High Watermark
PRUNE_TARGET_BYTES = int(6.5 * 1024 * 1024 * 1024)  # 6.5 GB Safe Headroom

GOOGLE_DRIVE_FOLDER_ID = os.environ.get("ROUNDPLAYER_GDRIVE_FOLDER_ID", "")
AUDIO_EXTS = {".flac", ".wav", ".alac", ".aiff", ".m4a", ".mp3", ".ogg", ".dsf", ".dff"}
COVER_NAMES = ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png"]

_lock = threading.RLock()

def init_dirs():
    """Ensure directory hierarchy exists."""
    os.makedirs(HIFI_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(COVERS_DIR, exist_ok=True)

def load_manifest() -> Dict[str, Any]:
    """Loads cache manifest tracking file access and sizes."""
    if os.path.isfile(MANIFEST_FILE):
        try:
            with open(MANIFEST_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def save_manifest(manifest: Dict[str, Any]):
    """Saves cache manifest atomically."""
    temp_file = MANIFEST_FILE + ".tmp"
    try:
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)
        shutil.move(temp_file, MANIFEST_FILE)
    except Exception as e:
        print(f"[Manifest Write Error] {e}")

def get_cache_stats() -> Dict[str, Any]:
    """Returns current cache disk metrics."""
    with _lock:
        manifest = load_manifest()
        total_bytes = 0
        file_count = 0
        
        if os.path.isdir(CACHE_DIR):
            for root, _, files in os.walk(CACHE_DIR):
                for f in files:
                    if f.endswith(".json") or f.endswith(".tmp"):
                        continue
                    fp = os.path.join(root, f)
                    try:
                        total_bytes += os.path.getsize(fp)
                        file_count += 1
                    except Exception:
                        pass

        return {
            "total_bytes": total_bytes,
            "total_mb": round(total_bytes / (1024 * 1024), 2),
            "total_gb": round(total_bytes / (1024 * 1024 * 1024), 3),
            "max_gb": round(CACHE_MAX_BYTES / (1024 * 1024 * 1024), 1),
            "trigger_gb": round(PRUNE_TRIGGER_BYTES / (1024 * 1024 * 1024), 1),
            "target_gb": round(PRUNE_TARGET_BYTES / (1024 * 1024 * 1024), 1),
            "cached_tracks": len([k for k in manifest.keys() if not k.startswith("_")]),
            "file_count": file_count,
        }

def check_and_prune_cache(exclude_track_id: Optional[str] = None):
    """
    LRU Eviction: If total cache >= 8.0 GB, prunes least recently accessed
    files until cache drops below 6.5 GB. Currently active track is preserved.
    """
    with _lock:
        stats = get_cache_stats()
        current_bytes = stats["total_bytes"]
        if current_bytes < PRUNE_TRIGGER_BYTES:
            return

        print(f"[Cache Prune] Cache is {stats['total_gb']:.2f} GB >= 8.0 GB limit. Pruning oldest tracks...")
        manifest = load_manifest()
        
        items = []
        for tid, data in manifest.items():
            if tid == exclude_track_id or not isinstance(data, dict):
                continue
            items.append((tid, data.get("last_accessed", 0), data.get("file_path"), data.get("beats_path")))
        
        items.sort(key=lambda x: x[1])
        
        bytes_freed = 0
        for tid, _, fpath, bpath in items:
            if current_bytes - bytes_freed <= PRUNE_TARGET_BYTES:
                break
            
            if fpath and os.path.isfile(fpath) and fpath.startswith(CACHE_DIR):
                try:
                    fsize = os.path.getsize(fpath)
                    os.remove(fpath)
                    bytes_freed += fsize
                    print(f"  [Pruned] {os.path.basename(fpath)} ({fsize / (1024*1024):.1f} MB)")
                except Exception as e:
                    print(f"  [Prune Error] {fpath}: {e}")
                    
            if bpath and os.path.isfile(bpath) and bpath.startswith(CACHE_DIR):
                try:
                    os.remove(bpath)
                except Exception:
                    pass
                    
            del manifest[tid]

        save_manifest(manifest)
        print(f"[Cache Prune] Freed {bytes_freed / (1024*1024):.1f} MB.")

def locate_local_track_file(track: Dict[str, Any]) -> Optional[str]:
    """Finds if this track exists locally in /data/hifi_cache or /data/hifi_music."""
    clean_id = track.get("track_id", "")
    # 1. Direct cache check
    for ext in AUDIO_EXTS:
        target = os.path.join(CACHE_DIR, f"{clean_id}{ext}")
        if os.path.isfile(target) and os.path.getsize(target) > 1000:
            return target

    # 2. Check track's stored file_path
    fp = track.get("file_path")
    if fp and os.path.isfile(fp) and os.path.getsize(fp) > 1000:
        return fp

    # 3. Check relative path in HIFI_DIR and HIFI_DIR/HIFI
    rel = track.get("rel_path")
    if rel:
        for prefix in [HIFI_DIR, os.path.join(HIFI_DIR, "HIFI")]:
            c = os.path.join(prefix, rel)
            if os.path.isfile(c) and os.path.getsize(c) > 1000:
                return c

    # 4. Match by file_name inside artist/album folder
    fname = track.get("file_name")
    artist = track.get("artist")
    album = track.get("album")
    if fname and artist and album:
        for base in [HIFI_DIR, os.path.join(HIFI_DIR, "HIFI")]:
            for album_folder in [album, album.split(" - ")[-1] if " - " in album else album]:
                candidate = os.path.join(base, artist, album_folder, fname)
                if os.path.isfile(candidate) and os.path.getsize(candidate) > 1000:
                    return candidate

    return None

def is_track_cached(track_id: str) -> bool:
    """Checks if audio file exists locally and is non-empty."""
    clean_id = track_id.replace("hifi_", "")
    track = find_track_by_id(clean_id)
    if track:
        local = locate_local_track_file(track)
        if local:
            return True
    return False

def get_track_file_path(track_id: str) -> Optional[str]:
    """Returns local path to audio file if available."""
    clean_id = track_id.replace("hifi_", "")
    track = find_track_by_id(clean_id)
    if track:
        return locate_local_track_file(track)
    return None

def fetch_cover_from_itunes(artist: str, album: str, dest_path: str) -> bool:
    """Queries iTunes Search API to fetch 600x600 album artwork."""
    try:
        clean_album = album.split(" - ")[-1] if " - " in album else album
        clean_album = clean_album.replace("(deluxe edition)", "").replace("(Deluxe)", "").strip()
        query = f"{artist} {clean_album}"
        url = f"https://itunes.apple.com/search?term={requests.utils.quote(query)}&entity=album&limit=3"
        resp = requests.get(url, timeout=8)
        if resp.status_code == 200:
            data = resp.json()
            results = data.get("results", [])
            if results:
                art_url = results[0].get("artworkUrl100", "").replace("100x100bb.jpg", "600x600bb.jpg")
                if art_url:
                    img_resp = requests.get(art_url, timeout=10)
                    if img_resp.status_code == 200 and len(img_resp.content) > 1024:
                        with open(dest_path, "wb") as f:
                            f.write(img_resp.content)
                        return True
    except Exception as e:
        print(f"  [Art Fetch Error] {artist} - {album}: {e}")
    return False

def sync_album_art():
    """Permanent local collection of all album covers into COVERS_DIR."""
    init_dirs()
    print("[Album Art] Scanning and permanently indexing album artwork...")
    
    for root, dirs, files in os.walk(HIFI_DIR):
        if root.startswith(COVERS_DIR) or root.startswith(CACHE_DIR):
            continue
        rel = os.path.relpath(root, HIFI_DIR)
        parts = [p for p in rel.split(os.sep) if p and p != "HIFI"]
        if len(parts) >= 2:
            artist = parts[0]
            album = " - ".join(parts[1:])
            key = f"{artist}_{album}".replace("/", "_").replace("\\", "_")
            dest = os.path.join(COVERS_DIR, f"{key}.jpg")
            
            if not os.path.isfile(dest):
                for f in files:
                    if f.lower() in COVER_NAMES:
                        src = os.path.join(root, f)
                        try:
                            shutil.copy2(src, dest)
                            break
                        except Exception:
                            pass
                            
def find_album_by_key(key: str) -> Optional[Tuple[str, str, Dict[str, Any]]]:
    """(artist, album, album_dict) for an 'Artist_Album' cover key."""
    catalog = load_raw_catalog()
    for a in catalog.get("artists", []):
        artist = a["name"]
        for alb in a.get("albums", []):
            album = alb["name"]
            curr_key = f"{artist}_{album}".replace("/", "_").replace("\\", "_")
            if curr_key == key:
                return artist, album, alb
    return None


def _cover_from_embedded(album: Dict[str, Any], dest: str) -> bool:
    """Many FLAC/MP3 files carry their own picture: pull it from any cached track of the album (needs mutagen)."""
    try:
        from mutagen import File as MutagenFile  # type: ignore
    except Exception:
        return False
    for t in album.get("tracks", []):
        try:
            path = locate_local_track_file(t) if isinstance(t, dict) else None
            if not path:
                continue
            mf = MutagenFile(path)
            data = None
            if mf is None:
                continue
            pics = getattr(mf, "pictures", None)           # FLAC
            if pics:
                data = pics[0].data
            elif hasattr(mf, "tags") and mf.tags is not None:
                for k, v in mf.tags.items():               # ID3 APIC / MP4 covr
                    if k.startswith("APIC") and hasattr(v, "data"):
                        data = v.data; break
                    if k == "covr" and v:
                        data = bytes(v[0]); break
            if data and len(data) > 2048:
                with open(dest, "wb") as f:
                    f.write(data)
                return True
        except Exception:
            continue
    return False


def _clean_album_name(album: str) -> str:
    """'2024 - Radical Optimism' -> 'Radical Optimism'; drops '(Deluxe)' style tails that hurt search."""
    import re as _re
    a = _re.sub(r"^\s*\d{4}\s*[-–]\s*", "", album or "")                       # "2024 - Title"
    a = _re.sub(r"\s*[\(\[]\s*(19|20)\d\d\s*[\)\]]", "", a)                  # "Title [1968]"
    a = _re.sub(r"\s*[\(\[](deluxe|remaster|expanded|edition|bonus|anniversary|explicit|flac|mp3|24.?bit|hi.?res)[^\)\]]*[\)\]]", "", a, flags=_re.I)
    a = _re.sub(r"\b(flac|mp3|wav|alac|dsd|24bit|16bit|96khz|44khz|hi-?res|lossless)\b", "", a, flags=_re.I)
    a = _re.sub(r"\s*[\(\[][^\)\]]*$", "", a)                                    # truncated "(Austra" tails
    a = _re.sub(r"\s{2,}", " ", a)
    return a.strip(" -–_")


def _cover_from_web(artist: str, album: str, dest: str) -> bool:
    """Public cover lookups that need no API key: iTunes Search, then Deezer. Saves a ~1200 px JPEG."""
    import urllib.parse
    q = f"{artist} {_clean_album_name(album)}".strip()
    if not q:
        return False
    ua = {"User-Agent": "RoundPlayer/1.0 (+raspberry pi media player)"}
    try:
        r = requests.get("https://itunes.apple.com/search", params={"term": q, "entity": "album", "limit": 3}, headers=ua, timeout=6)
        if r.ok:
            for item in r.json().get("results", []):
                url = item.get("artworkUrl100")
                if url:
                    url = url.replace("100x100bb", "1200x1200bb")
                    img = requests.get(url, headers=ua, timeout=8)
                    if img.ok and len(img.content) > 4096:
                        with open(dest, "wb") as f:
                            f.write(img.content)
                        return True
    except Exception as e:
        print(f"[Cover] iTunes lookup failed for {q!r}: {e}")
    try:
        r = requests.get("https://api.deezer.com/search/album", params={"q": q, "limit": 3}, headers=ua, timeout=6)
        if r.ok:
            for item in r.json().get("data", []):
                url = item.get("cover_xl") or item.get("cover_big")
                if url:
                    img = requests.get(url, headers=ua, timeout=8)
                    if img.ok and len(img.content) > 4096:
                        with open(dest, "wb") as f:
                            f.write(img.content)
                        return True
    except Exception as e:
        print(f"[Cover] Deezer lookup failed for {q!r}: {e}")
    # Last resort for bootlegs / odd album names: the artist's own picture (Deezer search is forgiving of typos)
    try:
        r = requests.get("https://api.deezer.com/search/artist", params={"q": artist, "limit": 1}, headers=ua, timeout=6)
        if r.ok:
            for item in r.json().get("data", []):
                url = item.get("picture_xl") or item.get("picture_big")
                if url:
                    img = requests.get(url, headers=ua, timeout=8)
                    if img.ok and len(img.content) > 4096:
                        with open(dest, "wb") as f:
                            f.write(img.content)
                        print(f"[Cover] using artist picture for {artist} - {album}")
                        return True
    except Exception as e:
        print(f"[Cover] Deezer artist lookup failed for {artist!r}: {e}")
    return False


_cover_locks: Dict[str, threading.Lock] = {}
_cover_locks_guard = threading.Lock()


def resolve_cover(key: Optional[str] = None, rel_path: Optional[str] = None, track_id: Optional[str] = None) -> Optional[str]:
    """Path of an album cover, fetching it once if needed: local file -> Drive -> embedded picture -> iTunes/Deezer.
    A miss leaves '<key>.none' next to the covers so the lookups are not repeated for a week. Blocking: call in a thread."""
    if track_id:
        t = find_track_by_id(track_id.replace("hifi_", ""))
        if t:
            key = key or os.path.basename(t.get("cover_rel", "")).rsplit(".jpg", 1)[0]
    if rel_path and not key:
        full = os.path.join(HIFI_DIR, rel_path)
        if os.path.isfile(full):
            return full
        key = os.path.basename(rel_path).rsplit(".jpg", 1)[0]
    if not key:
        return None
    os.makedirs(COVERS_DIR, exist_ok=True)
    dest = os.path.join(COVERS_DIR, f"{key}.jpg")
    if os.path.isfile(dest) and os.path.getsize(dest) > 1024:
        return dest
    miss = dest[:-4] + ".none"
    if os.path.isfile(miss) and time.time() - os.path.getmtime(miss) < 7 * 86400:
        return None
    with _cover_locks_guard:
        lock = _cover_locks.setdefault(key, threading.Lock())
    with lock:
        if os.path.isfile(dest) and os.path.getsize(dest) > 1024:
            return dest
        found = find_album_by_key(key)
        artist, album, alb = found if found else ("", "", {})
        cover_id = alb.get("cover_gdrive_id") if alb else None
        if cover_id:
            try:
                r = requests.get(f"https://drive.usercontent.google.com/download?id={cover_id}&export=download", timeout=8)
                if r.ok and len(r.content) > 1024 and "text/html" not in (r.headers.get("content-type") or ""):
                    with open(dest, "wb") as f:
                        f.write(r.content)
                    return dest
            except Exception:
                pass
        if alb and _cover_from_embedded(alb, dest):
            print(f"[Cover] embedded picture used for {key}")
            return dest
        if artist and _cover_from_web(artist, album, dest):
            print(f"[Cover] fetched online for {artist} - {album}")
            return dest
        try:
            open(miss, "w").close()
        except OSError:
            pass
        return None


def find_cover_gdrive_id_by_key(key: str) -> Optional[str]:
    """Finds Google Drive file ID for an album cover by artist_album key."""
    catalog = load_raw_catalog()
    for a in catalog.get("artists", []):
        artist = a["name"]
        for alb in a.get("albums", []):
            album = alb["name"]
            curr_key = f"{artist}_{album}".replace("/", "_").replace("\\", "_")
            if curr_key == key:
                return alb.get("cover_gdrive_id")
    return None


def get_or_create_beats(filepath: str) -> Dict[str, Any]:
    """Generates Aubio beat onset timestamps and BPM for rhythmic synchronization."""
    beats_path = filepath + ".beats.npy"
    if os.path.isfile(beats_path):
        try:
            beats = np.load(beats_path).tolist()
            if len(beats) > 1:
                diffs = np.diff(beats)
                median_interval = np.median(diffs)
                bpm = round(60.0 / median_interval, 1) if median_interval > 0 else 120.0
            else:
                bpm = 120.0
            return {"beats": beats, "bpm": bpm, "count": len(beats)}
        except Exception:
            pass

    try:
        cmd = ["aubioonset", "-i", filepath, "-t", "0.3"]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if res.returncode == 0:
            lines = res.stdout.strip().splitlines()
            beats = [float(line.strip()) for line in lines if line.strip()]
            np.save(beats_path, np.array(beats, dtype=np.float32))
            if len(beats) > 1:
                diffs = np.diff(beats)
                median_interval = np.median(diffs)
                bpm = round(60.0 / median_interval, 1) if median_interval > 0 else 120.0
            else:
                bpm = 120.0
            return {"beats": beats, "bpm": bpm, "count": len(beats)}
    except Exception as e:
        print(f"[Aubio Error] {filepath}: {e}")

    return {"beats": [], "bpm": 120.0, "count": 0}

class CancelledDownload(Exception):
    """Raised when a foreground download was superseded by a newer play request."""


class _Download:
    """One in-flight Google Drive download, shared by everyone who asks for the same track."""
    __slots__ = ("track_id", "done", "downloaded", "total", "error", "result", "cancel", "foreground", "started")

    def __init__(self, track_id: str, foreground: bool):
        self.track_id = track_id
        self.done = threading.Event()
        self.downloaded = 0
        self.total = 0
        self.error: Optional[BaseException] = None
        self.result: Optional[Dict[str, Any]] = None
        self.cancel = False
        self.foreground = foreground
        self.started = time.time()


_inflight: Dict[str, _Download] = {}
_inflight_lock = threading.Lock()


def _cleanup_partials() -> None:
    try:
        for name in os.listdir(CACHE_DIR):
            if name.endswith(".part"):
                try:
                    os.remove(os.path.join(CACHE_DIR, name))
                except OSError:
                    pass
    except OSError:
        pass


_cleanup_partials()


def cancel_download(track_id: str) -> bool:
    """Cancel an in-flight *foreground* download (a background pre-cache keeps going)."""
    clean_id = track_id.replace("hifi_", "")
    with _inflight_lock:
        dl = _inflight.get(clean_id)
    if dl and dl.foreground and not dl.done.is_set():
        dl.cancel = True
        return True
    return False


def download_progress(track_id: str) -> Optional[Tuple[int, int]]:
    clean_id = track_id.replace("hifi_", "")
    with _inflight_lock:
        dl = _inflight.get(clean_id)
    return (dl.downloaded, dl.total) if dl else None


def _open_gdrive_stream(sess: requests.Session, download_url: str) -> requests.Response:
    """
    Initiates a streaming GET request to Google Drive, automatically detecting
    and confirming the large-file virus scan warning form/token if returned.
    """
    resp = sess.get(download_url, stream=True, timeout=(15, 60))
    resp.raise_for_status()
    ctype = (resp.headers.get("content-type") or "").lower()
    if "text/html" not in ctype:
        return resp

    # Google Drive returns an HTML confirmation prompt for files > 100 MB
    html = resp.text
    resp.close()

    # Strategy 1: Look for download form with hidden inputs (id, export, confirm, uuid)
    form_m = re.search(r'<form[^>]+id=["\']download-form["\'][^>]*>(.*?)</form>', html, re.DOTALL | re.IGNORECASE)
    if not form_m:
        form_m = re.search(r'<form[^>]+action=["\']([^"\']+)["\'][^>]*>(.*?)</form>', html, re.DOTALL | re.IGNORECASE)

    if form_m:
        action_m = re.search(r'action=["\']([^"\']+)["\']', form_m.group(0), re.IGNORECASE)
        action_url = urljoin(download_url, action_m.group(1)) if action_m else download_url
        params = {}
        for inp in re.findall(r'<input[^>]+>', form_m.group(0)):
            name_m = re.search(r'name=["\']([^"\']+)["\']', inp, re.IGNORECASE)
            val_m = re.search(r'value=["\']([^"\']*)["\']', inp, re.IGNORECASE)
            if name_m:
                params[name_m.group(1)] = val_m.group(1) if val_m else ""
        if params:
            print(f"[On-Demand Download] Submitting Google Drive confirmation form with params: {list(params.keys())}")
            resp2 = sess.get(action_url, params=params, stream=True, timeout=(15, 60))
            resp2.raise_for_status()
            if "text/html" not in (resp2.headers.get("content-type") or "").lower():
                return resp2
            html = resp2.text
            resp2.close()

    # Strategy 2: Look for <a> tag with confirmation link
    link_m = re.search(r'<a[^>]+id=["\']uc-download-link["\'][^>]+href=["\']([^"\']+)["\']', html, re.IGNORECASE)
    if not link_m:
        link_m = re.search(r'href=["\']([^"\']+[?&]confirm=[^"\']+)["\']', html, re.IGNORECASE)
    if link_m:
        link_url = urljoin(download_url, link_m.group(1).replace("&amp;", "&"))
        print("[On-Demand Download] Following Google Drive confirmation link...")
        resp2 = sess.get(link_url, stream=True, timeout=(15, 60))
        resp2.raise_for_status()
        if "text/html" not in (resp2.headers.get("content-type") or "").lower():
            return resp2
        resp2.close()

    # Strategy 3: Check cookies for download_warning token
    for k, v in sess.cookies.items():
        if k.startswith("download_warning"):
            print("[On-Demand Download] Retrying with download_warning cookie confirm token...")
            resp2 = sess.get(download_url, params={"confirm": v}, stream=True, timeout=(15, 60))
            resp2.raise_for_status()
            if "text/html" not in (resp2.headers.get("content-type") or "").lower():
                return resp2
            resp2.close()

    raise RuntimeError("Google Drive answered with a web page instead of the file (sharing / quota / virus-scan confirmation could not be resolved)")


def _run_download(dl: _Download, track: Dict[str, Any], cached_dest: str) -> None:
    part_dest = cached_dest + ".part"
    file_id = track.get("gdrive_file_id") or track.get("file_id")
    try:
        if not file_id:
            raise ValueError(f"No Google Drive file ID available for track {dl.track_id}")
        fake_dir = os.environ.get("HIFI_FAKE_DRIVE")   # tests: "download" = slow copy from this directory
        if fake_dir:
            src = os.path.join(fake_dir, track.get("file_name") or f"{dl.track_id}.flac")
            dl.total = os.path.getsize(src)
            with open(src, "rb") as fin, open(part_dest, "wb") as f:
                while True:
                    if dl.cancel:
                        raise CancelledDownload(dl.track_id)
                    chunk = fin.read(64 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
                    dl.downloaded += len(chunk)
                    time.sleep(float(os.environ.get("HIFI_FAKE_DRIVE_DELAY", "0.02")))
            shutil.move(part_dest, cached_dest)
            with _lock:
                manifest = load_manifest()
                manifest[dl.track_id] = {"last_accessed": time.time(), "size_bytes": os.path.getsize(cached_dest),
                                         "file_path": cached_dest, "beats_path": cached_dest + ".beats.npy"}
                save_manifest(manifest)
            dl.result = {"cached": True, "file_path": cached_dest, "track_id": dl.track_id}
            return
        download_url = f"https://drive.usercontent.google.com/download?id={file_id}&export=download"
        print(f"[On-Demand Download] Downloading {track.get('title')} ({track.get('artist')}) from {download_url}...")
        sess = requests.Session()
        sess.headers.update({
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        })
        with _open_gdrive_stream(sess, download_url) as resp:
            resp.raise_for_status()
            ctype = (resp.headers.get("content-type") or "").lower()
            if "text/html" in ctype:
                raise RuntimeError("Google Drive answered with a web page instead of the file (sharing / quota / virus-scan page)")
            dl.total = int(resp.headers.get("content-length", 0))
            with open(part_dest, "wb") as f:
                for chunk in resp.iter_content(chunk_size=256 * 1024):
                    if dl.cancel:
                        raise CancelledDownload(dl.track_id)
                    if chunk:
                        f.write(chunk)
                        dl.downloaded += len(chunk)
        if not (os.path.isfile(part_dest) and os.path.getsize(part_dest) > 1000):
            raise RuntimeError(f"Download failed or empty file for {dl.track_id}")
        shutil.move(part_dest, cached_dest)
        print(f"[On-Demand Download] Saved {cached_dest} ({os.path.getsize(cached_dest)/(1024*1024):.1f} MB)")
        with _lock:
            manifest = load_manifest()
            manifest[dl.track_id] = {
                "last_accessed": time.time(),
                "size_bytes": os.path.getsize(cached_dest),
                "file_path": cached_dest,
                "beats_path": cached_dest + ".beats.npy"
            }
            save_manifest(manifest)
        dl.result = {"cached": True, "file_path": cached_dest, "track_id": dl.track_id}
    except BaseException as e:  # noqa: BLE001 - must always release the waiters
        dl.error = e
        try:
            if os.path.isfile(part_dest):
                os.remove(part_dest)
        except OSError:
            pass
        if isinstance(e, CancelledDownload):
            print(f"[On-Demand Download] Cancelled {dl.track_id}")
        else:
            print(f"[On-Demand Download] Failed {dl.track_id}: {e}")
    finally:
        with _inflight_lock:
            if _inflight.get(dl.track_id) is dl:
                del _inflight[dl.track_id]
        dl.done.set()


def ensure_track_cached(track_id: str, progress_callback=None, foreground: bool = False,
                        cancel_check=None, with_beats: bool = True) -> Dict[str, Any]:
    """
    Ensures the track is on disk and returns {"cached", "file_path", "track_id", "beats"?}.

    - Already local: returns immediately (beats computed inline only when with_beats).
    - Otherwise downloads from Google Drive. Concurrent callers for the same track share ONE download
      (the HUD, the web remote, the pre-cacher and the stream endpoint used to race three copies).
    - progress_callback(downloaded, total) is called ~4x/s while waiting.
    - foreground=True marks the download cancellable via cancel_download(); cancel_check() returning
      True makes *this caller* stop waiting (raises CancelledDownload) without touching the download.
    - with_beats=False skips aubio (10-30 s on a Pi 4): the caller runs it in the background.
    """
    track = find_track_by_id(track_id)
    if not track:
        raise ValueError(f"Track {track_id} not found in catalog")

    clean_id = track["track_id"]
    local_file = locate_local_track_file(track)

    # 1. Already on disk
    if local_file and os.path.isfile(local_file) and os.path.getsize(local_file) > 1000:
        with _lock:
            manifest = load_manifest()
            manifest[clean_id] = {
                "last_accessed": time.time(),
                "size_bytes": os.path.getsize(local_file),
                "file_path": local_file,
                "beats_path": local_file + ".beats.npy"
            }
            save_manifest(manifest)
        out = {"cached": True, "file_path": local_file, "track_id": clean_id}
        if with_beats:
            out["beats"] = get_or_create_beats(local_file)
        return out

    # 2. Join or start the download
    ext = os.path.splitext(track.get("file_name") or track.get("rel_path") or ".flac")[1].lower()
    if ext not in AUDIO_EXTS:
        ext = ".flac"
    cached_dest = os.path.join(CACHE_DIR, f"{clean_id}{ext}")

    with _inflight_lock:
        dl = _inflight.get(clean_id)
        if dl is None:
            dl = _Download(clean_id, foreground)
            _inflight[clean_id] = dl
            threading.Thread(target=_run_download, args=(dl, track, cached_dest),
                             daemon=True, name=f"hifi_dl_{clean_id}").start()
        elif foreground:
            dl.foreground = True   # a pre-cache the user now actually wants: make it cancellable like any foreground one
            dl.cancel = False

    while not dl.done.wait(0.25):
        if progress_callback:
            progress_callback(dl.downloaded, dl.total)
        if cancel_check and cancel_check():
            raise CancelledDownload(clean_id)
    if dl.error is not None:
        raise dl.error
    if progress_callback and dl.total:
        progress_callback(dl.total, dl.total)

    check_and_prune_cache(exclude_track_id=clean_id)
    out = dict(dl.result or {"cached": True, "file_path": cached_dest, "track_id": clean_id})
    if with_beats:
        out["beats"] = get_or_create_beats(out["file_path"])
    return out

def trigger_background_precache(track_id: str):
    """Asynchronously pre-downloads upcoming track in low-priority background thread."""
    if not track_id:
        return
    clean_id = track_id.replace("hifi_", "")
    if is_track_cached(clean_id):
        return
    def _worker():
        try:
            print(f"[HiFi Preloader] Pre-caching upcoming track: {clean_id}")
            ensure_track_cached(clean_id, with_beats=False)   # beats are computed when it actually plays
            print(f"[HiFi Preloader] Successfully pre-cached: {clean_id}")
        except Exception as e:
            print(f"[HiFi Preloader] Pre-cache error for {clean_id}: {e}")
    t = threading.Thread(target=_worker, daemon=True, name=f"precache_{clean_id}")
    t.start()

_catalog_cache: Dict[str, Any] = {"path": None, "mtime": 0.0, "data": None}


def load_raw_catalog() -> Dict[str, Any]:
    """Loads either remote_library.json or library_cache.json - cached in memory by file mtime (every lookup used
    to re-read and re-parse the whole JSON). A changed catalog also rebuilds the SQLite index (library_db)."""
    for p in [CATALOG_FILE, LOCAL_LEGACY_CACHE]:
        if os.path.isfile(p):
            try:
                mtime = os.path.getmtime(p)
                with _lock:
                    if _catalog_cache["data"] is not None and _catalog_cache["path"] == p and _catalog_cache["mtime"] == mtime:
                        return _catalog_cache["data"]
                with open(p, "r", encoding="utf-8") as f:
                    data = json.load(f)
                with _lock:
                    _catalog_cache.update(path=p, mtime=mtime, data=data)
                try:
                    import library_db
                    if library_db.needs_rebuild(mtime):
                        n = library_db.rebuild(data, mtime)
                        print(f"[Library] index rebuilt: {n} tracks")
                except Exception as e:
                    print(f"[Library] index rebuild failed: {e}")
                return data
            except Exception:
                pass
    return {"artists": [], "total_tracks": 0, "total_albums": 0, "total_artists": 0}

def scan_library(force: bool = False) -> Dict[str, Any]:
    """
    Returns the full hierarchical catalog with `is_cached` status annotated on each track
    and guaranteed permanent local album covers.
    """
    catalog = load_raw_catalog()
    
    for artist in catalog.get("artists", []):
        for album in artist.get("albums", []):
            artist_name = artist["name"]
            album_name = album["name"]
            key = f"{artist_name}_{album_name}".replace("/", "_").replace("\\", "_")
            album["cover_rel"] = f"covers/{key}.jpg"
            
            for track in album.get("tracks", []):
                local = locate_local_track_file(track)
                track["is_cached"] = bool(local is not None)
                if local:
                    track["file_path"] = local

    return catalog

def find_track_by_id(track_id: str) -> Optional[Dict[str, Any]]:
    """Looks up track metadata by track_id from cached catalog."""
    clean_id = track_id.replace("hifi_", "")
    catalog = load_raw_catalog()
    for artist in catalog.get("artists", []):
        for album in artist.get("albums", []):
            for track in album.get("tracks", []):
                if track.get("track_id") == clean_id or track.get("id") == clean_id:
                    artist_name = artist["name"]
                    album_name = album["name"]
                    key = f"{artist_name}_{album_name}".replace("/", "_").replace("\\", "_")
                    track["cover_rel"] = f"covers/{key}.jpg"
                    track["cover_path"] = os.path.join(COVERS_DIR, f"{key}.jpg")
                    local = locate_local_track_file(track)
                    if local:
                        track["file_path"] = local
                        track["is_cached"] = True
                    else:
                        track["is_cached"] = False
                    return track
    return None

def get_flat_tracks() -> List[Dict[str, Any]]:
    """Returns a flattened list of all tracks across artists and albums."""
    catalog = load_raw_catalog()
    flat = []
    for artist in catalog.get("artists", []):
        artist_name = artist.get("name", "Unknown Artist")
        for album in artist.get("albums", []):
            album_name = album.get("name", "Unknown Album")
            for track in album.get("tracks", []):
                t = dict(track)
                t["artist"] = artist_name
                t["album"] = album_name
                flat.append(t)
    return flat

def get_album_tracks_for_track(track_id: str) -> Tuple[List[Dict[str, Any]], int]:
    """
    Finds the album that contains track_id and returns:
    (album_tracks, current_track_index_in_album)
    """
    clean_id = track_id.replace("hifi_", "")
    catalog = load_raw_catalog()
    for artist in catalog.get("artists", []):
        artist_name = artist.get("name", "Unknown Artist")
        for album in artist.get("albums", []):
            album_name = album.get("name", "Unknown Album")
            tracks = album.get("tracks", [])
            for idx, t in enumerate(tracks):
                if t.get("track_id") == clean_id or t.get("id") == clean_id:
                    enriched = []
                    for item in tracks:
                        c = dict(item)
                        c["artist"] = artist_name
                        c["album"] = album_name
                        c["cover_key"] = f"{artist_name}_{album_name}".replace("/", "_").replace("\\", "_")
                        enriched.append(c)
                    return enriched, idx
    return [], -1

def search_library(query: str, limit: int = 50) -> List[Dict[str, Any]]:
    """
    Fast ranked search across all Hi-Fi artists, albums, and track titles.
    Returns enriched track items with cover art URLs and cache status.
    """
    q0 = (query or "").strip()
    if q0:
        # SQLite FTS first (instant, prefix matching, diacritics-insensitive); the JSON walk below is the fallback
        try:
            import library_db
            load_raw_catalog()   # ensures the index exists / is current
            hits = library_db.search(q0, limit=limit)
            if hits:
                out = []
                for t in hits:
                    item = dict(t)
                    item["key"] = t["album_key"]
                    item["cover_url"] = f"/api/hifi/cover?key={t['album_key']}"
                    item["is_cached"] = is_track_cached(t["track_id"])
                    out.append(item)
                return out
        except Exception as e:
            print(f"[Library] fts search failed, falling back: {e}")
    catalog = scan_library()
    q = (query or "").strip().lower()
    matches = []

    for artist in catalog.get("artists", []):
        artist_name = artist.get("name", "")
        a_low = artist_name.lower()
        for album in artist.get("albums", []):
            album_name = album.get("name", "")
            alb_low = album_name.lower()
            key = f"{artist_name}_{album_name}".replace("/", "_").replace("\\", "_")
            cover_url = f"/api/hifi/cover?key={key}"
            cover_rel = f"covers/{key}.jpg"

            for track in album.get("tracks", []):
                t_title = track.get("title", "")
                t_low = t_title.lower()
                f_name = track.get("file_name", "").lower()

                # If query is empty, return initial catalog tracks
                if not q:
                    item = dict(track)
                    item["artist"] = artist_name
                    item["album"] = album_name
                    item["key"] = key
                    item["cover_rel"] = cover_rel
                    item["cover_url"] = cover_url
                    matches.append(item)
                    if len(matches) >= limit:
                        return matches
                    continue

                # Check match priority
                priority = None
                if q == t_low:
                    priority = 1
                elif t_low.startswith(q):
                    priority = 2
                elif q in t_low:
                    priority = 3
                elif q == a_low or a_low.startswith(q):
                    priority = 4
                elif q in a_low:
                    priority = 5
                elif q in alb_low:
                    priority = 6
                elif q in f_name:
                    priority = 7

                if priority is not None:
                    item = dict(track)
                    item["artist"] = artist_name
                    item["album"] = album_name
                    item["key"] = key
                    item["cover_rel"] = cover_rel
                    item["cover_url"] = cover_url
                    item["_priority"] = priority
                    matches.append(item)

    if q:
        matches.sort(key=lambda x: (x.get("_priority", 99), x.get("artist", "").lower(), x.get("title", "").lower()))
        for m in matches:
            m.pop("_priority", None)

    return matches[:limit]

if __name__ == "__main__":
    init_dirs()
    print("[Hi-Fi Manager] Synchronizing permanent covers...")
    sync_album_art()
    stats = get_cache_stats()
    print(f"[Hi-Fi Manager] Cache Status: {stats['total_mb']} MB / {stats['max_gb']} GB (Prune Trigger: {stats['trigger_gb']} GB)")
