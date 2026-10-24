#!/usr/bin/env python3
"""
Round Media Player - Master Playback Manager & Ingestion Engine (Raspberry Pi 4 + DAC Pro)
Media orchestration, deterministic caching, 60 Hz Unix domain telemetry, and DAC coordination.
"""

import os
import sys
import json
import time
import re
import math
import asyncio
import subprocess
import threading
import shutil
import colorsys
import urllib.request
import urllib.error
import glob
from datetime import datetime, timezone
from typing import List, Dict, Optional, Set, Any
from collections import OrderedDict

import numpy as np
from collections import deque as _deque


class _TeeLog:
    """Keeps the last 300 lines the daemon printed so Settings → Diagnostics can show them without journal access."""
    def __init__(self, stream):
        self.stream = stream
        self.lines = _deque(maxlen=300)
        self._buf = ""

    def write(self, data):
        try:
            self.stream.write(data)
        except Exception:
            pass
        self._buf += data
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            if line.strip() and "/api/hud/state" not in line and "GET /api/state" not in line:
                self.lines.append(f"{time.strftime('%H:%M:%S')} {line}")

    def flush(self):
        try:
            self.stream.flush()
        except Exception:
            pass

    def isatty(self):
        return False


_log_ring = _TeeLog(sys.stdout)
sys.stdout = _log_ring
sys.stderr = _TeeLog(sys.stderr)
sys.stderr.lines = _log_ring.lines
try:
    import aubio
    HAS_AUBIO = True
except Exception as _e:  # beat analysis is a nice-to-have; never block playback on it
    aubio = None
    HAS_AUBIO = False
    print("[Beats] aubio unavailable, BPM analysis disabled:", _e)
import yt_dlp
import network_manager
import ytmusicapi
import hifi_manager
import hifi_playlists
import library_db
import mqtt_bridge
import yt_stream
from PIL import Image
from pydantic import BaseModel
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware

# Directories & Sockets
CACHE_DIR = "/data/roundplayer_cache"
TEMP_DIR = "/tmp/roundplayer_temp"
TELEMETRY_SOCK_PATH = "/tmp/roundplayer_telemetry.sock"
MAX_CACHE_TRACKS = 35
MAX_CACHE_BYTES = 25 * 1024 * 1024 * 1024  # 25 GB

os.makedirs(CACHE_DIR, exist_ok=True)
os.makedirs(TEMP_DIR, exist_ok=True)

app = FastAPI(title="Round Media Player - Playback Manager")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Models
class TrackInfo(BaseModel):
    video_id: str
    title: str
    artist: str
    duration: Optional[str] = "0:00"
    duration_seconds: Optional[int] = 0
    bpm: Optional[float] = 103.0
    beat_count: Optional[int] = 0
    dominant_color: Optional[str] = "#00E5FF"
    source: Optional[str] = "youtube"
    thumbnail_url: Optional[str] = ""
    is_cached: bool = False
    cached_at: Optional[str] = None
    last_accessed_at: Optional[str] = None

class CacheStatus(BaseModel):
    status: str
    progress: Optional[float] = 0.0
    percent: Optional[int] = 0
    step: Optional[str] = ""
    title: Optional[str] = None
    artist: Optional[str] = None
    error: Optional[str] = None

class ControlCommand(BaseModel):
    action: str  # "play", "pause", "seek", "volume"
    value: Optional[float] = None
    seek_seconds: Optional[float] = None

class SystemState(BaseModel):
    active_video_id: Optional[str]
    title: Optional[str]
    artist: Optional[str]
    is_playing: bool
    volume: float
    current_bpm: float
    playback_position_s: float
    duration_seconds: Optional[int] = 240
    dominant_color: str
    caching_video_id: Optional[str] = None
    caching_title: Optional[str] = None
    caching_artist: Optional[str] = None
    caching_progress: Optional[Any] = None  # str step label while caching, float progress when done
    caching_percent: Optional[int] = 0
    is_hifi: Optional[bool] = False
    format: Optional[str] = None
    bit_depth: Optional[int] = None
    sample_rate_hz: Optional[int] = None
    shuffle: Optional[bool] = False
    repeat: Optional[str] = "all"
    cmd_seq: Optional[int] = 0
    hud_synced: Optional[bool] = False

# --- Playback commands ----------------------------------------------------------------------
# The HUD used to *diff* the daemon's is_playing / active_video_id against its own state at 60 Hz, which
# raced with its own local actions (pause flapping, double media opens, half-cached files). Now every
# state change issues an explicit, numbered command; the HUD applies each seq exactly once and reports
# the resulting real state back through /api/hud/state.
pending_cast_position: Dict[str, float] = {}   # video_id -> start position requested by a cast sender

# YouTube tracks that are not cached locally play from a resolved stream (yt_stream). Which mode a track uses
# (audio only for YouTube Music) is remembered here so resume / repeat / resync reload it the same way.
_yt_audio_only: Dict[str, bool] = {}


def _yt_stream_for(track_id: str) -> Optional[Dict[str, Any]]:
    try:
        key = f"{track_id}:{'a' if _yt_audio_only.get(track_id) else 'v'}"
        hit = yt_stream._cache.get(key)
        if hit and hit["expires"] - time.time() > 120:
            return hit
    except Exception:
        pass
    return None


def _issue_cmd_locked(kind: str, track_id: Optional[str] = None, source: Optional[str] = None,
                      position_s: Optional[float] = None, playing: Optional[bool] = None) -> Dict[str, Any]:
    """Call with state_lock held. kind: load | play | pause | seek | stop."""
    extra: Dict[str, Any] = {}
    if kind == "load" and source == "youtube" and track_id and not track_id.startswith("ext:") and not is_track_ready(track_id):
        st = _yt_stream_for(track_id)
        if st is None:
            # URL unknown or expired (resume after hours, resync after a restart): resolve, then issue this load
            def later(tid=track_id, pos=position_s, play=playing):
                try:
                    yt_stream.resolve(tid, audio_only=_yt_audio_only.get(tid, False), force=True)
                except Exception as e:
                    print(f"[YT stream] re-resolve failed for {tid}: {e}")
                    return
                with state_lock:
                    if runtime_state.get("active_video_id") == tid:
                        _issue_cmd_locked("load", track_id=tid, source="youtube", position_s=pos, playing=play)
            threading.Thread(target=later, daemon=True, name=f"yt_reresolve_{track_id}").start()
            return {"type": "pending", "track_id": track_id}
        extra = {"url": st["url"], "audio_only": st["audio_only"]}
    seq = int(runtime_state.get("cmd_seq", 0)) + 1
    runtime_state["cmd_seq"] = seq
    cmd = {"seq": seq, "type": kind, "track_id": track_id, "source": source,
           "position_s": position_s, "playing": playing, "ts": time.time(), **extra}
    runtime_state["cmd"] = cmd
    return cmd

def issue_cmd(kind: str, **kw) -> Dict[str, Any]:
    with state_lock:
        return _issue_cmd_locked(kind, **kw)

def _source_of(track_id: Optional[str]) -> str:
    return "hifi" if (track_id or "").startswith("hifi_") else "youtube"

def hud_synced() -> bool:
    """True when the HUD has confirmed it is on the daemon's current track in the intended play state."""
    if not hud_state_fresh():
        return False
    cmd = runtime_state.get("cmd") or {}
    want_playing = runtime_state.get("is_playing", False)
    return hud_state.get("track_id") == runtime_state.get("active_video_id") and bool(hud_state.get("is_playing")) == bool(want_playing) \
        and (cmd.get("type") != "load" or hud_state.get("track_id") == cmd.get("track_id"))

# Real playback state reported by the HUD (mpv) - preferred over the wall-clock estimate when fresh
hud_state: Dict[str, Any] = {"ts": 0.0, "position_s": 0.0, "duration_s": 0.0, "is_playing": False,
                             "track_id": None, "audio_rate_hz": None, "audio_format": None}
HUD_STATE_FRESH_S = 3.0

def hud_state_fresh() -> bool:
    return (time.time() - hud_state.get("ts", 0.0)) < HUD_STATE_FRESH_S

def current_position_s() -> float:
    """Playback position: the HUD's real mpv position when fresh, else the wall-clock estimate."""
    if hud_state_fresh() and hud_state.get("track_id") == runtime_state.get("active_video_id"):
        return max(0.0, float(hud_state.get("position_s") or 0.0))
    if runtime_state.get("is_playing", False) and runtime_state.get("start_time"):
        pos = (time.time() - runtime_state["start_time"]) + runtime_state.get("position_offset_s", 0.0)
    elif runtime_state.get("pause_time") and runtime_state.get("start_time"):
        pos = (runtime_state["pause_time"] - runtime_state["start_time"]) + runtime_state.get("position_offset_s", 0.0)
    else:
        pos = 0.0
    return max(0.0, pos)

# Global State
state_lock = threading.Lock()
cache_tasks: Dict[str, Dict] = {}
caching_lock = threading.Lock()
target_track_id: Optional[str] = None

# Queue & History State
queue_lock = threading.Lock()
playback_queue: List[Dict[str, Any]] = []
playback_history: List[str] = []

class QueueItem(BaseModel):
    video_id: str
    title: Optional[str] = None
    artist: Optional[str] = None
    album: Optional[str] = None
    duration: Optional[str] = None
    thumbnail_url: Optional[str] = None
    source: Optional[str] = "youtube"
    position: Optional[str] = "end"
    cover_key: Optional[str] = None

    class Config:
        extra = "allow"

# The daemon always comes up in standby: a restart (or a reboot) must never resurrect a track on its own.
runtime_state = {
    "active_video_id": "standby",
    "title": "Standby",
    "artist": "",
    "album": "",
    "is_playing": False,
    "is_hifi": False,
    "audio_format": "",
    "bit_depth": 0,
    "sample_rate_hz": 0,
    "hifi_catalog_version": 1,
    "hifi_sync_status": "idle",
    "hifi_sync_message": "Ready",
    "shuffle": False,
    "repeat": "all",
    "volume": 100.0,
    "cmd_seq": 0,
    "cmd": None,
    "current_bpm": 126.2,
    "beat_period_s": 60.0 / 126.2,
    "dominant_color": "#d89c31",
    "start_time": time.time(),
    "pause_time": time.time(),
    "position_offset_s": 0.0,
    "beats": np.array([], dtype=np.float32),
}

# --- Track Directory Helpers ---

def get_track_dir(track_id: str) -> str:
    return os.path.join(CACHE_DIR, track_id)

def get_meta_path(track_id: str) -> str:
    return os.path.join(get_track_dir(track_id), "metadata.json")

def get_video_path(track_id: str) -> str:
    return os.path.join(get_track_dir(track_id), "video.mp4")

def get_audio_path(track_id: str) -> str:
    return os.path.join(get_track_dir(track_id), "audio.wav")

def get_cover_path(track_id: str) -> str:
    return os.path.join(get_track_dir(track_id), "cover.jpg")

def get_beats_path(track_id: str) -> str:
    return os.path.join(get_track_dir(track_id), "beats.npy")

def get_flag_path(track_id: str) -> str:
    return os.path.join(get_track_dir(track_id), "complete.flag")

def is_track_ready(track_id: str) -> bool:
    v_path = get_video_path(track_id)
    f_path = get_flag_path(track_id)
    return os.path.isfile(f_path) and os.path.isfile(v_path) and os.path.getsize(v_path) > 1024

def activate_track_sync(video_id: str) -> dict:
    meta_path = get_meta_path(video_id)
    try:
        with open(meta_path, 'r', encoding='utf-8') as f:
            meta = json.load(f)
        
        # Update last_accessed_at for LRU
        meta["last_accessed_at"] = datetime.now(timezone.utc).isoformat()
        try:
            with open(meta_path, 'w', encoding='utf-8') as f:
                json.dump(meta, f, indent=2)
        except Exception:
            pass

        bpm = float(meta.get("bpm", 126.2))
        color = meta.get("dominant_color", "#00E5FF")
        title = meta.get("title", "Unknown")
        artist = meta.get("artist", "Unknown")

        beats_path = get_beats_path(video_id)
        if os.path.exists(beats_path):
            try:
                beats_arr = np.load(beats_path)
            except Exception:
                beats_arr = np.array([], dtype=np.float32)
        else:
            beats_arr = np.array([], dtype=np.float32)

        with state_lock:
            runtime_state["active_video_id"] = video_id
            runtime_state["current_bpm"] = bpm
            runtime_state["beat_period_s"] = 60.0 / bpm if bpm > 0 else 60.0 / 103.0
            runtime_state["dominant_color"] = color
            runtime_state["title"] = title
            runtime_state["artist"] = artist
            runtime_state["album"] = ""
            runtime_state["is_playing"] = True
            runtime_state["is_hifi"] = False
            runtime_state["audio_only"] = False
            runtime_state["audio_format"] = "AAC"
            runtime_state["bit_depth"] = 16
            runtime_state["sample_rate_hz"] = 48000
            runtime_state["start_time"] = time.time()
            _start_pos = float(pending_cast_position.pop(video_id, 0.0) or 0.0)
            runtime_state["position_offset_s"] = _start_pos
            _issue_cmd_locked("load", track_id=video_id, source="youtube", position_s=_start_pos, playing=True)
            runtime_state["pause_time"] = None
            runtime_state["position_offset_s"] = 0.0
            runtime_state["beats"] = beats_arr

        print(f"[PlaybackManager] Activated track: {video_id} ('{title}' by {artist}, BPM {bpm})")
        _note_played(video_id, title, artist, "", False)

        with queue_lock:
            if not playback_history or playback_history[-1] != video_id:
                playback_history.append(video_id)
            if playback_queue and playback_queue[0].get("video_id") == video_id:
                playback_queue.pop(0)
            if playback_queue:
                next_vid = playback_queue[0].get("video_id")
                if next_vid and not is_track_ready(next_vid):
                    threading.Thread(target=run_caching_pipeline, args=(next_vid,), daemon=True).start()

        return {
            "status": "playing",
            "video_id": video_id,
            "bpm": bpm,
            "dominant_color": color,
            "title": title,
            "artist": artist
        }
    except Exception as e:
        print(f"[PlaybackManager] Error activating track {video_id}: {e}")
        return {"status": "error", "message": str(e)}

# --- Hi-Fi: non-blocking "prepare then play" ------------------------------------------------------
# Every play request (any source) bumps prep_gen. A Hi-Fi track that is not on disk is downloaded in a
# worker thread; when it finishes it only activates if prep_gen is still its own - a newer request
# (another Hi-Fi track, a YouTube cast, stop/idle) silently retires it and cancels the foreground
# download. Progress is published through cache_tasks[...] exactly like the YouTube pipeline, so the
# telemetry packet carries caching_video_id / caching_percent / caching_progress for the HUD and remote.
prep_gen = 0


# ---- Resume across reboots + recently played -------------------------------------------------------------
RESUME_FILE = "/data/roundplayer_resume.json" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "roundplayer_resume.json")
HISTORY_FILE = "/data/roundplayer_history.json" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "roundplayer_history.json")
_resume_last_write = 0.0
_history_lock = threading.Lock()


def _snapshot_now_locked() -> Optional[Dict[str, Any]]:
    """What is on right now, in the shape /api/resume reloads. Caller holds state_lock."""
    active = runtime_state.get("active_video_id")
    if not active or active == "standby":
        return None
    return {"track_id": active, "position_s": current_position_s(), "title": runtime_state.get("title"),
            "artist": runtime_state.get("artist"), "album": runtime_state.get("album"), "is_hifi": runtime_state.get("is_hifi", False),
            "audio_format": runtime_state.get("audio_format"), "bit_depth": runtime_state.get("bit_depth"),
            "sample_rate_hz": runtime_state.get("sample_rate_hz"), "dominant_color": runtime_state.get("dominant_color"),
            "duration_seconds": runtime_state.get("duration_seconds", 0), "audio_only": bool(runtime_state.get("audio_only")), "ts": time.time()}


def _write_json_atomic(path: str, data: Any) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def _save_resume(snapshot: Optional[Dict[str, Any]]) -> None:
    """Remember the last track + position on disk so a reboot (or power cut) still resumes where you were."""
    global _resume_last_write
    try:
        if snapshot is None:
            return
        _write_json_atomic(RESUME_FILE, snapshot)
        _resume_last_write = time.time()
    except Exception as e:
        print(f"[Resume] save failed: {e}")


def _load_resume() -> Optional[Dict[str, Any]]:
    try:
        d = json.load(open(RESUME_FILE))
        if d.get("track_id") and d["track_id"] != "standby":
            if d["track_id"].startswith("hifi_") and not hifi_manager.find_track_by_id(d["track_id"][5:]):
                return None   # the library changed under it
            return d
    except Exception:
        pass
    return None


def _note_played(track_id: str, title: str, artist: str, album: str, is_hifi: bool) -> None:
    """Recently played: newest first, one entry per track, 200 max. Cheap enough to do on every activation."""
    def work():
        with _history_lock:
            try:
                hist = json.load(open(HISTORY_FILE))
                if not isinstance(hist, list):
                    hist = []
            except Exception:
                hist = []
            hist = [h for h in hist if h.get("track_id") != track_id]
            hist.insert(0, {"track_id": track_id, "title": title, "artist": artist, "album": album, "is_hifi": is_hifi, "ts": time.time()})
            try:
                _write_json_atomic(HISTORY_FILE, hist[:200])
            except Exception as e:
                print(f"[History] save failed: {e}")
    threading.Thread(target=work, daemon=True).start()


def recently_played(limit: int = 30) -> List[Dict[str, Any]]:
    with _history_lock:
        try:
            hist = json.load(open(HISTORY_FILE))
        except Exception:
            return []
    out = []
    for h in hist:
        if not isinstance(h, dict):
            continue
        tid = str(h.get("track_id", ""))
        if tid.startswith("hifi_"):
            t = hifi_manager.find_track_by_id(tid[5:])
            if not t:
                continue   # gone from the library
            out.append({**h, "track": t})
        else:
            out.append(h)
        if len(out) >= limit:
            break
    return out


def _enter_idle_locked() -> None:
    """Stop playback and remember what was on, so /api/resume can bring it back paused at the same spot."""
    active = runtime_state.get("active_video_id")
    if active and active != "standby":
        runtime_state["last_idle_track"] = {"track_id": active, "position_s": current_position_s(),
                                            "title": runtime_state.get("title"), "artist": runtime_state.get("artist"),
                                            "album": runtime_state.get("album"), "is_hifi": runtime_state.get("is_hifi", False),
                                            "audio_format": runtime_state.get("audio_format"), "bit_depth": runtime_state.get("bit_depth"),
                                            "sample_rate_hz": runtime_state.get("sample_rate_hz"), "dominant_color": runtime_state.get("dominant_color"),
                                            "duration_seconds": runtime_state.get("duration_seconds", 0), "audio_only": bool(runtime_state.get("audio_only"))}
        _save_resume(runtime_state["last_idle_track"])
    _issue_cmd_locked("stop", playing=False)
    runtime_state["is_playing"] = False
    runtime_state["pause_time"] = time.time()
    runtime_state["active_video_id"] = "standby"
    runtime_state["title"] = "Standby"
    runtime_state["artist"] = ""
    runtime_state["caching_video_id"] = None
    runtime_state["caching_title"] = None
    runtime_state["caching_artist"] = None
    with caching_lock:
        for tid, tinfo in cache_tasks.items():
            if isinstance(tinfo, dict) and tinfo.get("status") not in ["ready", "error"]:
                tinfo["status"] = "canceled"


def resume_from_idle() -> dict:
    """Bring the last track back, paused, at the position it was stopped (the 'wake' tap after sleep)."""
    with state_lock:
        last = runtime_state.get("last_idle_track")
        if runtime_state.get("active_video_id") != "standby":
            return {"status": "ok", "resumed": False, "active": runtime_state.get("active_video_id")}
        if not last:
            return {"status": "ok", "resumed": False}
        tid = last["track_id"]
        _supersede_preparing_locked(tid)
        for k in ("title", "artist", "album", "is_hifi", "audio_format", "bit_depth", "sample_rate_hz", "dominant_color", "duration_seconds", "audio_only"):
            if last.get(k) is not None:
                runtime_state[k] = last[k]
        if not tid.startswith("hifi_"):
            _yt_audio_only.setdefault(tid, bool(last.get("audio_only")))
        runtime_state["active_video_id"] = tid
        runtime_state["is_playing"] = False
        runtime_state["pause_time"] = time.time()
        runtime_state["start_time"] = time.time()
        runtime_state["position_offset_s"] = float(last.get("position_s") or 0.0)
        _issue_cmd_locked("load", track_id=tid, source=_source_of(tid), position_s=float(last.get("position_s") or 0.0), playing=False)
    return {"status": "ok", "resumed": True, "track_id": tid}


def _supersede_preparing_locked(new_id: Optional[str]) -> int:
    """Called under state_lock by every play/stop request: retire whatever is being prepared."""
    global prep_gen, target_track_id
    prep_gen += 1
    if new_id != runtime_state.get("cast_track_id"):
        runtime_state["cast_track_id"] = None
    cur = runtime_state.get("caching_video_id")
    if cur and cur != new_id:
        if cur.startswith("hifi_"):
            hifi_manager.cancel_download(cur)
        runtime_state["caching_video_id"] = None
        runtime_state["caching_title"] = None
        runtime_state["caching_artist"] = None
        task = cache_tasks.get(cur)
        if task and task.get("status") in ("downloading", "preparing"):
            task["status"] = "canceled"
            task["step"] = "Canceled"
    if new_id is None or not new_id.startswith("hifi_"):
        pass
    else:
        target_track_id = None   # a pending YouTube cache must not auto-play over this Hi-Fi request
    return prep_gen


def _hifi_track_summary(track: dict, clean_id: str) -> dict:
    return {
        "track_id": f"hifi_{clean_id}",
        "title": track.get("title", "Unknown Title"),
        "artist": track.get("artist", "Unknown Artist"),
        "album": track.get("album", "Unknown Album"),
        "is_hifi": True,
        "format": track.get("format") or "FLAC",
        "bit_depth": track.get("bit_depth", 16) or 16,
        "sample_rate_hz": track.get("sample_rate_hz", 44100) or 44100,
        "stream_url": f"/media/hifi/{clean_id}/stream",
    }


def _hifi_background_beats(clean_id: str, file_path: str) -> None:
    """aubio onset analysis takes 10-30 s on a Pi 4: run it after playback has started and patch the live state."""
    try:
        beats_info = hifi_manager.get_or_create_beats(file_path) or {}
    except Exception as e:
        print(f"[Hi-Fi Beats] {clean_id}: {e}")
        return
    beats = beats_info.get("beats") or []
    bpm = float(beats_info.get("bpm", 0) or 0)
    with state_lock:
        if runtime_state.get("active_video_id") == f"hifi_{clean_id}":
            runtime_state["beats"] = np.array(beats, dtype=np.float32)
            if bpm > 0:
                runtime_state["current_bpm"] = bpm
                runtime_state["beat_period_s"] = 60.0 / bpm


def _activate_hifi_ready(clean_id: str, track: dict, file_path: str, position_s: float = 0.0, issue_load: bool = True) -> dict:
    """The file is on disk: make it the active track and tell the HUD to load it. Never blocks on I/O > a few ms."""
    beats_path = file_path + ".beats.npy"
    beats_arr = np.array([], dtype=np.float32)
    bpm = 0.0
    if os.path.isfile(beats_path):
        try:
            beats_arr = np.load(beats_path).astype(np.float32)
            if len(beats_arr) > 1:
                med = float(np.median(np.diff(beats_arr)))
                bpm = round(60.0 / med, 1) if med > 0 else 0.0
        except Exception:
            beats_arr = np.array([], dtype=np.float32)
    if bpm <= 0:
        bpm = 120.0
        threading.Thread(target=_hifi_background_beats, args=(clean_id, file_path), daemon=True,
                         name=f"hifi_beats_{clean_id}").start()

    dominant_color = "#F59E0B"
    if track.get("cover_path") and os.path.isfile(track["cover_path"]):
        try:
            dominant_color = extract_dominant_color(track["cover_path"])
        except Exception:
            pass
    else:
        # No cover yet: resolve it (embedded picture / online lookup) in the background and tint the UI when it lands
        def _late_cover(cid=clean_id):
            try:
                path = hifi_manager.resolve_cover(track_id=cid)
                if path:
                    col = extract_dominant_color(path)
                    with state_lock:
                        if runtime_state.get("active_video_id") == f"hifi_{cid}":
                            runtime_state["dominant_color"] = col
            except Exception as e:
                print(f"[Cover] late resolve failed for {cid}: {e}")
        threading.Thread(target=_late_cover, daemon=True, name=f"cover_{clean_id}").start()

    full_id = f"hifi_{clean_id}"
    summary = _hifi_track_summary(track, clean_id)
    with state_lock:
        runtime_state["active_video_id"] = full_id
        runtime_state["title"] = summary["title"]
        runtime_state["artist"] = summary["artist"]
        runtime_state["album"] = summary["album"]
        runtime_state["is_playing"] = True
        runtime_state["is_hifi"] = True
        runtime_state["audio_only"] = False
        runtime_state["audio_format"] = summary["format"]
        runtime_state["bit_depth"] = summary["bit_depth"]
        runtime_state["sample_rate_hz"] = summary["sample_rate_hz"]
        runtime_state["current_bpm"] = bpm
        runtime_state["beat_period_s"] = 60.0 / bpm
        runtime_state["dominant_color"] = dominant_color
        runtime_state["start_time"] = time.time() - position_s
        runtime_state["pause_time"] = None
        runtime_state["position_offset_s"] = 0.0
        runtime_state["beats"] = beats_arr
        runtime_state["duration_seconds"] = int(track.get("duration_s") or 0)   # HUD reports the real one
        if runtime_state.get("caching_video_id") == full_id:
            runtime_state["caching_video_id"] = None
            runtime_state["caching_title"] = None
            runtime_state["caching_artist"] = None
        cache_tasks[full_id] = {"status": "ready", "progress": 1.0, "percent": 100, "step": "Ready", "error": None}
        if issue_load:
            _issue_cmd_locked("load", track_id=full_id, source="hifi", position_s=position_s, playing=True)
        else:
            _supersede_preparing_locked(full_id)   # gapless: mpv already moved on by itself; just adopt it

    print(f"[Hi-Fi Playback] Activated: {summary['title']} by {summary['artist']} "
          f"[{summary['format']} {summary['bit_depth']}b/{summary['sample_rate_hz']}Hz, BPM {bpm}]")
    _note_played(full_id, summary["title"], summary["artist"], summary.get("album", ""), True)

    with queue_lock:
        if not playback_history or playback_history[-1] != full_id:
            playback_history.append(full_id)

    preload_upcoming_hifi_track(clean_id)
    _warm_related(summary["artist"])
    out = {"status": "playing", "bpm": bpm, "dominant_color": dominant_color}
    out.update(summary)
    return out


def _hifi_prepare_worker(clean_id: str, track: dict, gen: int) -> None:
    full_id = f"hifi_{clean_id}"
    task = cache_tasks[full_id]

    def still_current() -> bool:
        return prep_gen == gen

    def on_progress(downloaded: int, total: int) -> None:
        if total > 0:
            pct = int(downloaded * 100 / total)
            task["percent"] = max(1, min(99, pct))
            task["progress"] = max(0.01, min(0.99, downloaded / total))
            task["step"] = f"Downloading {pct}%  ·  {downloaded / 1048576:.1f} / {total / 1048576:.1f} MB"
        else:
            task["step"] = f"Downloading  ·  {downloaded / 1048576:.1f} MB"

    try:
        cached = hifi_manager.ensure_track_cached(clean_id, progress_callback=on_progress, foreground=True,
                                                  cancel_check=lambda: not still_current(), with_beats=False)
    except hifi_manager.CancelledDownload:
        task.update({"status": "canceled", "step": "Canceled"})
        return
    except Exception as e:
        print(f"[Hi-Fi Cache Error] {clean_id}: {e}")
        task.update({"status": "error", "step": f"Download failed: {e}", "error": str(e), "percent": 0, "progress": 0.0})
        # leave the failure on screen for a moment, then clear it (unless something else took over)
        time.sleep(4.0)
        with state_lock:
            if runtime_state.get("caching_video_id") == full_id and prep_gen == gen:
                runtime_state["caching_video_id"] = None
                runtime_state["caching_title"] = None
                runtime_state["caching_artist"] = None
        return

    with state_lock:
        current = prep_gen == gen
    if not current:
        task.update({"status": "ready", "step": "Ready", "percent": 100, "progress": 1.0})
        return
    task.update({"status": "preparing", "step": "Starting playback...", "percent": 100, "progress": 1.0})
    _activate_hifi_ready(clean_id, track, cached["file_path"])


def activate_hifi_track(track_id: str) -> dict:
    """Play a Hi-Fi track. Cached -> activates immediately ("playing"). Not cached -> returns "preparing" at once and
    the download/activation continues in the background, visible via telemetry caching_* fields. A later play request
    of any kind supersedes it cleanly."""
    clean_id = track_id.replace("hifi_", "")
    track = hifi_manager.find_track_by_id(clean_id)
    if not track:
        return {"status": "error", "message": f"Track {clean_id} not found in Hi-Fi library"}
    full_id = f"hifi_{clean_id}"

    file_path = hifi_manager.get_track_file_path(clean_id)
    if file_path and os.path.isfile(file_path) and os.path.getsize(file_path) > 1000:
        with state_lock:
            _supersede_preparing_locked(full_id)
        return _activate_hifi_ready(clean_id, track, file_path)

    with state_lock:
        if runtime_state.get("caching_video_id") == full_id and cache_tasks.get(full_id, {}).get("status") in ("downloading", "preparing"):
            out = {"status": "preparing"}
            out.update(_hifi_track_summary(track, clean_id))
            return out   # same track tapped twice: keep the download that is already running
        gen = _supersede_preparing_locked(full_id)
        runtime_state["caching_video_id"] = full_id
        runtime_state["caching_title"] = track.get("title", "Hi-Fi Audio")
        runtime_state["caching_artist"] = track.get("artist", "")
        cache_tasks[full_id] = {"status": "downloading", "progress": 0.0, "percent": 0,
                                "step": "Connecting to Google Drive...", "error": None,
                                "title": track.get("title"), "artist": track.get("artist")}
    threading.Thread(target=_hifi_prepare_worker, args=(clean_id, track, gen), daemon=True,
                     name=f"hifi_prep_{clean_id}").start()
    out = {"status": "preparing"}
    out.update(_hifi_track_summary(track, clean_id))
    return out


def cancel_preparing() -> dict:
    """Abort whatever is being prepared (HUD banner 'x', remote). The current track keeps playing."""
    with state_lock:
        cur = runtime_state.get("caching_video_id")
        _supersede_preparing_locked(None)
    return {"status": "ok", "canceled": cur}


def preload_upcoming_hifi_track(current_clean_id: str):
    """Predicts and pre-caches next track in queue or active album in background."""
    import hifi_manager
    try:
        # 1. Check queue first
        with queue_lock:
            if playback_queue:
                next_q = playback_queue[0]
                q_id = str(next_q.get("video_id") or next_q.get("track_id") or "")
                if q_id.startswith("hifi_") or next_q.get("source") == "hifi":
                    hifi_manager.trigger_background_precache(q_id.replace("hifi_", ""))
                    return

        # 2. Check current track's album
        album_tracks, idx = hifi_manager.get_album_tracks_for_track(current_clean_id)
        if album_tracks and idx >= 0:
            n = len(album_tracks)
            wrap = runtime_state.get("repeat") == "all"
            for step in (1, 2):   # two tracks ahead so album listening never waits on Drive
                j = idx + step
                if j >= n:
                    if not wrap:
                        break
                    j %= n
                    if j == idx:
                        continue
                next_track = album_tracks[j]
                next_id = next_track.get("track_id")
                if next_id and not next_track.get("is_cached", False):
                    hifi_manager.trigger_background_precache(next_id)
    except Exception as e:
        print(f"[HiFi Preloader] Error during preload: {e}")


# --- Cache Initialization & Migration ---

def init_existing_cache():
    """Scan /data/roundplayer_cache/ and ensure existing tracks have complete.flag and cover.jpg."""
    if not os.path.exists(CACHE_DIR):
        return
    for item in os.listdir(CACHE_DIR):
        item_path = os.path.join(CACHE_DIR, item)
        if not os.path.isdir(item_path):
            continue
        v_path = get_video_path(item)
        m_path = get_meta_path(item)
        c_path = get_cover_path(item)
        f_path = get_flag_path(item)

        if os.path.isfile(v_path) and os.path.isfile(m_path):
            # Extract cover if missing
            if not os.path.isfile(c_path):
                try:
                    subprocess.run([
                        'ffmpeg', '-y', '-ss', '00:00:05', '-i', v_path,
                        '-vframes', '1', '-vf', 'scale=512:512', c_path
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                except Exception:
                    pass
            # Mark complete if missing
            if not os.path.isfile(f_path):
                try:
                    with open(f_path, 'w') as f:
                        f.write(datetime.now(timezone.utc).isoformat())
                except Exception:
                    pass

init_existing_cache()

# --- LRU Cache Eviction ---

def get_dir_size(path: str) -> int:
    total = 0
    try:
        for entry in os.scandir(path):
            if entry.is_file():
                total += entry.stat().st_size
    except Exception:
        pass
    return total

def evict_lru_cache():
    """Evict oldest tracks by last_accessed_at if limit exceeded."""
    if not os.path.exists(CACHE_DIR):
        return
    track_dirs = []
    total_size = 0
    for item in os.listdir(CACHE_DIR):
        dir_path = get_track_dir(item)
        if not os.path.isdir(dir_path):
            continue
        m_path = get_meta_path(item)
        last_accessed = 0.0
        if os.path.isfile(m_path):
            try:
                with open(m_path, 'r', encoding='utf-8') as f:
                    meta = json.load(f)
                    ts = meta.get('last_accessed_at') or meta.get('cached_at')
                    if ts:
                        last_accessed = datetime.fromisoformat(ts).timestamp()
            except Exception:
                pass
        if last_accessed == 0.0:
            last_accessed = os.path.getmtime(dir_path)
        
        sz = get_dir_size(dir_path)
        total_size += sz
        track_dirs.append((item, last_accessed, sz))

    # Sort oldest first
    track_dirs.sort(key=lambda x: x[1])

    while len(track_dirs) > MAX_CACHE_TRACKS or total_size > MAX_CACHE_BYTES:
        oldest_id, _, sz = track_dirs.pop(0)
        with state_lock:
            if oldest_id == runtime_state.get("active_video_id"):
                continue  # Never evict currently playing track
        print(f"[LRU] Evicting cached track: {oldest_id} ({sz / (1024*1024):.1f} MB)")
        try:
            shutil.rmtree(get_track_dir(oldest_id))
            total_size -= sz
        except Exception as e:
            print(f"[LRU] Error removing {oldest_id}: {e}")

# --- Beat Detection & Color Extraction ---

def compute_beats_aubio(audio_path: str, win_s: int = 1024, hop_s: int = 512, samplerate: int = 48000):
    s = aubio.source(audio_path, samplerate, hop_s)
    tempo = aubio.tempo("default", win_s, hop_s, samplerate)
    beats = []
    total_frames = 0
    while True:
        samples, read = s()
        is_beat = tempo(samples)
        if is_beat:
            this_beat = tempo.get_last_s()
            beats.append(float(this_beat))
        total_frames += read
        if read < hop_s:
            break
    
    bpm = float(tempo.get_bpm())
    if bpm <= 0 and len(beats) > 1:
        diffs = np.diff(beats)
        median_interval = np.median(diffs)
        bpm = 60.0 / median_interval if median_interval > 0 else 103.0
    return beats, round(bpm, 1)

def extract_dominant_color(video_path: str) -> str:
    tmp_img = os.path.join(TEMP_DIR, f"thumb_{int(time.time()*1000)}.jpg")
    try:
        subprocess.run([
            'ffmpeg', '-y', '-ss', '00:00:08', '-i', video_path,
            '-vframes', '1', '-vf', 'scale=64:64', tmp_img
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        if not os.path.exists(tmp_img):
            return '#00E5FF'
        im = Image.open(tmp_img).convert('RGB')
        colors = im.getcolors(64 * 64) or []
        vibrant_candidates = []
        for count, (r, g, b) in colors:
            h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            if v > 0.20 and s > 0.15:
                score = count * (s ** 1.5) * v
                vibrant_candidates.append((score, h, s, v))
        if os.path.exists(tmp_img):
            os.remove(tmp_img)
        if vibrant_candidates:
            vibrant_candidates.sort(reverse=True, key=lambda x: x[0])
            _, h, s, v = vibrant_candidates[0]
            s = max(s, 0.70)
            v = max(v, 0.85)
            r, g, b = colorsys.hsv_to_rgb(h, s, v)
            return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"
    except Exception as e:
        if os.path.exists(tmp_img):
            os.remove(tmp_img)
    return '#00E5FF'

# --- Ingestion Pipeline Worker ---

def run_caching_pipeline(video_id: str):
    global target_track_id
    if is_track_ready(video_id):
        cache_tasks[video_id] = {
            "status": "ready", "progress": 1.0, "percent": 100, "step": "Ready", "error": None
        }
        with state_lock:
            should_play = (target_track_id == video_id)
        if should_play:
            activate_track_sync(video_id)
        return

    with caching_lock:
        if is_track_ready(video_id):
            cache_tasks[video_id] = {
                "status": "ready", "progress": 1.0, "percent": 100, "step": "Ready", "error": None
            }
            with state_lock:
                should_play = (target_track_id == video_id)
            if should_play:
                activate_track_sync(video_id)
            return

        track_dir = get_track_dir(video_id)
        os.makedirs(track_dir, exist_ok=True)
        temp_template = os.path.join(TEMP_DIR, f"{video_id}.%(ext)s")

        try:
            cache_tasks[video_id] = {
                "status": "downloading",
                "progress": 0.05,
                "percent": 5,
                "step": "Downloading 1080p HD stream...",
                "title": None,
                "artist": None,
                "error": None
            }

            def progress_hook(d):
                if d.get('status') == 'downloading':
                    total = d.get('total_bytes') or d.get('total_bytes_estimate') or 0
                    downloaded = d.get('downloaded_bytes') or 0
                    if total > 0:
                        fraction = min(max(downloaded / total, 0.0), 1.0)
                        p = 0.05 + 0.65 * fraction
                        pct = int(p * 100)
                        cache_tasks[video_id]["progress"] = round(p, 2)
                        cache_tasks[video_id]["percent"] = pct
                        cache_tasks[video_id]["step"] = f"Downloading 1080p stream ({pct}%)"

            ydl_opts = {
                # Pi 4: only H.264 can use the V4L2 hardware decoder - never fall back to VP9/AV1 video.
                'format': 'bestvideo[height<=1080][vcodec^=avc]+bestaudio[acodec^=mp4a]/bestvideo[height<=1080][vcodec^=avc]+bestaudio[ext=m4a]/best[height<=1080][vcodec^=avc]/bestaudio/best',
                'outtmpl': temp_template,
                'quiet': True,
                'no_warnings': True,
                'noplaylist': True,
                'progress_hooks': [progress_hook],
                'extractor_args': {
                    'youtube': {
                        'player_client': ['ios', 'android', 'mweb', 'web']
                    }
                },
            }
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=True)
                downloaded_ext = info.get('ext', 'mp4')
                raw_file = os.path.join(TEMP_DIR, f"{video_id}.{downloaded_ext}")
                title = info.get('title', 'Unknown Title')
                artist = info.get('artist') or info.get('uploader', 'Unknown Artist')
                duration = int(info.get('duration') or 0)
                cache_tasks[video_id]["title"] = title
                cache_tasks[video_id]["artist"] = artist

            if not os.path.exists(raw_file):
                matches = [f for f in glob.glob(os.path.join(TEMP_DIR, f"{video_id}.*")) if not f.endswith('.part')]
                if matches:
                    raw_file = matches[0]
                else:
                    raise FileNotFoundError(f"Downloaded raw file for {video_id} not found in {TEMP_DIR}")

            # Check if video stream exists
            has_video = False
            try:
                probe = subprocess.run([
                    'ffprobe', '-v', 'error', '-select_streams', 'v:0',
                    '-show_entries', 'stream=codec_name',
                    '-of', 'default=noprint_wrappers=1:nokey=1', raw_file
                ], capture_output=True, text=True, timeout=8)
                if probe.stdout.strip():
                    has_video = True
            except Exception:
                has_video = False

            video_out = get_video_path(video_id)
            audio_out = get_audio_path(video_id)
            cover_out = get_cover_path(video_id)
            beats_out = get_beats_path(video_id)
            meta_out = get_meta_path(video_id)
            flag_out = get_flag_path(video_id)

            # 1. Audio extraction (48kHz 24-bit uncompressed stereo PCM for DAC Pro)
            cache_tasks[video_id]["progress"] = 0.70
            cache_tasks[video_id]["percent"] = 70
            cache_tasks[video_id]["step"] = "Extracting uncompressed 24-bit 48kHz PCM audio"
            extract_cmd = ['ffmpeg', '-y', '-i', raw_file]
            if duration > 240:
                extract_cmd += ['-t', '180']
            extract_cmd += ['-vn', '-acodec', 'pcm_s24le', '-ar', '48000', '-ac', '2', audio_out]
            subprocess.run(extract_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

            # 2. Extract Cover Art
            cover_extracted = False
            if has_video:
                try:
                    subprocess.run([
                        'ffmpeg', '-y', '-ss', '00:00:06', '-i', raw_file,
                        '-vframes', '1', '-vf', 'scale=512:512', cover_out
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
                    if os.path.exists(cover_out) and os.path.getsize(cover_out) > 1024:
                        cover_extracted = True
                except Exception:
                    pass

            if not cover_extracted:
                thumb_url = info.get('thumbnail')
                if not thumb_url and info.get('thumbnails'):
                    thumb_url = info['thumbnails'][-1].get('url')
                if thumb_url:
                    try:
                        urllib.request.urlretrieve(thumb_url, cover_out)
                        if os.path.exists(cover_out) and os.path.getsize(cover_out) > 1024:
                            cover_extracted = True
                    except Exception:
                        pass

            if not cover_extracted or not os.path.exists(cover_out):
                im = Image.new('RGB', (512, 512), color=(14, 20, 36))
                im.save(cover_out, 'JPEG')

            # 3. Video Stream Creation
            cache_tasks[video_id]["status"] = "processing"
            cache_tasks[video_id]["progress"] = 0.80
            cache_tasks[video_id]["percent"] = 80
            cache_tasks[video_id]["step"] = "Preparing clean 1080p video stream"

            if has_video:
                remux_cmd = ['ffmpeg', '-y', '-i', raw_file, '-c', 'copy', '-movflags', '+faststart', video_out]
                res = subprocess.run(remux_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if res.returncode != 0 or not os.path.exists(video_out) or os.path.getsize(video_out) < 1024:
                    subprocess.run([
                        'ffmpeg', '-y', '-i', raw_file,
                        '-vf', 'scale=-2:1080',
                        '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23',
                        '-pix_fmt', 'yuv420p',
                        '-c:a', 'aac', '-b:a', '192k',
                        '-movflags', '+faststart', video_out
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            else:
                # Audio-only track (e.g. YouTube Music): generate clean 1080x1080 video from cover.jpg
                vid_duration = min(duration, 180) if duration > 0 else 180
                subprocess.run([
                    'ffmpeg', '-y', '-loop', '1', '-i', cover_out,
                    '-c:v', 'libx264', '-tune', 'stillimage', '-preset', 'ultrafast',
                    '-pix_fmt', 'yuv420p', '-t', str(vid_duration),
                    '-vf', 'scale=1080:1080:force_original_aspect_ratio=decrease,pad=1080:1080:(ow-iw)/2:(oh-ih)/2:color=black',
                    '-movflags', '+faststart', video_out
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

            # 4. Aubio Beat & Tempo Analysis
            cache_tasks[video_id]["progress"] = 0.88
            cache_tasks[video_id]["percent"] = 88
            cache_tasks[video_id]["step"] = "Computing Aubio beat markers & tempo"
            if HAS_AUBIO:
                beats, bpm = compute_beats_aubio(audio_out)
            else:
                beats, bpm = np.array([], dtype=np.float32), 120.0
            np.save(beats_out, np.array(beats, dtype=np.float32))

            # 5. Dominant Neon Color Extraction
            cache_tasks[video_id]["progress"] = 0.95
            cache_tasks[video_id]["percent"] = 95
            cache_tasks[video_id]["step"] = "Extracting neon dominant palette"
            dominant_color = extract_dominant_color(video_out)

            # 6. Metadata JSON Commit
            now_iso = datetime.now(timezone.utc).isoformat()
            duration_str = f"{duration // 60}:{duration % 60:02d}"
            metadata = {
                "video_id": video_id,
                "title": title,
                "artist": artist,
                "duration": duration_str,
                "duration_seconds": duration,
                "bpm": bpm,
                "beat_count": len(beats),
                "dominant_color": dominant_color,
                "source": "youtube",
                "cached_at": now_iso,
                "last_accessed_at": now_iso
            }
            with open(meta_out, 'w', encoding='utf-8') as f:
                json.dump(metadata, f, indent=2)

            # 7. Atomic Complete Flag
            with open(flag_out, 'w') as f:
                f.write(now_iso)

            # Clean raw download
            if os.path.exists(raw_file):
                os.remove(raw_file)

            cache_tasks[video_id]["status"] = "ready"
            cache_tasks[video_id]["progress"] = 1.0
            cache_tasks[video_id]["percent"] = 100
            cache_tasks[video_id]["step"] = "Ready"

            # Auto-activate if target track matches
            with state_lock:
                if runtime_state.get("caching_video_id") == video_id:
                    runtime_state["caching_video_id"] = None
                should_auto_play = (target_track_id == video_id)
            if should_auto_play:
                print(f"[Ingestion Engine] Target track ready, auto-activating: {video_id}")
                activate_track_sync(video_id)

            # Check LRU cache limit
            evict_lru_cache()

        except Exception as e:
            print(f"[Ingestion Error] {video_id}: {e}")
            cache_tasks[video_id] = {
                "status": "error", "progress": 0.0, "percent": 0, "step": "Failed", "error": str(e)
            }
            with state_lock:
                if runtime_state.get("caching_video_id") == video_id:
                    runtime_state["caching_video_id"] = None

# --- 60 Hz Unix Domain Socket Telemetry Server ---

unix_clients: Set[asyncio.StreamWriter] = set()

async def unix_socket_client_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    unix_clients.add(writer)
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            # Handle incoming IPC command if any
            try:
                cmd = json.loads(line.decode().strip())
                action = cmd.get("action")
                val = cmd.get("value")
                with state_lock:
                    if action == "play":
                        runtime_state["is_playing"] = True
                        runtime_state["pause_time"] = None
                        _issue_cmd_locked("play", track_id=runtime_state.get("active_video_id"), playing=True)
                    elif action == "pause":
                        runtime_state["is_playing"] = False
                        runtime_state["pause_time"] = time.time()
                        _issue_cmd_locked("pause", track_id=runtime_state.get("active_video_id"), playing=False)
                    elif action == "volume" and val is not None:
                        runtime_state["volume"] = float(val)
            except Exception:
                pass
    except Exception:
        pass
    finally:
        unix_clients.discard(writer)
        writer.close()

_telemetry_server = None

async def start_unix_telemetry_server():
    if os.path.exists(TELEMETRY_SOCK_PATH):
        try:
            os.remove(TELEMETRY_SOCK_PATH)
        except Exception:
            pass
    global _telemetry_server
    server = await asyncio.start_unix_server(unix_socket_client_handler, path=TELEMETRY_SOCK_PATH)
    _telemetry_server = server  # keep a reference: on Python 3.13 an unreferenced Server is closed when garbage-collected
    # Set generous socket permissions for local processes
    try:
        os.chmod(TELEMETRY_SOCK_PATH, 0o666)
    except Exception:
        pass
    print(f"[Telemetry] Unix domain socket server listening at {TELEMETRY_SOCK_PATH}")
    return server

async def telemetry_broadcaster_loop():
    """Broadcasts 60 Hz telemetry packets over Unix domain socket and WebSockets."""
    while True:
        t_now = time.time()
        timestamp_us = int(t_now * 1e6)

        with state_lock:
            live_bpm = runtime_state.get("current_bpm", 126.2)
            is_playing = runtime_state.get("is_playing", False)
            active_id = runtime_state.get("active_video_id", "standby")
            caching_id = runtime_state.get("caching_video_id")
            caching_title = runtime_state.get("caching_title")
            caching_artist = runtime_state.get("caching_artist")
            is_hifi = runtime_state.get("is_hifi", False)
            audio_format = runtime_state.get("audio_format", "AAC")
            bit_depth = runtime_state.get("bit_depth", 16)
            sample_rate_hz = runtime_state.get("sample_rate_hz", 48000)
            dominant_color = runtime_state.get("dominant_color", "#00E5FF")
            current_title = runtime_state.get("title", "")
            current_artist = runtime_state.get("artist", "")
            current_album = runtime_state.get("album", "")

        c_task = cache_tasks.get(caching_id) if caching_id else None
        c_progress = c_task.get("progress", 0.05) if c_task else 0.0
        c_percent = c_task.get("percent", 5) if c_task else 0
        if c_task and c_task.get("title") and not caching_title:
            caching_title = c_task.get("title")
        if c_task and c_task.get("artist") and not caching_artist:
            caching_artist = c_task.get("artist")

        beat_freq = (live_bpm / 60.0) if live_bpm > 0 else (103.0 / 60.0)
        phase = (t_now * beat_freq * 2.0 * np.pi) % (2.0 * np.pi) if is_playing else 0.0

        packet = {
            "timestamp_us": timestamp_us,
            "track_id": active_id,
            "bpm": round(live_bpm, 1),
            "beat_phase": round(phase / (2.0 * np.pi), 3),
            "is_playing": is_playing,
            "is_hifi": is_hifi,
            "audio_format": audio_format,
            "bit_depth": bit_depth,
            "sample_rate_hz": sample_rate_hz,
            "color": dominant_color,
            "title": current_title,
            "artist": current_artist,
            "album": current_album,
            "caching_video_id": caching_id,
            "caching_progress": (c_task.get("step") if c_task else None) or ("Preparing 1080p..." if c_task else None),
            "caching_fraction": round(c_progress, 2),
            "caching_percent": c_percent,
            "position_s": round(current_position_s(), 2),
            "duration_s": runtime_state.get("duration_seconds", 0),
            "volume": runtime_state.get("volume", 100.0),
            "cmd": runtime_state.get("cmd"),
            "hud_synced": hud_synced(),
            "cast_senders": runtime_state.get("cast_senders") or [],
            "up_next": up_next(),
            "caching_title": caching_title,
            "caching_artist": caching_artist,
            "hifi_catalog_version": runtime_state.get("hifi_catalog_version", 1),
            "hifi_sync_status": runtime_state.get("hifi_sync_status", "idle"),
            "shuffle": runtime_state.get("shuffle", False),
            "repeat": runtime_state.get("repeat", "all"),
            "display": runtime_state.get("display"),
            "sleep_in_s": (runtime_state["sleep_at"] - time.time()) if runtime_state.get("sleep_at") else None,
            "external": runtime_state.get("external"),
            "audio_only": bool(runtime_state.get("audio_only")) and not runtime_state.get("is_hifi"),
            "video_height": runtime_state.get("video_height"),
        }

        # Broadcast to Unix Socket clients
        data_bytes = (json.dumps(packet) + "\n").encode()
        dead_clients = set()
        for w in list(unix_clients):
            try:
                w.write(data_bytes)
            except Exception:
                dead_clients.add(w)
        for d in dead_clients:
            unix_clients.discard(d)

        await asyncio.sleep(1.0 / 60.0)

# --- Network Geolocation & Real-Time Open-Meteo Weather Engine ---

weather_state: Dict[str, Any] = {
    "city": "Unknown",
    "temperature": 15.0,
    "weather_code": 0,
    "is_day": 1,
    "condition": "Clear",
    "circadian_color": "#38BDF8",
    "updated_at": None
}

def compute_circadian_weather_color(hour: int, weather_code: int, is_day: int) -> str:
    # 1. Base Circadian Color by solar hour
    if 0 <= hour < 5:
        base_color = "#38BDF8"  # Deep midnight starlight sapphire
    elif 5 <= hour < 7:
        base_color = "#FB7185"  # Soft dawn rose
    elif 7 <= hour < 11:
        base_color = "#38BDF8"  # Morning crisp sky azure
    elif 11 <= hour < 16:
        base_color = "#00E5FF"  # High noon radiant solar cyan
    elif 16 <= hour < 19:
        base_color = "#F59E0B"  # Golden hour amber
    elif 19 <= hour < 22:
        base_color = "#818CF8"  # Twilight velvet indigo
    else:
        base_color = "#0284C7"  # Deep night ocean blue

    # 2. Weather Condition Modulation
    if weather_code in [95, 96, 99]:
        return "#A855F7"  # Electric thunderstorm violet
    elif 51 <= weather_code <= 67 or 80 <= weather_code <= 82:
        return "#06B6D4"  # Cool oceanic rain cyan
    elif 71 <= weather_code <= 77 or 85 <= weather_code <= 86:
        return "#BAE6FD"  # Glacial diamond snow frost
    elif weather_code in [3, 45, 48]:
        return "#94A3B8"  # Misty silver overcast vapor
    elif weather_code in [0, 1] and is_day:
        if 16 <= hour < 19:
            return "#F59E0B"  # Sunlit amber sunset
        return "#38BDF8"      # Clear azure sun

    return base_color

async def fetch_weather_now():
    global weather_state
    try:
        settings = load_settings()
        custom_city = settings.get("selected_city")
        custom_lat = settings.get("custom_lat")
        custom_lon = settings.get("custom_lon")

        if custom_city and custom_lat is not None and custom_lon is not None:
            lat = float(custom_lat)
            lon = float(custom_lon)
            city = str(custom_city)
        else:
            # Step 1: Network IP Geolocation
            req = urllib.request.Request("http://ip-api.com/json", headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                geo = json.loads(resp.read().decode())
            if geo.get("status") == "success":
                lat = geo["lat"]
                lon = geo["lon"]
                city = geo.get("city", "Unknown")
            else:
                lat = 53.383
                lon = -1.466
                city = "Sheffield"

        # Step 2: Open-Meteo Current & Daily Forecast Weather
        weather_url = (
            f"https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}"
            "&current=temperature_2m,relative_humidity_2m,is_day,weather_code"
            "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
            "&timezone=auto&forecast_days=4"
        )
        w_req = urllib.request.Request(weather_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(w_req, timeout=6) as w_resp:
            w_data = json.loads(w_resp.read().decode())
            current = w_data.get("current", {})
            temp = float(current.get("temperature_2m", 15.0))
            code = int(current.get("weather_code", 0))
            is_day = int(current.get("is_day", 1))

            conditions = {
                0: "Clear Sky", 1: "Mainly Clear", 2: "Partly Cloudy", 3: "Overcast",
                45: "Fog", 48: "Rime Fog",
                51: "Light Drizzle", 53: "Drizzle", 55: "Dense Drizzle",
                61: "Slight Rain", 63: "Moderate Rain", 65: "Heavy Rain",
                71: "Slight Snow", 73: "Moderate Snow", 75: "Heavy Snow",
                80: "Rain Showers", 81: "Heavy Showers", 82: "Violent Showers",
                95: "Thunderstorm", 96: "Hail Thunderstorm", 99: "Severe Thunderstorm"
            }
            cond_name = conditions.get(code, "Clear" if is_day else "Starry")
            now_hour = datetime.now().hour
            circadian_color = compute_circadian_weather_color(now_hour, code, is_day)

            # Step 3: Parse 3-day forecast & astronomical sunrise/sunset
            daily = w_data.get("daily", {})
            d_times = daily.get("time", [])
            d_codes = daily.get("weather_code", [])
            d_max = daily.get("temperature_2m_max", [])
            d_min = daily.get("temperature_2m_min", [])
            d_pop = daily.get("precipitation_probability_max", [])
            d_sunrises = daily.get("sunrise", [])
            d_sunsets = daily.get("sunset", [])

            forecast_list = []
            for i in range(1, min(4, len(d_times))):
                try:
                    dt = datetime.strptime(d_times[i], "%Y-%m-%d")
                    day_name = dt.strftime("%a").upper()
                except Exception:
                    day_name = f"D+{i}"
                forecast_list.append({
                    "day": day_name,
                    "date": d_times[i],
                    "weather_code": int(d_codes[i]) if i < len(d_codes) else code,
                    "temp_max": round(float(d_max[i])) if i < len(d_max) else round(temp),
                    "temp_min": round(float(d_min[i])) if i < len(d_min) else round(temp - 5),
                    "rain_pop": int(d_pop[i]) if (i < len(d_pop) and d_pop[i] is not None) else 0
                })

            today_sunrise_iso = d_sunrises[0] if d_sunrises else ""
            today_sunset_iso = d_sunsets[0] if d_sunsets else ""
            today_sunrise_str = today_sunrise_iso.split("T")[1] if "T" in today_sunrise_iso else "06:30"
            today_sunset_str = today_sunset_iso.split("T")[1] if "T" in today_sunset_iso else "18:30"

            weather_state = {
                "city": city,
                "lat": lat,
                "lon": lon,
                "temperature": temp,
                "weather_code": code,
                "is_day": is_day,
                "condition": cond_name,
                "circadian_color": circadian_color,
                "sunrise": today_sunrise_str,
                "sunset": today_sunset_str,
                "sunrise_iso": today_sunrise_iso,
                "sunset_iso": today_sunset_iso,
                "forecast": forecast_list,
                "updated_at": datetime.now(timezone.utc).isoformat()
            }
            print(f"[Weather] Updated: {city}, {temp}°C, {cond_name}, Sun: {today_sunrise_str}-{today_sunset_str}, Forecast: {len(forecast_list)} days")
            return weather_state
    except Exception as e:
        print(f"[Weather Error] Failed to fetch weather: {e}")
        return weather_state

async def weather_updater_task():
    while True:
        await fetch_weather_now()
        await asyncio.sleep(900)  # Refresh every 15 minutes

class CitySelectRequest(BaseModel):
    city: str
    lat: Optional[float] = None
    lon: Optional[float] = None

# --- REST Endpoints ---

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(start_unix_telemetry_server())
    asyncio.create_task(display_schedule_loop())
    asyncio.create_task(telemetry_broadcaster_loop())
    asyncio.create_task(weather_updater_task())
    try:
        restore_from_sdcard_if_fresh()
    except Exception:
        pass
    # We always start in standby; tell a HUD that outlived us (it may still show the last video) to match.
    with state_lock:
        _issue_cmd_locked("stop", playing=False)
    asyncio.create_task(backup_loop())
    asyncio.create_task(sleep_timer_loop())
    asyncio.create_task(watchdog_loop())
    asyncio.create_task(ytdlp_update_loop())
    global _main_loop
    _main_loop = asyncio.get_event_loop()
    try:
        if start_mqtt_from_settings():
            print("[MQTT] bridge started")
    except Exception as e:
        print(f"[MQTT] {e}")
    asyncio.create_task(alarm_loop())
    threading.Thread(target=apply_boot_volume, daemon=True, name="boot-volume").start()
    try:
        last = _load_resume()
        if last:
            with state_lock:
                runtime_state["last_idle_track"] = last
            print(f"[Resume] will resume {last.get('title')!r} at {float(last.get('position_s') or 0):.0f}s on wake")
    except Exception:
        pass
    try:
        st = load_settings()
        with state_lock:
            runtime_state["shuffle"] = bool(st.get("shuffle", False))
            runtime_state["repeat"] = st.get("repeat", "all") if st.get("repeat") in ("off", "all", "one") else "all"
    except Exception:
        pass
    if network_manager.available() and os.environ.get("ROUNDPLAYER_NO_NET_WATCHDOG") != "1":
        threading.Thread(target=network_manager.watchdog_loop, daemon=True, name="net-watchdog").start()

@app.get("/api/weather")
async def get_weather():
    if not weather_state.get("updated_at"):
        await fetch_weather_now()
    return weather_state

@app.get("/api/weather/search")
async def search_weather_city(q: str):
    if not q or len(q.strip()) < 2:
        return {"results": []}
    try:
        encoded_q = urllib.parse.quote(q.strip())
        url = f"https://geocoding-api.open-meteo.com/v1/search?name={encoded_q}&count=8&language=en&format=json"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            results = []
            for r in data.get("results", []):
                results.append({
                    "name": r.get("name"),
                    "country": r.get("country", ""),
                    "admin1": r.get("admin1", ""),
                    "latitude": r.get("latitude"),
                    "longitude": r.get("longitude")
                })
            return {"results": results}
    except Exception as e:
        print(f"[City Search Error] {e}")
        return {"results": [], "error": str(e)}

@app.post("/api/weather/city")
async def set_weather_city(req: CitySelectRequest):
    settings = load_settings()
    if req.city.lower() in ["auto", "automatic", "ip"]:
        settings["selected_city"] = None
        settings["custom_lat"] = None
        settings["custom_lon"] = None
        save_settings(settings)
        w = await fetch_weather_now()
        return {"status": "ok", "mode": "auto", "weather": w}

    lat = req.lat
    lon = req.lon
    if lat is None or lon is None:
        try:
            geo_url = f"https://geocoding-api.open-meteo.com/v1/search?name={urllib.parse.quote(req.city)}&count=1&language=en&format=json"
            g_req = urllib.request.Request(geo_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(g_req, timeout=5) as g_resp:
                g_data = json.loads(g_resp.read().decode())
                if g_data.get("results"):
                    lat = g_data["results"][0]["latitude"]
                    lon = g_data["results"][0]["longitude"]
                    req.city = g_data["results"][0]["name"]
        except Exception as e:
            print(f"[Geocode Error] {e}")

    settings["selected_city"] = req.city
    settings["custom_lat"] = lat
    settings["custom_lon"] = lon
    save_settings(settings)
    w = await fetch_weather_now()
    return {"status": "ok", "city": req.city, "weather": w}

@app.get("/api/state", response_model=SystemState)
async def get_system_state():
    with state_lock:
        pos = round(current_position_s(), 1)
        if hud_state_fresh() and hud_state.get("duration_s"):
            runtime_state["duration_seconds"] = int(hud_state["duration_s"])

        return SystemState(
            cmd_seq=runtime_state.get("cmd_seq", 0),
            hud_synced=hud_synced(),
            active_video_id=runtime_state.get("active_video_id"),
            title=runtime_state.get("title"),
            artist=runtime_state.get("artist"),
            is_playing=runtime_state.get("is_playing", False),
            volume=runtime_state.get("volume", 100.0),
            current_bpm=runtime_state.get("current_bpm", 126.2),
            playback_position_s=pos,
            duration_seconds=runtime_state.get("duration_seconds", 240),
            dominant_color=runtime_state.get("dominant_color", "#00E5FF"),
            caching_video_id=runtime_state.get("caching_video_id"),
            caching_title=runtime_state.get("caching_title"),
            caching_artist=runtime_state.get("caching_artist"),
            caching_progress=runtime_state.get("caching_progress"),
            caching_percent=runtime_state.get("caching_percent", 0),
            is_hifi=runtime_state.get("is_hifi", False),
            format=runtime_state.get("audio_format"),
            bit_depth=runtime_state.get("bit_depth"),
            sample_rate_hz=runtime_state.get("sample_rate_hz"),
        )

@app.get("/api/tracks")
@app.get("/tracks")
async def list_tracks():
    tracks = []
    if not os.path.exists(CACHE_DIR):
        return tracks
    for item in os.listdir(CACHE_DIR):
        if not is_track_ready(item):
            continue
        meta_file = get_meta_path(item)
        if os.path.isfile(meta_file):
            try:
                with open(meta_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    data["is_cached"] = True
                    tracks.append(data)
            except Exception:
                continue
    return tracks

JUNK_SEARCH_REGEX = re.compile(
    r'\b(karaoke|piano tutorial|how to play|slowed|reverb|sped up|speed up|8d audio|bass boosted|loop|10 hours?|1 hour|parody|reaction|tutorial|lesson)\b',
    re.IGNORECASE
)

@app.get("/api/search")
@app.get("/search")
async def search(q: str):
    if not q.strip():
        return []
    try:
        yt = ytmusicapi.YTMusic()
        # 1. Search official studio tracks / master songs first (highest audio fidelity & official release)
        try:
            song_results = yt.search(q, filter="songs")
        except Exception:
            song_results = []

        # 2. Search official videos to capture genuine music videos
        try:
            video_results = yt.search(q, filter="videos")
        except Exception:
            video_results = []

        output = []
        seen_ids = set()

        # Prioritize official studio master tracks
        for res in song_results:
            vid = res.get('videoId')
            if not vid or vid in seen_ids:
                continue
            title = res.get('title', '')
            if JUNK_SEARCH_REGEX.search(title):
                continue
            seen_ids.add(vid)
            thumbnails = res.get('thumbnails', [])
            thumb = thumbnails[-1]['url'] if thumbnails else ''
            artists = res.get('artists', [])
            artist_name = artists[0]['name'] if artists else 'Unknown'
            output.append({
                "video_id": vid,
                "title": title or 'Unknown',
                "artist": artist_name,
                "duration": res.get('duration', '0:00'),
                "thumbnail_url": thumb,
                "is_cached": is_track_ready(vid)
            })
            if len(output) >= 8:
                break

        # Supplement with verified music videos (filtering out tutorials, covers, karaoke, etc.)
        if len(output) < 8:
            for res in video_results:
                vid = res.get('videoId')
                if not vid or vid in seen_ids:
                    continue
                title = res.get('title', '')
                if JUNK_SEARCH_REGEX.search(title):
                    continue
                seen_ids.add(vid)
                thumbnails = res.get('thumbnails', [])
                thumb = thumbnails[-1]['url'] if thumbnails else ''
                artists = res.get('artists', [])
                artist_name = artists[0]['name'] if artists else 'Unknown'
                output.append({
                    "video_id": vid,
                    "title": title or 'Unknown',
                    "artist": artist_name,
                    "duration": res.get('duration', '0:00'),
                    "thumbnail_url": thumb,
                    "is_cached": is_track_ready(vid)
                })
                if len(output) >= 8:
                    break

        return output
    except Exception as e:
        print(f"[Search Error] {e}")
        return []

@app.post("/api/cache/clear")
@app.post("/cache/clear")
async def clear_cached_music():
    current_active = runtime_state.get("active_video_id")
    cleared_count = 0
    try:
        if os.path.exists(CACHE_DIR):
            for entry in os.listdir(CACHE_DIR):
                entry_path = os.path.join(CACHE_DIR, entry)
                if os.path.isdir(entry_path) and entry != current_active:
                    import shutil
                    shutil.rmtree(entry_path, ignore_errors=True)
                    cleared_count += 1
        with state_lock:
            cache_tasks.clear()
        return {"status": "ok", "cleared_tracks": cleared_count}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/cache/{video_id}")
@app.post("/cache/{video_id}")
async def trigger_cache(video_id: str):
    if is_track_ready(video_id):
        return {"status": "ready", "video_id": video_id}
    if video_id in cache_tasks and cache_tasks[video_id]["status"] not in ["error", "ready"]:
        return {"status": cache_tasks[video_id]["status"], "video_id": video_id}
    
    asyncio.get_event_loop().run_in_executor(None, run_caching_pipeline, video_id)
    return {"status": "downloading", "video_id": video_id}

@app.get("/api/cache/status/{video_id}", response_model=CacheStatus)
@app.get("/cache/status/{video_id}", response_model=CacheStatus)
async def get_cache_status(video_id: str):
    if is_track_ready(video_id):
        return CacheStatus(status="ready", progress=1.0, percent=100, step="Ready")
    if video_id in cache_tasks:
        task = cache_tasks[video_id]
        p = task.get("progress", 0.0)
        pct = task.get("percent") or int(p * 100)
        return CacheStatus(
            status=task.get("status", "downloading"),
            progress=p,
            percent=pct,
            step=task.get("step", ""),
            title=task.get("title"),
            artist=task.get("artist"),
            error=task.get("error")
        )
    return CacheStatus(status="missing", error="Track not cached", progress=0.0, percent=0, step="Not in queue")

@app.post("/api/play/{video_id}")
@app.post("/play/{video_id}")
async def set_active_track(video_id: str, request: Request = None):
    meta_hint = {}
    if request:
        try:
            body = await request.body()
            if body:
                meta_hint = json.loads(body.decode())
        except Exception:
            pass

    global target_track_id
    with state_lock:
        _supersede_preparing_locked(video_id)
        target_track_id = video_id
        runtime_state["is_playing"] = True
        if meta_hint.get("source") == "cast":
            runtime_state["cast_track_id"] = video_id
        try:
            if meta_hint.get("position") is not None:
                pending_cast_position[video_id] = float(meta_hint.get("position") or 0.0)
        except Exception:
            pass

    if is_track_ready(video_id):
        with state_lock:
            runtime_state["caching_video_id"] = None
        return activate_track_sync(video_id)

    # Not cached: stream it like a normal player (resolve ~2-3 s, then mpv streams with range requests).
    # The full download pipeline is only used when "Keep a copy" is on.
    audio_only = bool(meta_hint.get("music")) or bool(load_settings().get("youtube_audio_only", False))
    _yt_audio_only[video_id] = audio_only
    c_title = meta_hint.get("title") if meta_hint.get("title") not in (None, "", "Incoming Video") else "YouTube"
    c_artist = meta_hint.get("artist") if meta_hint.get("artist") not in (None, "", "YouTube Cast") else ""
    with state_lock:
        gen = prep_gen
        runtime_state["caching_video_id"] = video_id
        runtime_state["caching_title"] = c_title
        runtime_state["caching_artist"] = c_artist or "Connecting…"
        runtime_state["active_video_id"] = video_id
        runtime_state["title"] = c_title
        runtime_state["artist"] = c_artist
        runtime_state["album"] = ""
        runtime_state["is_hifi"] = False
        runtime_state["is_playing"] = True
        cache_tasks[video_id] = {"status": "preparing", "progress": 0.1, "percent": 10, "step": "Connecting", "error": None}
    asyncio.get_event_loop().run_in_executor(None, _start_yt_stream, video_id, gen, audio_only)
    if load_settings().get("youtube_keep_copy", False):
        asyncio.get_event_loop().run_in_executor(None, _background_keep_copy, video_id)
    return {"status": "connecting", "video_id": video_id, "title": c_title, "artist": c_artist, "audio_only": audio_only}


def _background_keep_copy(video_id: str) -> None:
    """Optional: download the full file in the background for offline replay, without auto-playing it."""
    global target_track_id
    try:
        time.sleep(20)   # let the stream get going first
        with state_lock:
            target_track_id = None   # never let the pipeline switch playback when it finishes
        run_caching_pipeline(video_id)
    except Exception as e:
        print(f"[YT keep copy] {video_id}: {e}")


def _start_yt_stream(video_id: str, gen: int, audio_only: bool) -> None:
    try:
        st = yt_stream.resolve(video_id, audio_only=audio_only)
    except Exception as e:
        msg = str(e).split("\n")[0][:160]
        print(f"[YT stream] resolve failed for {video_id}: {msg}")
        with state_lock:
            if prep_gen == gen and runtime_state.get("caching_video_id") == video_id:
                cache_tasks[video_id] = {"status": "error", "progress": 0, "percent": 0, "step": "Could not play this video", "error": msg}
                runtime_state["caching_artist"] = "Could not play this video"
        return
    # Cover (thumbnail) for lists, the art layout and the tint - quick, and does not block playback
    def cover_and_meta():
        try:
            cover = get_cover_path(video_id)
            if yt_stream.fetch_thumbnail(st.get("thumbnail"), cover):
                col = extract_dominant_color(cover)
                with state_lock:
                    if runtime_state.get("active_video_id") == video_id:
                        runtime_state["dominant_color"] = col
        except Exception as e:
            print(f"[YT stream] cover failed for {video_id}: {e}")
    threading.Thread(target=cover_and_meta, daemon=True).start()
    with state_lock:
        if prep_gen != gen or runtime_state.get("active_video_id") != video_id:
            return   # superseded while resolving (the user picked something else)
        if st["audio_only"]:
            _yt_audio_only[video_id] = True
        start_pos = float(pending_cast_position.pop(video_id, 0.0) or 0.0)
        runtime_state["title"] = st["title"]
        runtime_state["artist"] = st["artist"] or runtime_state.get("artist") or ""
        runtime_state["album"] = st.get("album") or ""
        runtime_state["is_hifi"] = False
        runtime_state["audio_only"] = bool(st["audio_only"])
        runtime_state["video_height"] = st.get("height")
        runtime_state["audio_format"] = st.get("acodec") or "AAC"
        runtime_state["bit_depth"] = 16
        runtime_state["sample_rate_hz"] = 48000 if (st.get("acodec") or "").startswith("OPUS") else 44100
        runtime_state["duration_seconds"] = int(st.get("duration_s") or 0)
        runtime_state["current_bpm"] = 120.0
        runtime_state["beats"] = np.array([], dtype=np.float32)
        runtime_state["start_time"] = time.time()
        runtime_state["position_offset_s"] = start_pos
        runtime_state["pause_time"] = None
        runtime_state["is_playing"] = True
        runtime_state["caching_video_id"] = None
        runtime_state["caching_title"] = None
        runtime_state["caching_artist"] = None
        cache_tasks[video_id] = {"status": "ready", "progress": 1.0, "percent": 100, "step": "Streaming", "error": None}
        _issue_cmd_locked("load", track_id=video_id, source="youtube", position_s=start_pos, playing=True)
    print(f"[YT stream] {video_id} '{st['title']}' by {st['artist']} - {'audio only ' + str(st.get('acodec')) if st['audio_only'] else str(st.get('height')) + 'p'} (resolved in {st['resolved_in_s']} s)")
    _note_played(video_id, st["title"], st["artist"], st.get("album") or "", False)
    with queue_lock:
        if not playback_history or playback_history[-1] != video_id:
            playback_history.append(video_id)

@app.post("/api/control")
@app.post("/control")
async def handle_control(cmd: ControlCommand):
    with state_lock:
        if cmd.action == "play":
            runtime_state["is_playing"] = True
            if runtime_state.get("pause_time") and runtime_state.get("start_time"):
                paused_duration = time.time() - runtime_state["pause_time"]
                runtime_state["start_time"] += paused_duration
                runtime_state["pause_time"] = None
            _issue_cmd_locked("play", track_id=runtime_state.get("active_video_id"), playing=True)
        elif cmd.action == "pause":
            runtime_state["is_playing"] = False
            runtime_state["pause_time"] = time.time()
            _issue_cmd_locked("pause", track_id=runtime_state.get("active_video_id"), playing=False)
            _save_resume(_snapshot_now_locked())   # a pause is the most likely last thing before the plug is pulled
        elif cmd.action in ["stop", "idle", "sleep"]:
            _supersede_preparing_locked(None)
            _enter_idle_locked()
        elif cmd.action == "stop_cast":
            # The phone ended its cast session (explicit stop, app backgrounded, Wi-Fi drop). Only the track the cast
            # itself started is affected - and it simply stops. Anything the user picked since is left alone.
            # (The old "pop history and reload the previous track" is what made the box jump to earlier songs.)
            cast_owned = runtime_state.get("cast_track_id")
            caching_id = runtime_state.get("caching_video_id")
            if cast_owned and (runtime_state.get("active_video_id") == cast_owned or caching_id == cast_owned):
                _supersede_preparing_locked(None)
                if caching_id:
                    with caching_lock:
                        if caching_id in cache_tasks:
                            cache_tasks[caching_id]["status"] = "canceled"
                _enter_idle_locked()
                # Stopping a cast means "done" - not "pause": nothing is kept for tap-to-wake to bring back, so a touch
                # on the clock opens the library instead of reloading the cast video paused. (It stays in Recently played.)
                runtime_state["last_idle_track"] = None
                try:
                    os.remove(RESUME_FILE)
                except OSError:
                    pass
            runtime_state["cast_track_id"] = None
        elif cmd.action == "seek" and cmd.seek_seconds is not None:
            runtime_state["position_offset_s"] = float(cmd.seek_seconds)
            runtime_state["start_time"] = time.time()
            _issue_cmd_locked("seek", track_id=runtime_state.get("active_video_id"), position_s=float(cmd.seek_seconds),
                              playing=runtime_state.get("is_playing", False))
        elif cmd.action == "volume" and cmd.value is not None:
            runtime_state["volume"] = float(cmd.value)
    return {"status": "ok", "action": cmd.action, "value": cmd.value, "is_playing": runtime_state.get("is_playing", False),
            "cmd_seq": runtime_state.get("cmd_seq", 0)}

# --- Queue & Playlist Endpoints ---

@app.get("/api/queue")
async def get_queue():
    with queue_lock:
        return {"queue": list(playback_queue), "history": list(playback_history)}

@app.post("/api/queue/add")
async def add_to_queue(item: QueueItem):
    with queue_lock:
        is_hifi = item.video_id.startswith("hifi_") or item.source == "hifi"
        clean_id = item.video_id.replace("hifi_", "")
        full_id = f"hifi_{clean_id}" if is_hifi else item.video_id
        
        is_ready = hifi_manager.is_track_cached(clean_id) if is_hifi else is_track_ready(full_id)
        
        queue_entry = {
            "video_id": full_id,
            "title": item.title or "Queued Track",
            "artist": item.artist or "Unknown",
            "album": item.album or "",
            "duration": item.duration or "",
            "thumbnail_url": item.thumbnail_url or "",
            "source": "hifi" if is_hifi else (item.source or "youtube"),
            "cover_key": item.cover_key or "",
            "is_cached": is_ready
        }
        
        if getattr(item, "position", "end") == "next":
            playback_queue.insert(0, queue_entry)
        else:
            playback_queue.append(queue_entry)
            
        if not is_hifi and not is_ready:
            threading.Thread(target=run_caching_pipeline, args=(full_id,), daemon=True).start()
    return {"status": "ok", "queue_length": len(playback_queue)}

@app.post("/api/queue/remove/{index}")
async def remove_from_queue(index: int):
    with queue_lock:
        if 0 <= index < len(playback_queue):
            removed = playback_queue.pop(index)
            return {"status": "ok", "removed": removed}
    raise HTTPException(status_code=400, detail="Index out of range")

@app.post("/api/queue/clear")
async def clear_queue():
    with queue_lock:
        playback_queue.clear()
    return {"status": "ok"}

@app.post("/api/queue/next")
async def play_next_in_queue_endpoint():
    _log_switch_away(None, user=True)   # an explicit "next" counts as a skip of the current track
    return await play_next_in_queue()


async def play_next_in_queue():
    next_id = None
    planned = up_next()   # the same pick the HUD may already have pre-opened (gapless); takes queue_lock itself
    with queue_lock:
        if playback_queue:
            next_item = playback_queue.pop(0)
            next_id = next_item.get("video_id") or next_item.get("track_id")
        elif runtime_state.get("is_hifi"):
            curr_clean = runtime_state.get("active_video_id", "").replace("hifi_", "")
            album_tracks, idx = hifi_manager.get_album_tracks_for_track(curr_clean)
            if album_tracks and idx >= 0:
                if planned and planned.get("source") == "album":
                    next_id = planned["track_id"]
                elif load_settings().get("autoplay_similar", True):
                    pick = _autoplay_pick(f"hifi_{curr_clean}")
                    if pick:
                        next_id = "hifi_" + str(pick.get("track_id"))
                    else:
                        runtime_state["is_playing"] = False
                        runtime_state["pause_time"] = time.time()
                        return {"status": "ended", "message": "Album finished"}
                else:
                    runtime_state["is_playing"] = False
                    runtime_state["pause_time"] = time.time()
                    return {"status": "ended", "message": "Album finished"}
            else:
                flat = hifi_manager.get_flat_tracks()
                if flat:
                    next_id = "hifi_" + str(flat[0].get("track_id", ""))
        else:
            return {"status": "empty"}
    if next_id and next_id.startswith("hifi_"):
        return await asyncio.to_thread(activate_hifi_track, next_id)
    if next_id:
        return await set_active_track(next_id)
    return {"status": "empty"}

@app.post("/api/queue/prev")
async def play_prev_in_history():
    prev_id = None
    with queue_lock:
        if len(playback_history) >= 2:
            playback_history.pop()  # Pop current
            prev_id = playback_history.pop()
        elif runtime_state.get("is_hifi"):
            curr_clean = runtime_state.get("active_video_id", "").replace("hifi_", "")
            album_tracks, idx = hifi_manager.get_album_tracks_for_track(curr_clean)
            if album_tracks and idx >= 0:
                if runtime_state.get("shuffle") and len(album_tracks) > 1:
                    import random
                    pool = [i for i in range(len(album_tracks)) if i != idx]
                    prev_idx = random.choice(pool) if pool else 0
                    prev_id = "hifi_" + str(album_tracks[prev_idx].get("track_id", ""))
                elif idx - 1 >= 0:
                    prev_id = "hifi_" + str(album_tracks[idx - 1].get("track_id", ""))
                elif runtime_state.get("repeat") == "all":
                    prev_id = "hifi_" + str(album_tracks[-1].get("track_id", ""))
                else:
                    prev_id = "hifi_" + str(album_tracks[0].get("track_id", ""))
        elif len(playback_history) == 1:
            prev_id = playback_history[0]
        else:
            return {"status": "empty"}
    if prev_id and prev_id.startswith("hifi_"):
        return await asyncio.to_thread(activate_hifi_track, prev_id)
    if prev_id:
        return await set_active_track(prev_id)
    return {"status": "empty"}

# --- Persistent Settings & System Endpoints ---

SETTINGS_FILE = "/data/roundplayer_settings.json" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "roundplayer_settings.json")
DEFAULT_SETTINGS = {
    "centerpiece_style": "chronometer",
    "idle_timeout_seconds": 120,
    "ambient_brightness": 100,
    "volume_ceiling": 100,
    "loudnorm_enabled": True,
    "selected_city": None,
    "custom_lat": None,
    "custom_lon": None,
    "autoplay_similar": True,   # when the album/queue ends, keep playing music like it (Hi-Fi)
    "clock_24h": False,         # clock on the standby screen / screensaver: 12 h with AM/PM by default
    "shuffle": False,
    "repeat": "all",
    "volume_pct": 100.0,        # the one volume: HUD slider position; applied to the DAC's digital volume
    "update": {"url": ""},
    "youtube_keep_copy": False,   # also download casts in the background for offline replay
    "youtube_audio_only": False,  # play every YouTube cast as audio with the cover (YouTube Music always is)
    "mqtt": {"enabled": False, "host": "", "port": 1883, "username": "", "password": "", "base": "roundplayer"},
    "alarm": {"enabled": False, "time": "07:30", "days": [0, 1, 2, 3, 4], "source": "last", "volume_pct": 45, "fade_s": 60},
}

def load_settings() -> dict:
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, 'r', encoding='utf-8') as f:
                data = json.load(f)
                res = DEFAULT_SETTINGS.copy()
                res.update(data)
                return res
        except Exception:
            pass
    return DEFAULT_SETTINGS.copy()

def save_settings(data: dict) -> dict:
    current = load_settings()
    current.update(data)
    try:
        os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
        with open(SETTINGS_FILE, 'w', encoding='utf-8') as f:
            json.dump(current, f, indent=2)
    except Exception as e:
        print(f"[Settings Save Error] {e}")
    return current

def get_lan_ip() -> str:
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

@app.get("/api/settings")
async def get_settings():
    return load_settings()

@app.post("/api/settings")
async def update_settings(new_settings: Dict[str, Any]):
    out = save_settings(new_settings)
    if "mqtt" in new_settings:
        try:
            start_mqtt_from_settings()
        except Exception as e:
            print(f"[MQTT] restart failed: {e}")
    return {"status": "ok", "settings": out}

# --- Audiophile DAC & PipeWire Settings Endpoints ---

DACPRO_CTL = "/usr/local/bin/dacpro-ctl"
DACPRO_CONF = "/etc/dacpro.json"

@app.get("/api/audio/settings")
async def get_audio_settings():
    """Returns saved settings from /etc/dacpro.json and live DAC telemetry."""
    saved = {}
    if os.path.exists(DACPRO_CONF):
        try:
            with open(DACPRO_CONF, "r", encoding="utf-8") as f:
                saved = json.load(f)
        except Exception as e:
            pass
    
    live_readback = {}
    try:
        res = subprocess.run(
            ["sudo", DACPRO_CTL, "show"],
            capture_output=True, text=True, timeout=3
        )
        if res.returncode == 0:
            lines = res.stdout.splitlines()
            in_live = False
            for line in lines:
                if "Live DAC readback:" in line:
                    in_live = True
                    continue
                if in_live and line.strip():
                    parts = line.strip().split(maxsplit=1)
                    if len(parts) == 2:
                        live_readback[parts[0]] = parts[1]
    except Exception:
        pass
        
    return {
        "status": "ok",
        "settings": saved,
        "live": live_readback,
        "options": {
            "filter": ["ringless", "fir", "iir", "high-atten", "fixed"],
            "analog-gain": ["0", "-6"],
            "boost": ["on", "off"],
            "deemphasis": ["on", "off"],
            "channels": ["stereo", "swap", "mono-left", "mono-right", "left-only", "right-only"],
            "ramp": ["1/0.5dB", "1/1dB", "1/2dB", "1/4dB", "instant"],
            "auto-mute": ["off", "21ms", "106ms", "213ms", "533ms", "1.07s", "2.13s", "5.33s", "10.66s"],
            "pw-resample-quality": [4, 10, 12, 14],
            "pw-dither": ["none", "rectangular", "triangular", "triangular-hf", "wannamaker3", "lipshitz5"],
            "pw-hires": ["on", "off"],
            "pw-keep-awake": ["on", "off"],
            "mute": ["on", "off"],
            "balance": {"min": -12.0, "max": 12.0, "step": 0.5}
        }
    }

@app.post("/api/audio/settings")
async def update_audio_settings(payload: Dict[str, Any]):
    """Updates one or more audio settings and persists them via dacpro-ctl without dropping playback."""
    results = {}
    errors = {}
    is_playing = False
    with state_lock:
        is_playing = bool(runtime_state.get("is_playing"))
        
    for opt, val in payload.items():
        try:
            cmd = ["sudo", DACPRO_CTL, "set", str(opt), str(val)]
            if str(opt).startswith("pw-") and is_playing:
                cmd.append("--no-restart")
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=6)
            if res.returncode == 0:
                results[opt] = val
            else:
                errors[opt] = res.stderr.strip() or res.stdout.strip()
        except Exception as e:
            errors[opt] = str(e)
            
    return {"status": "ok" if not errors else "partial", "updated": results, "errors": errors}

@app.post("/api/audio/reset")
async def reset_audio_settings():
    """Resets all DAC Pro and PipeWire audio parameters to factory defaults."""
    is_playing = False
    with state_lock:
        is_playing = bool(runtime_state.get("is_playing"))
    cmd = ["sudo", DACPRO_CTL, "reset"]
    if is_playing:
        cmd.append("--no-restart")
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=6)
    return {"status": "ok" if res.returncode == 0 else "error", "message": res.stdout.strip() or res.stderr.strip()}

@app.post("/api/audio/preset/best-quality")
async def apply_best_quality_preset():
    """Applies reference audiophile preset across all 14 parameters without restarting during playback."""
    is_playing = False
    with state_lock:
        is_playing = bool(runtime_state.get("is_playing"))
    preset = {
        "filter": "ringless",
        "pw-resample-quality": "14",
        "pw-keep-awake": "on",
        "pw-hires": "on",
        "pw-dither": "lipshitz5",
        "ramp": "1/0.5dB",
        "analog-gain": "0",
        "boost": "off",
        "channels": "stereo",
        "balance": "0.0",
        "auto-mute": "off",
        "deemphasis": "off",
        "mute": "off"
    }
    for opt, val in preset.items():
        try:
            cmd = ["sudo", DACPRO_CTL, "set", opt, str(val)]
            if opt.startswith("pw-") and is_playing:
                cmd.append("--no-restart")
            subprocess.run(cmd, check=True, timeout=6)
        except Exception:
            pass
    return {"status": "ok", "preset": preset}

@app.post("/api/audio/volume")
async def set_hardware_dac_volume(payload: Dict[str, Any]):
    """Sets DAC digital volume directly (-103.5 to 0.0 dB). Lossless 32-bit path."""
    vol_db = payload.get("volume_db")
    pct = None
    if vol_db is None:
        vol_pct = payload.get("volume_pct")
        if vol_pct is not None:
            pct = max(0.0, min(100.0, float(vol_pct)))
            vol_db = _pct_to_db(pct)
    if vol_db is not None:
        vol_db = max(VOL_MIN_DB, min(0.0, float(vol_db)))
        if pct is None:
            pct = _db_to_pct(vol_db)
        formatted = f"{vol_db:.1f}"
        await asyncio.to_thread(subprocess.run, ["sudo", DACPRO_CTL, "set", "volume", formatted], capture_output=True, text=True, timeout=4)
        with state_lock:
            runtime_state["volume"] = pct
        st = load_settings()
        if abs(float(st.get("volume_pct", -1)) - pct) > 0.01:
            st["volume_pct"] = pct
            save_settings(st)
        return {"status": "ok", "volume_db": vol_db, "volume_pct": pct}
    raise HTTPException(status_code=400, detail="Missing volume_db or volume_pct")


# Perceptual slider: dB = 40·log10(p). 50 % = -12 dB, 25 % = -24 dB, 10 % = -40 dB, 1 % = -80 dB, 0 % = silent.
# (The old linear -60..0 mapping left the bottom third of the slider inaudible.) settings.volume_ceiling (10..100)
# caps what the slider can ask for - a guest cannot blast it.
VOL_MIN_DB = -103.5


def _db_to_pct(db: float) -> float:
    if db <= VOL_MIN_DB + 0.01:
        return 0.0
    return max(0.0, min(100.0, 100.0 * (10 ** (db / 40.0))))


def _pct_to_db(pct: float) -> float:
    pct = max(0.0, min(100.0, float(pct)))
    try:
        ceiling = float(load_settings().get("volume_ceiling", 100) or 100)
    except Exception:
        ceiling = 100.0
    pct = min(pct, max(10.0, min(100.0, ceiling)))
    if pct <= 0.5:
        return VOL_MIN_DB
    return max(VOL_MIN_DB, min(0.0, 40.0 * math.log10(pct / 100.0)))


def pw_sinks_to_unity():
    """PipeWire sinks run at software unity (the DAC does the volume). WirePlumber remembers a route volume per
    sink and re-applies it at every start (it once held 0.40 for the DAC = -24 dB of silent attenuation)."""
    env = dict(os.environ, XDG_RUNTIME_DIR=os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    try:
        dump = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5, env=env).stdout or "[]")
    except Exception:
        return 0
    n = 0
    for o in dump:
        props = (o.get("info") or {}).get("props") or {}
        if props.get("media.class") == "Audio/Sink":
            try:
                subprocess.run(["wpctl", "set-volume", str(o["id"]), "1.0"], capture_output=True, timeout=3, env=env)
                subprocess.run(["wpctl", "set-mute", str(o["id"]), "0"], capture_output=True, timeout=3, env=env)
                n += 1
            except Exception:
                pass
    return n


def apply_boot_volume():
    """Boot: the DAC's digital volume is whatever alsa-restore / the DAC defaults left it at and the HUD slider
    starts at 100 % - they must agree. The saved slider position wins: apply it to the DAC and publish it."""
    try:
        pct = float(load_settings().get("volume_pct", 100.0))
    except Exception:
        pct = 100.0
    db = _pct_to_db(pct)
    for attempt in range(20):   # the DAC card can appear a few seconds after we start
        try:
            r = subprocess.run(["sudo", DACPRO_CTL, "apply"], capture_output=True, text=True, timeout=40)
            r2 = subprocess.run(["sudo", DACPRO_CTL, "set", "volume", f"{db:.1f}"], capture_output=True, text=True, timeout=8)
            if r.returncode == 0 and r2.returncode == 0 and "not detected" not in (r.stdout + r2.stdout):
                break
        except Exception as e:
            print(f"[Boot volume] attempt {attempt}: {e}")
        time.sleep(2)
    with state_lock:
        runtime_state["volume"] = pct
    for _ in range(15):   # PipeWire comes up with the user session, possibly after us
        if pw_sinks_to_unity():
            break
        time.sleep(2)
    print(f"[Boot volume] DAC settings applied, volume {pct:.0f}% ({db:.1f} dB), PipeWire sinks at unity")
    # Sound-check: read the DAC back and compare with what we meant to set. Something else (udev's alsactl, a late
    # card registration) may have written the registers after us; re-apply up to 3 times, then report.
    time.sleep(3)
    result = {"ok": False, "issues": ["not checked"], "live": {}}
    for attempt in range(3):
        result = dac_verify()
        if result.get("ok"):
            break
        print(f"[Sound-check] mismatch ({attempt + 1}/3): {result.get('issues')} - re-applying")
        try:
            subprocess.run(["sudo", DACPRO_CTL, "apply"], capture_output=True, text=True, timeout=40)
            subprocess.run(["sudo", DACPRO_CTL, "set", "volume", f"{db:.1f}"], capture_output=True, text=True, timeout=8)
        except Exception:
            pass
        time.sleep(2)
    with state_lock:
        runtime_state["audio_check"] = {"ok": bool(result.get("ok")), "issues": result.get("issues", []), "checked_at": time.time(),
                                        "reapplied": attempt if not result.get("ok") else attempt}
    print(f"[Sound-check] {'OK' if result.get('ok') else 'FAILED: ' + '; '.join(result.get('issues', []))}")


def dac_verify() -> Dict[str, Any]:
    try:
        r = subprocess.run([DACPRO_CTL, "verify"], capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception as e:
        return {"ok": False, "issues": [f"verify failed: {e}"], "live": {}}


# --- HUD -> daemon real playback state, live audio readback, network ---------------------------

class HudStateReport(BaseModel):
    track_id: Optional[str] = None
    position_s: float = 0.0
    duration_s: float = 0.0
    is_playing: bool = False
    audio_rate_hz: Optional[int] = None
    audio_format: Optional[str] = None

@app.get("/api/hud/state")
async def get_hud_state():
    """What the HUD last reported (debug / remote)."""
    return {**hud_state, "fresh": hud_state_fresh(), "synced": hud_synced(), "age_s": round(time.time() - float(hud_state.get("ts") or 0), 2)}

@app.post("/api/hud/state")
async def post_hud_state(rep: HudStateReport):
    """The HUD reports mpv's real position/duration/state (~2 Hz). Everything else reads it via current_position_s()."""
    hud_state.update({"ts": time.time(), "track_id": rep.track_id, "position_s": rep.position_s,
                      "duration_s": rep.duration_s, "is_playing": rep.is_playing,
                      "audio_rate_hz": rep.audio_rate_hz, "audio_format": rep.audio_format})
    snap = None
    with state_lock:
        if rep.duration_s and rep.track_id == runtime_state.get("active_video_id"):
            runtime_state["duration_seconds"] = int(rep.duration_s)
        # Keep the wall-clock estimate anchored so a stale HUD never jumps the position by much
        if rep.track_id == runtime_state.get("active_video_id"):
            runtime_state["position_offset_s"] = rep.position_s
            runtime_state["start_time"] = time.time()
            if runtime_state.get("pause_time"):
                runtime_state["pause_time"] = time.time()   # keep (pause_time - start_time) == 0 while paused
            if time.time() - _resume_last_write > 10.0:
                snap = _snapshot_now_locked()
    if snap:
        await asyncio.to_thread(_save_resume, snap)
    # The HUD's play state is *reported*, never adopted: intent only changes through commands. End of track
    # arrives explicitly via /api/hud/ended.
    return {"status": "ok"}


def _pipewire_audio_live() -> Dict[str, Any]:
    """What PipeWire is actually running the DAC at (rate / format) and the active streams."""
    info: Dict[str, Any] = {"sink": None, "streams": []}
    try:
        env = dict(os.environ)
        env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=4, env=env).stdout
        for o in json.loads(out):
            inf = o.get("info") or {}
            props = inf.get("props") or {}
            cls = props.get("media.class")
            # The negotiated format lives in params.Format (props.audio.rate is only set when forced)
            fmt_list = (inf.get("params") or {}).get("Format") or []
            fmt = fmt_list[0] if fmt_list and isinstance(fmt_list[0], dict) else {}
            live_rate = props.get("audio.rate") or fmt.get("rate")
            live_format = props.get("audio.format") or fmt.get("format")
            if cls == "Audio/Sink" and props.get("node.name") == "roundplayer_eq":
                info["eq_sink"] = True
                continue
            if cls == "Audio/Sink":
                name = props.get("node.name", "")
                card = str(props.get("alsa.card_name", "")) + str(props.get("node.description", ""))
                entry = {"name": name, "card": card, "rate": live_rate, "format": live_format,
                         "allowed_rates": props.get("audio.allowed-rates"), "state": inf.get("state")}
                # prefer the DAC Pro
                if info["sink"] is None or "hifiberry" in card.lower() or "dac" in card.lower():
                    info["sink"] = entry
            elif cls == "Stream/Output/Audio":
                info["streams"].append({"app": props.get("application.name"), "rate": live_rate,
                                        "format": live_format,
                                        "resample_quality": props.get("resample.quality")})
    except Exception as e:
        info["error"] = str(e)
    return info

@app.get("/api/audio/live")
async def get_audio_live():
    """Measured audio path: PipeWire sink rate/format, HUD-reported mpv output, DAC readback. For the 'bit-perfect' indicator."""
    pw = _pipewire_audio_live()
    dac = {}
    try:
        res = subprocess.run(["sudo", "-n", DACPRO_CTL, "show"], capture_output=True, text=True, timeout=3)
        in_live = False
        for line in res.stdout.splitlines():
            if "Live DAC readback:" in line:
                in_live = True; continue
            if in_live and line.strip():
                parts = line.strip().split(maxsplit=1)
                if len(parts) == 2:
                    dac[parts[0]] = parts[1]
    except Exception:
        pass
    src_rate = runtime_state.get("sample_rate_hz")
    sink_rate = (pw.get("sink") or {}).get("rate")
    eq_active = any((st.get("app") or "") == "RoundPlayer EQ" or "roundplayer_eq" in str(st.get("name") or "") for st in pw.get("streams", [])) \
        or bool(pw.get("eq_sink"))
    bit_perfect = bool(src_rate and sink_rate and int(src_rate) == int(sink_rate) and not eq_active
                       and str((pw.get("sink") or {}).get("format", "")).startswith(("S32", "S24")))
    return {"pipewire": pw, "dac": dac, "hud": {k: hud_state.get(k) for k in ("audio_rate_hz", "audio_format")}, "eq_active": eq_active,
            "boot_check": runtime_state.get("audio_check"),
            "source": {"rate_hz": src_rate, "bit_depth": runtime_state.get("bit_depth"),
                       "format": runtime_state.get("audio_format")},
            "bit_perfect": bit_perfect}


class NetworkConnectRequest(BaseModel):
    ssid: str
    psk: Optional[str] = None
    hidden: bool = False
    band: Optional[str] = None   # "5" | "2.4" | "auto" (default: saved preference, 5 GHz)

class NetworkPrefsRequest(BaseModel):
    band: Optional[str] = None          # preferred band for new/saved connections
    hotspot_band: Optional[str] = None  # "5" | "2.4"

class NetworkSsidRequest(BaseModel):
    ssid: str

class HotspotRequest(BaseModel):
    enable: bool = True

@app.get("/api/network/status")
async def network_status():
    return await asyncio.to_thread(network_manager.status)

@app.get("/api/network/scan")
async def network_scan(rescan: bool = True):
    return {"networks": await asyncio.to_thread(network_manager.scan, rescan)}

@app.get("/api/network/saved")
async def network_saved():
    return {"saved": await asyncio.to_thread(network_manager.saved)}

@app.post("/api/network/connect")
async def network_connect(req: NetworkConnectRequest):
    return await asyncio.to_thread(network_manager.connect, req.ssid, req.psk, req.hidden, req.band)

@app.get("/api/network/prefs")
async def network_prefs():
    return {"prefs": network_manager._prefs(), "regdomain": await asyncio.to_thread(network_manager.regdomain)}

@app.post("/api/network/prefs")
async def network_set_prefs(req: NetworkPrefsRequest):
    prefs = network_manager.set_prefs(band=req.band, hotspot_band=req.hotspot_band)
    # re-apply the band to the active connection so the change takes effect now
    st = await asyncio.to_thread(network_manager.status)
    ssid = ((st.get("wifi") or {}).get("ssid"))
    if ssid and not st.get("hotspot") and req.band is not None:
        await asyncio.to_thread(network_manager.connect, ssid, None, False, req.band)
    return {"status": "ok", "prefs": prefs}

@app.post("/api/network/regdomain")
async def network_regdomain():
    return await asyncio.to_thread(network_manager.ensure_regdomain)

@app.post("/api/network/forget")
async def network_forget(req: NetworkSsidRequest):
    return await asyncio.to_thread(network_manager.forget, req.ssid)

@app.post("/api/network/hotspot")
async def network_hotspot(req: HotspotRequest):
    return await asyncio.to_thread(network_manager.hotspot, req.enable)


@app.get("/api/system/ip")
async def get_system_ip():
    ip = get_lan_ip()
    return {"ip": ip, "web_url": f"http://{ip}:8080"}

@app.get("/api/system/qr.png")
async def get_system_qr():
    import io
    from fastapi.responses import Response
    ip = get_lan_ip()
    url = f"http://{ip}:8080"
    try:
        import qrcode
        qr = qrcode.QRCode(
            version=1,
            error_correction=qrcode.constants.ERROR_CORRECT_M,
            box_size=8,
            border=2,
        )
        qr.add_data(url)
        qr.make(fit=True)
        img = qr.make_image(fill_color="#00E5FF", back_color="#080D1A")
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return Response(content=buf.getvalue(), media_type="image/png")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/system/restart-services")
async def restart_services():
    subprocess.Popen(["sudo", "-n", "systemctl", "restart", "roundplayer_dial", "roundplayer_web"])
    return {"status": "restarting"}

@app.post("/api/search/history/clear")
async def clear_search_history():
    return {"status": "ok", "message": "Search history cleared"}

# --- Media Serving Endpoints ---

@app.get("/media/{video_id}/video.mp4")
async def serve_video(video_id: str):
    path = get_video_path(video_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Video file not found")
    return FileResponse(path, media_type="video/mp4")

@app.get("/media/{video_id}/audio.wav")
async def serve_audio(video_id: str):
    path = get_audio_path(video_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Audio file not found")
    return FileResponse(path, media_type="audio/wav")

@app.get("/media/{video_id}/cover.jpg")
async def serve_cover(video_id: str):
    path = get_cover_path(video_id)
    if not os.path.exists(path):
        # Fallback to generating cover on the fly
        v_path = get_video_path(video_id)
        if os.path.exists(v_path):
            subprocess.run([
                'ffmpeg', '-y', '-ss', '00:00:05', '-i', v_path,
                '-vframes', '1', '-vf', 'scale=512:512', path
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists(path):
        return FileResponse(path, media_type="image/jpeg")
    raise HTTPException(status_code=404, detail="Cover not found")

@app.get("/media/{video_id}/beats")
async def serve_beats(video_id: str):
    beats_path = get_beats_path(video_id)
    meta_path = get_meta_path(video_id)
    if not os.path.exists(beats_path) or not os.path.exists(meta_path):
        raise HTTPException(status_code=404, detail="Beats not found")
    beats_arr = np.load(beats_path).tolist()
    with open(meta_path, 'r', encoding='utf-8') as f:
        meta = json.load(f)
    return {
        "bpm": meta.get("bpm", 126.2),
        "beat_count": len(beats_arr),
        "beats": beats_arr
    }

@app.get("/media/{video_id}/dominant_color")
async def get_color(video_id: str):
    meta_path = get_meta_path(video_id)
    if os.path.exists(meta_path):
        with open(meta_path, 'r', encoding='utf-8') as f:
            meta = json.load(f)
        if "dominant_color" in meta:
            return {"color": meta["dominant_color"]}
        c = extract_dominant_color(get_video_path(video_id))
        meta["dominant_color"] = c
        with open(meta_path, 'w', encoding='utf-8') as f:
            json.dump(meta, f, indent=2)
        return {"color": c}

@app.websocket("/ws/telemetry")
async def websocket_telemetry(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            t_now = time.time()
            timestamp_us = int(t_now * 1e6)
            with state_lock:
                live_bpm = runtime_state.get("current_bpm", 126.2)
                is_playing = runtime_state.get("is_playing", True)
                active_id = runtime_state.get("active_video_id", "standby")
                title = runtime_state.get("title", "")
                artist = runtime_state.get("artist", "")
                color = runtime_state.get("dominant_color", "#00E5FF")
                vol = runtime_state.get("volume", 80.0)

            beat_freq = (live_bpm / 60.0) if live_bpm > 0 else (103.0 / 60.0)
            phase = (t_now * beat_freq * 2.0 * np.pi) % (2.0 * np.pi) if is_playing else 0.0

            telemetry = {
                "timestamp_us": timestamp_us,
                "track_id": active_id,
                "title": title,
                "artist": artist,
                "bpm": round(live_bpm, 1),
                "beat_phase": round(phase / (2.0 * np.pi), 3),
                "is_playing": is_playing,
                "dominant_color": color,
                "volume": vol,
                "hifi_catalog_version": runtime_state.get("hifi_catalog_version", 1),
                "hifi_sync_status": runtime_state.get("hifi_sync_status", "idle")
            }
            await websocket.send_json(telemetry)
            await asyncio.sleep(1.0 / 60.0)
    except (WebSocketDisconnect, Exception):
        pass

# --- Hi-Fi Lossless API & Google Drive Ingestion Endpoints ---

@app.get("/api/hifi/tree")
async def get_hifi_tree():
    import hifi_manager
    return hifi_manager.scan_library()

@app.get("/api/hifi/search")
async def search_hifi_endpoint(q: str = "", limit: int = 50):
    import hifi_manager
    return hifi_manager.search_library(query=q, limit=limit)

def run_background_sync(folder_url: Optional[str] = None):
    import sync_gdrive
    with state_lock:
        if runtime_state.get("hifi_sync_status") == "syncing":
            return
        runtime_state["hifi_sync_status"] = "syncing"
        runtime_state["hifi_sync_message"] = "Scanning Google Drive folders in parallel..."
    try:
        print(f"[Drive Sync] Starting background sync (url: {folder_url or 'default/saved'})...")
        sync_gdrive.sync(new_folder_url=folder_url)
        with state_lock:
            runtime_state["hifi_sync_status"] = "ready"
            runtime_state["hifi_sync_message"] = "Library updated successfully."
        trigger_catalog_update_broadcast()
        print("[Drive Sync] Successfully synced and updated library.")
    except Exception as e:
        print(f"[Drive Sync Error] {e}")
        with state_lock:
            runtime_state["hifi_sync_status"] = "error"
            runtime_state["hifi_sync_message"] = str(e)

@app.post("/api/hifi/scan")
async def trigger_hifi_scan():
    import hifi_manager
    threading.Thread(target=run_background_sync, daemon=True).start()
    return hifi_manager.scan_library(force=True)

@app.get("/api/hifi/cover")
async def get_hifi_cover(track_id: Optional[str] = None, rel_path: Optional[str] = None, key: Optional[str] = None):
    """Album cover: local file, else Drive, else the picture embedded in a cached track, else iTunes/Deezer lookup
    (cached under /data/hifi_music/covers, misses remembered for a week). Resolved off the event loop."""
    path = await asyncio.to_thread(hifi_manager.resolve_cover, key, rel_path, track_id)
    if path and os.path.isfile(path):
        return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "max-age=86400"})
    raise HTTPException(status_code=404, detail="Cover not found")

@app.get("/media/hifi/{track_id}/stream")
async def stream_hifi_track(track_id: str):
    """Serves a cached Hi-Fi file. Never downloads inline (that used to freeze the whole daemon for the duration of a
    Drive download): the HUD only opens this URL after the daemon's 'load' command, i.e. once the file is on disk."""
    clean_id = track_id.replace("hifi_", "")
    fpath = await asyncio.to_thread(hifi_manager.get_track_file_path, clean_id)
    if not fpath or not os.path.isfile(fpath):
        raise HTTPException(status_code=409, detail="Track not cached yet - POST /api/hifi/play first")
    media_type = "audio/flac" if fpath.endswith(".flac") else ("audio/x-dsf" if fpath.endswith(".dsf") else "audio/mpeg")
    return FileResponse(fpath, media_type=media_type)

@app.get("/media/hifi/{track_id}/beats")
async def get_hifi_beats(track_id: str):
    import hifi_manager
    clean_id = track_id.replace("hifi_", "")
    fpath = hifi_manager.get_track_file_path(clean_id)
    if not fpath:
        raise HTTPException(status_code=404, detail="Track not found")
    return hifi_manager.get_or_create_beats(fpath)

@app.get("/api/hifi/cache/stats")
async def get_hifi_cache_stats():
    import hifi_manager
    return hifi_manager.get_cache_stats()

@app.post("/api/hifi/cache/prune")
async def post_hifi_cache_prune():
    import hifi_manager
    hifi_manager.check_and_prune_cache()
    return hifi_manager.get_cache_stats()

class HiFiPlayRequest(BaseModel):
    track_id: str

def _log_switch_away(new_id: Optional[str], user: bool = True) -> None:
    """Play log: the active Hi-Fi track is being left. Finished = reached the end (logged in hud_ended); here we log
    a skip when the user moves on early (< 20 s in, or before half of it) and a partial play otherwise."""
    try:
        active = runtime_state.get("active_video_id")
        if not active or active == "standby" or not active.startswith("hifi_") or active == new_id:
            return
        pos = current_position_s()
        dur = float(runtime_state.get("duration_seconds") or 0)
        skipped = user and (pos < 20.0 or (dur > 0 and pos < 0.5 * dur))
        library_db.record_play(active, completed=False, skipped=skipped, listened_s=pos)
    except Exception as e:
        print(f"[Play log] {e}")


@app.post("/api/hifi/play")
async def play_hifi_endpoint(req: HiFiPlayRequest):
    _log_switch_away(req.track_id)
    return await asyncio.to_thread(activate_hifi_track, req.track_id)

@app.post("/api/prepare/cancel")
async def cancel_prepare_endpoint():
    return cancel_preparing()

class CastSendersReport(BaseModel):
    senders: List[str] = []

@app.post("/api/cast/senders")
async def cast_senders(rep: CastSendersReport):
    """yt-cast-receiver reports the phones currently connected (for the HUD's CASTING pill)."""
    with state_lock:
        runtime_state["cast_senders"] = list(rep.senders)
    return {"status": "ok", "senders": rep.senders}

def up_next() -> Optional[Dict[str, Any]]:
    """What plays after the current track: head of the queue, else the next album track (Hi-Fi). Cached per track."""
    global _up_next_cache
    with queue_lock:
        head = playback_queue[0] if playback_queue else None
    active = runtime_state.get("active_video_id")
    key = (active, (head or {}).get("video_id") or (head or {}).get("track_id"), runtime_state.get("repeat"), runtime_state.get("shuffle"))
    if _up_next_cache and _up_next_cache[0] == key:
        return _up_next_cache[1]
    result: Optional[Dict[str, Any]] = None
    if head:
        hid = str(head.get("video_id") or head.get("track_id") or "")
        result = {"track_id": hid, "title": head.get("title") or hid, "artist": head.get("artist") or "", "source": "queue"}
    elif active and active.startswith("hifi_"):
        try:
            album_tracks, idx = hifi_manager.get_album_tracks_for_track(active.replace("hifi_", ""))
            nxt = None
            if album_tracks and idx >= 0:
                if runtime_state.get("shuffle") and len(album_tracks) > 1:
                    import random
                    pool = [i for i in range(len(album_tracks)) if i != idx]
                    nxt = album_tracks[random.choice(pool)]   # chosen once per track (cached below) so prefetch and play agree
                elif idx + 1 < len(album_tracks):
                    nxt = album_tracks[idx + 1]
                elif runtime_state.get("repeat") == "all":
                    nxt = album_tracks[0]
            if nxt:
                result = {"track_id": "hifi_" + str(nxt.get("track_id")), "title": nxt.get("title"), "artist": nxt.get("artist"), "source": "album"}
        except Exception:
            result = None
    if result and result["track_id"] == active:
        result["same"] = True   # repeat-all on a one-track album: nothing new to announce or pre-open
    if result and result["track_id"].startswith("hifi_"):
        # Gapless needs the file on disk: the HUD only pre-opens tracks the stream endpoint can serve at once
        try:
            fp = hifi_manager.get_track_file_path(result["track_id"][5:])
            result["ready"] = bool(fp and os.path.isfile(fp) and os.path.getsize(fp) > 1000)
        except Exception:
            result["ready"] = False
    _up_next_cache = (key, result)
    return result

_up_next_cache = None

class HudEndedReport(BaseModel):
    track_id: Optional[str] = None

@app.post("/api/hud/ended")
async def hud_ended(rep: HudEndedReport):
    """mpv reached the end of the active track. Repeat-one replays it; otherwise the queue / album / autoplay decides."""
    with state_lock:
        active = runtime_state.get("active_video_id")
        if rep.track_id and active != rep.track_id:
            return {"status": "ignored", "active": active}
        if active and active.startswith("hifi_"):
            try:
                library_db.record_play(active, completed=True, listened_s=float(runtime_state.get("duration_seconds") or current_position_s()))
            except Exception:
                pass
        if runtime_state.get("repeat") == "one" and active and active != "standby":
            runtime_state["start_time"] = time.time()
            runtime_state["position_offset_s"] = 0.0
            runtime_state["is_playing"] = True
            runtime_state["pause_time"] = None
            _issue_cmd_locked("load", track_id=active, source=_source_of(active), position_s=0.0, playing=True)
            return {"status": "repeat_one"}
    return await play_next_in_queue()

class HudAdvancedReport(BaseModel):
    track_id: str
    previous: Optional[str] = None

@app.post("/api/hud/advanced")
async def hud_advanced(rep: HudAdvancedReport):
    """Gapless: mpv moved on its own into the track the HUD pre-opened. If it is the one we planned, adopt it as
    active without a load command (no gap, no re-open); otherwise fall back to the normal end-of-track path."""
    with state_lock:
        active = runtime_state.get("active_video_id")
        planned = up_next()
        if rep.previous and active != rep.previous:
            return {"status": "ignored", "active": active}
        if runtime_state.get("repeat") == "one":
            planned = None
    if planned and planned.get("track_id") == rep.track_id and rep.track_id.startswith("hifi_"):
        if rep.previous and rep.previous.startswith("hifi_"):
            try:
                library_db.record_play(rep.previous, completed=True, listened_s=float(runtime_state.get("duration_seconds") or 0))
            except Exception:
                pass
        clean = rep.track_id[5:]
        track = hifi_manager.find_track_by_id(clean)
        fp = hifi_manager.get_track_file_path(clean)
        if track and fp and os.path.isfile(fp):
            if planned.get("source") == "queue":
                with queue_lock:
                    if playback_queue and str(playback_queue[0].get("video_id") or playback_queue[0].get("track_id") or "") == rep.track_id:
                        playback_queue.pop(0)
            out = await asyncio.to_thread(_activate_hifi_ready, clean, track, fp, 0.0, False)
            return {"status": "adopted", **{k: out.get(k) for k in ("title", "artist", "track_id") if k in out}}
    # Not what we planned (queue changed under it, repeat-one, ...): decide properly and command the HUD
    res = await hud_ended(HudEndedReport(track_id=rep.previous or active))
    return {"status": "corrected", "result": res}

@app.post("/api/resume")
async def resume_endpoint():
    return resume_from_idle()

# ---- Sleep timer (fade then standby) and alarm (fade-in wake) ----------------------------------------------
def _set_dac_db(db: float) -> None:
    try:
        subprocess.run(["sudo", DACPRO_CTL, "set", "volume", f"{max(VOL_MIN_DB, min(0.0, db)):.1f}"], capture_output=True, text=True, timeout=6)
    except Exception:
        pass


async def _fade_to(target_pct: float, seconds: float, publish: bool = True) -> None:
    """Move the DAC volume smoothly from the current slider value to target_pct over `seconds` (perceptual steps)."""
    start = float(runtime_state.get("volume", 100.0))
    steps = max(1, int(seconds / 0.5))
    for i in range(1, steps + 1):
        pct = start + (target_pct - start) * i / steps
        await asyncio.to_thread(_set_dac_db, _pct_to_db(pct))
        if publish:
            with state_lock:
                runtime_state["volume"] = pct
        await asyncio.sleep(seconds / steps)


class SleepTimerRequest(BaseModel):
    minutes: Optional[float] = None   # None / 0 = cancel


@app.post("/api/sleep_timer")
async def set_sleep_timer(req: SleepTimerRequest):
    with state_lock:
        if not req.minutes or req.minutes <= 0:
            runtime_state["sleep_at"] = None
            return {"status": "ok", "sleep_at": None}
        runtime_state["sleep_at"] = time.time() + float(req.minutes) * 60.0
        return {"status": "ok", "sleep_at": runtime_state["sleep_at"], "minutes": req.minutes}


@app.get("/api/sleep_timer")
async def get_sleep_timer():
    sa = runtime_state.get("sleep_at")
    return {"sleep_at": sa, "remaining_s": max(0.0, sa - time.time()) if sa else None}


async def sleep_timer_loop():
    while True:
        await asyncio.sleep(1)
        try:
            sa = runtime_state.get("sleep_at")
            if not sa:
                continue
            remaining = sa - time.time()
            if remaining > 60:
                continue
            # Last minute: fade out, then standby, then put the volume back so the morning is not silent
            saved = float(runtime_state.get("volume", 100.0))
            with state_lock:
                runtime_state["sleep_at"] = None
            if runtime_state.get("active_video_id") != "standby" and runtime_state.get("is_playing"):
                await _fade_to(max(0.0, saved * 0.08), max(5.0, remaining), publish=False)
            with state_lock:
                _supersede_preparing_locked(None)
                _enter_idle_locked()
            await asyncio.sleep(0.5)
            await asyncio.to_thread(_set_dac_db, _pct_to_db(saved))
            print(f"[Sleep timer] faded out and slept; volume restored to {saved:.0f}%")
        except Exception as e:
            print(f"[Sleep timer] error: {e}")


def _alarm_cfg() -> Dict[str, Any]:
    a = load_settings().get("alarm") or {}
    return {"enabled": bool(a.get("enabled", False)), "time": str(a.get("time", "07:30")), "days": a.get("days", [0, 1, 2, 3, 4]),
            "source": a.get("source", "last"), "volume_pct": float(a.get("volume_pct", 45)), "fade_s": float(a.get("fade_s", 60))}


_alarm_fired_key = ""


async def alarm_loop():
    """Wake to music: at the set time, start quietly and fade up over a minute. days: 0 = Monday."""
    global _alarm_fired_key
    while True:
        await asyncio.sleep(20)
        try:
            a = _alarm_cfg()
            if not a["enabled"]:
                continue
            now = datetime.now()
            key = now.strftime("%Y-%m-%d ") + a["time"]
            if now.strftime("%H:%M") != a["time"] or key == _alarm_fired_key:
                continue
            days = a["days"] if isinstance(a["days"], list) else list(range(7))
            if days and now.weekday() not in days:
                continue
            _alarm_fired_key = key
            print(f"[Alarm] firing ({a['source']}) at {a['time']}")
            target = a["volume_pct"]
            await asyncio.to_thread(_set_dac_db, _pct_to_db(max(2.0, target * 0.1)))
            with state_lock:
                runtime_state["volume"] = max(2.0, target * 0.1)
            started = False
            src = a["source"]
            if src == "favorites":
                try:
                    r = await play_playlist_endpoint("favorites", PlaylistPlayRequest(shuffle=True))
                    started = r.get("status") in ("playing", "preparing", "ok")
                except Exception as e:
                    print(f"[Alarm] favorites failed: {e}")
            if not started and src in ("similar", "favorites"):
                try:
                    last = runtime_state.get("last_idle_track") or {}
                    seed = last.get("track_id")
                    if seed:
                        r = await similar_play_endpoint(MixPlayRequest(track_id=seed, limit=30))
                        started = r.get("status") in ("playing", "preparing")
                except Exception as e:
                    print(f"[Alarm] similar failed: {e}")
            if not started:
                res = resume_from_idle()
                if res.get("resumed"):
                    with state_lock:
                        runtime_state["is_playing"] = True
                        runtime_state["pause_time"] = None
                        _issue_cmd_locked("play", track_id=runtime_state.get("active_video_id"), playing=True)
                    started = True
                else:
                    flat = hifi_manager.get_flat_tracks()
                    if flat:
                        await asyncio.to_thread(activate_hifi_track, "hifi_" + str(flat[0].get("track_id")))
                        started = True
            if started:
                await _fade_to(target, a["fade_s"])
        except Exception as e:
            print(f"[Alarm] error: {e}")


# ---- Settings backup: one JSON bundle of everything that makes this box *this* box ------------------------
BACKUP_HELPER = "/usr/local/bin/roundplayer-backup"
BACKUP_DIR = "/data/backups" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "backups")
_backup_last_hash = ""


def build_backup() -> Dict[str, Any]:
    def rd(path):
        try:
            return json.load(open(path))
        except Exception:
            return None
    playlists = {}
    try:
        pdir = hifi_playlists.get_active_dir()
        for fn in sorted(os.listdir(pdir)):
            if fn.endswith(".json"):
                playlists[fn] = rd(os.path.join(pdir, fn))
    except Exception:
        pass
    return {
        "format": "roundplayer-backup/1",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "settings": rd(SETTINGS_FILE),
        "display": rd("/data/roundplayer_display.json"),
        "dacpro": rd(DACPRO_CONF),
        "wifi_prefs": rd("/data/roundplayer_wifi.json"),
        "playlists": playlists,
        "history": rd(HISTORY_FILE),
    }


def restore_backup(b: Dict[str, Any], restart_audio: bool = True) -> Dict[str, Any]:
    if not isinstance(b, dict) or str(b.get("format", "")).startswith("roundplayer-backup") is False:
        raise ValueError("not a roundplayer backup")
    done = []
    if isinstance(b.get("settings"), dict):
        save_settings(b["settings"]); done.append("settings")
    if isinstance(b.get("display"), dict):
        _write_json_atomic("/data/roundplayer_display.json" if os.path.isdir("/data") else "roundplayer_display.json", b["display"]); done.append("display")
        try:
            _display_ctl("apply")
        except Exception:
            pass
    if isinstance(b.get("wifi_prefs"), dict) and os.path.isdir("/data"):
        _write_json_atomic("/data/roundplayer_wifi.json", b["wifi_prefs"]); done.append("wifi_prefs")
    if isinstance(b.get("playlists"), dict):
        pdir = hifi_playlists.get_active_dir(); os.makedirs(pdir, exist_ok=True)
        for fn, data in b["playlists"].items():
            if fn.endswith(".json") and "/" not in fn and isinstance(data, dict):
                _write_json_atomic(os.path.join(pdir, fn), data)
        done.append(f"playlists({len(b['playlists'])})")
    if isinstance(b.get("history"), list):
        with _history_lock:
            _write_json_atomic(HISTORY_FILE, b["history"][:200])
        done.append("history")
    if isinstance(b.get("dacpro"), dict):
        d = dict(b["dacpro"]); eq = d.pop("eq", None)
        try:
            # dacpro-ctl validates each option; EQ goes through eq-json
            for k, v in d.items():
                subprocess.run(["sudo", "-n", DACPRO_CTL, "set", str(k), str(v), "--no-restart"], capture_output=True, text=True, timeout=20)
            if isinstance(eq, dict):
                subprocess.run(["sudo", "-n", DACPRO_CTL, "set", "eq-json", json.dumps(eq)], capture_output=True, text=True, timeout=30)
            if restart_audio:
                subprocess.run(["sudo", "-n", DACPRO_CTL, "apply", "--with-pipewire"], capture_output=True, text=True, timeout=40)
            done.append("dacpro")
        except Exception as e:
            done.append(f"dacpro failed: {e}")
    return {"status": "ok", "restored": done}


def write_backup_files(bundle: Dict[str, Any]) -> Dict[str, Any]:
    os.makedirs(BACKUP_DIR, exist_ok=True)
    latest = os.path.join(BACKUP_DIR, "latest.json")
    _write_json_atomic(latest, bundle)
    out = {"local": latest, "sdcard": None}
    try:
        r = subprocess.run(["sudo", "-n", BACKUP_HELPER, "put", latest], capture_output=True, text=True, timeout=20)
        if r.returncode == 0:
            out["sdcard"] = json.loads(r.stdout.strip().splitlines()[-1]).get("path")
        else:
            out["sdcard_error"] = (r.stderr or r.stdout).strip()[-200:]
    except Exception as e:
        out["sdcard_error"] = str(e)
    return out


def backup_loop_tick() -> Optional[Dict[str, Any]]:
    """Called every few minutes: if anything changed, write a fresh bundle locally and onto the boot partition."""
    global _backup_last_hash
    b = build_backup()
    b2 = dict(b); b2.pop("created_at", None); b2.pop("history", None)
    h = str(hash(json.dumps(b2, sort_keys=True, default=str)))
    if h == _backup_last_hash:
        return None
    _backup_last_hash = h
    return write_backup_files(b)


async def backup_loop():
    await asyncio.sleep(90)
    while True:
        try:
            r = await asyncio.to_thread(backup_loop_tick)
            if r:
                print(f"[Backup] updated: {r}")
        except Exception as e:
            print(f"[Backup] failed: {e}")
        await asyncio.sleep(300)


def restore_from_sdcard_if_fresh() -> None:
    """Fresh /data (new SD card image) + a bundle on the boot partition = this is the same box being rebuilt."""
    if os.path.exists(SETTINGS_FILE):
        return
    try:
        r = subprocess.run(["sudo", "-n", BACKUP_HELPER, "get"], capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            res = restore_backup(json.loads(r.stdout), restart_audio=False)
            print(f"[Backup] restored from the SD card's boot partition: {res}")
    except Exception as e:
        print(f"[Backup] restore check failed: {e}")


@app.get("/api/backup")
async def get_backup():
    return await asyncio.to_thread(build_backup)

@app.post("/api/backup/save")
async def save_backup_now():
    b = await asyncio.to_thread(build_backup)
    return await asyncio.to_thread(write_backup_files, b)

@app.get("/api/backup/status")
async def backup_status():
    latest = os.path.join(BACKUP_DIR, "latest.json")
    st = {"local": None, "sdcard": None}
    try:
        st["local"] = datetime.fromtimestamp(os.path.getmtime(latest), timezone.utc).isoformat()
    except Exception:
        pass
    try:
        r = subprocess.run(["sudo", "-n", BACKUP_HELPER, "get"], capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            st["sdcard"] = json.loads(r.stdout).get("created_at")
    except Exception:
        pass
    return st

@app.post("/api/backup/restore")
async def restore_backup_endpoint(bundle: Dict[str, Any]):
    try:
        return await asyncio.to_thread(restore_backup, bundle)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

# ---- External sources: AirPlay (shairport-sync) and Spotify Connect (librespot) --------------------------
# Both play straight into PipeWire (pulse backend), so the EQ / DAC path is shared. The daemon only needs to know a
# session started/ended and what is on, so the panel shows it and the box's own playback steps aside.
EXT_COVER = "/data/external_cover.jpg" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "external_cover.jpg")
EXT_NAMES = {"airplay": "AirPlay", "spotify": "Spotify Connect"}


class ExternalMeta(BaseModel):
    title: Optional[str] = None
    artist: Optional[str] = None
    album: Optional[str] = None
    duration_s: Optional[float] = None
    position_s: Optional[float] = None
    playing: Optional[bool] = None
    cover_b64: Optional[str] = None
    cover_url: Optional[str] = None
    device: Optional[str] = None


def _ext_id(name: str) -> str:
    return f"ext:{name}"


@app.post("/api/source/{name}/start")
async def external_start(name: str, meta: Optional[ExternalMeta] = None):
    if name not in EXT_NAMES:
        raise HTTPException(status_code=404, detail="unknown source")
    eid = _ext_id(name)
    with state_lock:
        active = runtime_state.get("active_video_id")
        if active != eid:
            if active and active != "standby" and not str(active).startswith("ext:"):
                runtime_state["last_idle_track"] = _snapshot_now_locked()
                _save_resume(runtime_state["last_idle_track"])
            _supersede_preparing_locked(None)
            _issue_cmd_locked("stop", playing=False)
            runtime_state["active_video_id"] = eid
            runtime_state["title"] = (meta.title if meta and meta.title else EXT_NAMES[name])
            runtime_state["artist"] = (meta.artist if meta and meta.artist else (meta.device if meta and meta.device else ""))
            runtime_state["album"] = (meta.album if meta and meta.album else "")
            runtime_state["is_hifi"] = False
            runtime_state["audio_format"] = "AIRPLAY" if name == "airplay" else "OGG"
            runtime_state["bit_depth"] = 16
            runtime_state["sample_rate_hz"] = 44100
            runtime_state["external"] = {"source": name, "device": (meta.device if meta else None), "started": time.time()}
            try:
                os.remove(EXT_COVER)
            except OSError:
                pass
        runtime_state["is_playing"] = True
        runtime_state["pause_time"] = None
        runtime_state["start_time"] = time.time()
        runtime_state["position_offset_s"] = float(meta.position_s or 0.0) if meta else 0.0
        runtime_state["duration_seconds"] = int(meta.duration_s or 0) if meta else 0
    print(f"[{EXT_NAMES[name]}] session started")
    return {"status": "ok", "active": eid}


@app.post("/api/source/{name}/meta")
async def external_meta(name: str, meta: ExternalMeta):
    eid = _ext_id(name)
    with state_lock:
        if runtime_state.get("active_video_id") != eid:
            return {"status": "ignored"}
        if meta.title:
            runtime_state["title"] = meta.title
        if meta.artist is not None:
            runtime_state["artist"] = meta.artist
        if meta.album is not None:
            runtime_state["album"] = meta.album
        if meta.duration_s:
            runtime_state["duration_seconds"] = int(meta.duration_s)
        if meta.position_s is not None:
            runtime_state["position_offset_s"] = float(meta.position_s)
            runtime_state["start_time"] = time.time()
            if runtime_state.get("pause_time"):
                runtime_state["pause_time"] = time.time()
        if meta.playing is not None:
            runtime_state["is_playing"] = bool(meta.playing)
            runtime_state["pause_time"] = None if meta.playing else time.time()
            if meta.playing and not meta.position_s:
                runtime_state["start_time"] = time.time()
    if meta.cover_b64:
        try:
            import base64
            data = base64.b64decode(meta.cover_b64)
            if len(data) > 1000:
                tmp = EXT_COVER + ".tmp"
                open(tmp, "wb").write(data)
                os.replace(tmp, EXT_COVER)
                try:
                    with state_lock:
                        runtime_state["dominant_color"] = extract_dominant_color(EXT_COVER)
                except Exception:
                    pass
        except Exception as e:
            print(f"[{EXT_NAMES.get(name, name)}] cover failed: {e}")
    elif meta.cover_url:
        def fetch(u=meta.cover_url):
            try:
                req = urllib.request.Request(u, headers={"User-Agent": "RoundPlayer/1.0"})
                with urllib.request.urlopen(req, timeout=8) as r:
                    data = r.read()
                if len(data) > 1000:
                    tmp = EXT_COVER + ".tmp"
                    open(tmp, "wb").write(data)
                    os.replace(tmp, EXT_COVER)
                    col = extract_dominant_color(EXT_COVER)
                    with state_lock:
                        runtime_state["dominant_color"] = col
            except Exception as e:
                print(f"[{EXT_NAMES.get(name, name)}] cover fetch failed: {e}")
        threading.Thread(target=fetch, daemon=True).start()
    return {"status": "ok"}


@app.post("/api/source/{name}/stop")
async def external_stop(name: str):
    eid = _ext_id(name)
    with state_lock:
        if runtime_state.get("active_video_id") != eid:
            return {"status": "ignored"}
        runtime_state["external"] = None
        runtime_state["is_playing"] = False
        runtime_state["pause_time"] = time.time()
        runtime_state["active_video_id"] = "standby"
        runtime_state["title"] = "Standby"
        runtime_state["artist"] = ""
        runtime_state["album"] = ""
    print(f"[{EXT_NAMES.get(name, name)}] session ended")
    return {"status": "ok"}


@app.get("/api/sources/status")
async def sources_status():
    uid = os.getuid()
    env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{uid}", DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{uid}/bus")
    def state(unit):
        try:
            return subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True, timeout=4, env=env).stdout.strip() or "unknown"
        except Exception:
            return "unknown"
    out = await asyncio.to_thread(lambda: {"airplay": state("shairport-sync.service"), "airplay_meta": state("airplay-meta.service"), "spotify": state("librespot.service")})
    out["active"] = (runtime_state.get("external") or {}).get("source")
    out["mqtt"] = bool((load_settings().get("mqtt") or {}).get("enabled"))
    return out


@app.get("/api/external/cover")
async def external_cover():
    if os.path.isfile(EXT_COVER):
        return FileResponse(EXT_COVER, media_type="image/jpeg", headers={"Cache-Control": "no-cache"})
    raise HTTPException(status_code=404, detail="no cover")


# ---- MQTT / Home Assistant --------------------------------------------------------------------------------
def _mqtt_state() -> Dict[str, Any]:
    sa = runtime_state.get("sleep_at")
    return {"title": runtime_state.get("title"), "artist": runtime_state.get("artist"), "album": runtime_state.get("album"),
            "track_id": runtime_state.get("active_video_id"), "is_playing": bool(runtime_state.get("is_playing")),
            "volume": float(runtime_state.get("volume", 100.0)), "is_hifi": bool(runtime_state.get("is_hifi")),
            "format": runtime_state.get("audio_format"), "sample_rate_hz": runtime_state.get("sample_rate_hz"),
            "sleep_in_min": int(max(0, sa - time.time()) / 60) if sa else 0, "source": (runtime_state.get("external") or {}).get("source") or ("hifi" if runtime_state.get("is_hifi") else "youtube"),
            "standby": runtime_state.get("active_video_id") == "standby"}


def _mqtt_command(entity: str, value: Any) -> None:
    loop = _main_loop
    def run(coro):
        if loop:
            asyncio.run_coroutine_threadsafe(coro, loop)
    if entity == "playing":
        run(handle_control(ControlCommand(action="play" if str(value).upper() == "ON" else "pause")))
    elif entity == "volume":
        run(set_hardware_dac_volume({"volume_pct": float(value)}))
    elif entity == "next":
        run(play_next_in_queue_endpoint())
    elif entity == "previous":
        run(play_prev_in_history())
    elif entity == "sleep":
        run(handle_control(ControlCommand(action="idle")))
    elif entity == "sleep_timer":
        run(set_sleep_timer(SleepTimerRequest(minutes=float(value) if value not in ("", "0", "off") else None)))


_main_loop: Optional[asyncio.AbstractEventLoop] = None


def start_mqtt_from_settings() -> bool:
    return mqtt_bridge.start(_mqtt_state, _mqtt_command, load_settings().get("mqtt") or {})


# ---- Software update (OTA): roundplayer-update runs in its own transient user unit so restarting this daemon
# does not kill it half way.
UPDATE_STATUS = "/data/update/status.json"


def _update_spawn(verb: str) -> Dict[str, Any]:
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "roundplayer-update")
    uid = os.getuid()
    env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{uid}", DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{uid}/bus")
    unit = f"roundplayer-update-{int(time.time())}"
    r = subprocess.run(["systemd-run", "--user", "--collect", f"--unit={unit}", "/bin/bash", script, verb],
                       capture_output=True, text=True, timeout=15, env=env)
    if r.returncode != 0:
        return {"status": "error", "message": (r.stderr or r.stdout).strip()[-300:]}
    return {"status": "started", "unit": unit}


@app.get("/api/update/status")
async def update_status():
    try:
        d = json.load(open(UPDATE_STATUS))
    except Exception:
        d = {"state": "idle"}
    d["current_version"] = _read(os.path.join(os.path.dirname(os.path.abspath(__file__)), "VERSION")) or "dev"
    d["url"] = (load_settings().get("update") or {}).get("url") or ""
    d["can_rollback"] = os.path.isdir(os.path.expanduser("~/roundplayer.prev"))
    return d


@app.post("/api/update/start")
async def update_start():
    if not (load_settings().get("update") or {}).get("url"):
        raise HTTPException(status_code=400, detail="Set an update URL first")
    return await asyncio.to_thread(_update_spawn, "start")


@app.post("/api/update/rollback")
async def update_rollback():
    return await asyncio.to_thread(_update_spawn, "rollback")


# ---- Health / diagnostics + systemd watchdog ----------------------------------------------------------------
BOOT_TS = time.time()


def _read(path: str) -> str:
    try:
        return open(path).read().strip()
    except Exception:
        return ""


def _cpu_temp() -> Optional[float]:
    v = _read("/sys/class/thermal/thermal_zone0/temp")
    try:
        return round(int(v) / 1000.0, 1)
    except Exception:
        return None


def _throttled() -> Optional[str]:
    try:
        r = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=3)
        return r.stdout.strip().split("=")[-1] if r.returncode == 0 else None
    except Exception:
        return None


def _wifi() -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    try:
        r = subprocess.run(["iw", "dev", "wlan0", "link"], capture_output=True, text=True, timeout=3).stdout
        m = re.search(r"SSID: (.+)", r); out["ssid"] = m.group(1).strip() if m else None
        m = re.search(r"signal: (-?\d+) dBm", r); out["rssi_dbm"] = int(m.group(1)) if m else None
        m = re.search(r"freq: (\d+)", r); out["freq_mhz"] = int(m.group(1)) if m else None
        m = re.search(r"tx bitrate: ([\d.]+ MBit/s)", r); out["tx_rate"] = m.group(1) if m else None
    except Exception:
        pass
    return out


def health_snapshot() -> Dict[str, Any]:
    st = os.statvfs("/data") if os.path.isdir("/data") else os.statvfs("/")
    mem = {}
    for line in _read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        if k in ("MemTotal", "MemAvailable"):
            mem[k] = int(v.strip().split()[0]) // 1024
    load = os.getloadavg()
    hs = hud_state_fresh()
    return {
        "ok": True, "uptime_s": int(time.time() - BOOT_TS), "system_uptime_s": int(float(_read("/proc/uptime").split()[0] or 0)),
        "cpu_temp_c": _cpu_temp(), "throttled": _throttled(), "load": [round(x, 2) for x in load],
        "mem_mb": {"total": mem.get("MemTotal"), "available": mem.get("MemAvailable")},
        "disk_free_gb": round(st.f_bavail * st.f_frsize / 1e9, 2), "disk_total_gb": round(st.f_blocks * st.f_frsize / 1e9, 2),
        "wifi": _wifi(), "hud_fresh": hs, "hud_synced": hud_synced(),
        "active": runtime_state.get("active_video_id"), "is_playing": runtime_state.get("is_playing"),
        "audio_check": runtime_state.get("audio_check"), "library_tracks": _safe_count(),
        "version": _read(os.path.join(os.path.dirname(os.path.abspath(__file__)), "VERSION")) or "dev",
    }


def _safe_count() -> Optional[int]:
    try:
        return library_db.count()
    except Exception:
        return None


@app.get("/api/health")
async def health_endpoint():
    return await asyncio.to_thread(health_snapshot)


@app.get("/api/health/log")
async def health_log(n: int = 60):
    return {"lines": list(_log_ring.lines)[-max(1, min(300, n)):]}


async def ytdlp_update_loop():
    """YouTube changes break old yt-dlp releases every few weeks: upgrade it weekly (takes effect on the next
    daemon restart / reboot - never mid-stream)."""
    await asyncio.sleep(600)
    stamp = "/data/.ytdlp_updated" if os.path.isdir("/data") else ".ytdlp_updated"
    while True:
        try:
            last = os.path.getmtime(stamp) if os.path.exists(stamp) else 0
            if time.time() - last > 7 * 86400:
                r = await asyncio.to_thread(subprocess.run, [sys.executable, "-m", "pip", "install", "-U", "--user", "--break-system-packages", "-q", "yt-dlp[default]"],
                                            capture_output=True, text=True, timeout=600)
                print(f"[yt-dlp] weekly update: {'ok' if r.returncode == 0 else (r.stderr or r.stdout)[-200:]}")
                open(stamp, "w").write(str(time.time()))
        except Exception as e:
            print(f"[yt-dlp] update failed: {e}")
        await asyncio.sleep(6 * 3600)


async def watchdog_loop():
    """systemd WatchdogSec: as long as the event loop turns we say so; a hung daemon gets restarted by systemd."""
    sock_path = os.environ.get("NOTIFY_SOCKET")
    if not sock_path:
        return
    addr = "\0" + sock_path[1:] if sock_path.startswith("@") else sock_path
    import socket as _socket
    while True:
        try:
            s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_DGRAM)
            s.connect(addr)
            s.sendall(b"WATCHDOG=1")
            s.close()
        except Exception:
            pass
        await asyncio.sleep(15)


@app.get("/api/resume/info")
async def resume_info():
    """What a wake would bring back (for the Home screen's 'Continue listening')."""
    with state_lock:
        last = runtime_state.get("last_idle_track")
        active = runtime_state.get("active_video_id")
    if not last:
        return {"available": False}
    return {"available": active == "standby", "track_id": last.get("track_id"), "title": last.get("title"), "artist": last.get("artist"),
            "album": last.get("album"), "position_s": last.get("position_s"), "duration_seconds": last.get("duration_seconds"), "is_hifi": last.get("is_hifi")}

@app.get("/api/history")
async def history_endpoint(limit: int = 30):
    return {"items": await asyncio.to_thread(recently_played, max(1, min(200, limit)))}

def _autoplay_pick(seed_id: str) -> Optional[Dict[str, Any]]:
    """One track that goes with the seed, avoiding what played recently (never raises; called under queue_lock)."""
    try:
        import similar
        tracks = []
        for window in (60, 10, 0):   # small libraries: allow older repeats rather than falling silent
            recent = list(playback_history[-window:]) if window else []
            res = similar.similar_tracks(seed_id, limit=8, exclude=recent, fetch=False)   # no network under the lock
            tracks = res.get("tracks") or []
            if tracks:
                break
        if not tracks:
            print(f"[Autoplay] nothing to play after {seed_id}")
            return None
        pick = tracks[0]
        print(f"[Autoplay] after {seed_id}: {pick.get('artist')} - {pick.get('title')}")
        return pick
    except Exception as e:
        print(f"[Autoplay] failed: {e}")
        return None


def _warm_related(artist: str) -> None:
    """Fetch the related-artist list for the playing artist in the background so autoplay has it when the album ends."""
    try:
        import similar
        threading.Thread(target=similar.related_artists, args=(artist,), daemon=True, name="related_warm").start()
    except Exception:
        pass


@app.get("/api/hifi/similar")
async def similar_endpoint(track_id: Optional[str] = None, artist: Optional[str] = None, limit: int = 50):
    """A mix of library tracks like the given track (or artist radio). Used by Smart mixes and the phone remote."""
    import similar
    seed = track_id or runtime_state.get("active_video_id")
    recent = list(playback_history[-60:])
    if artist:
        return await asyncio.to_thread(similar.artist_radio, artist, limit, recent)
    if not seed or not str(seed).startswith("hifi_"):
        raise HTTPException(status_code=400, detail="Play a Hi-Fi track first, or pass track_id")
    return await asyncio.to_thread(similar.similar_tracks, seed, limit, recent)


class MixPlayRequest(BaseModel):
    track_id: Optional[str] = None
    artist: Optional[str] = None
    limit: int = 50

@app.post("/api/hifi/similar/play")
async def similar_play_endpoint(req: MixPlayRequest):
    """Build the mix on the daemon and play it: first track now, the rest queued (one round-trip for the HUD)."""
    import similar
    recent = list(playback_history[-60:])
    seed = req.track_id or runtime_state.get("active_video_id")
    if req.artist:
        res = await asyncio.to_thread(similar.artist_radio, req.artist, req.limit, recent)
    elif seed and str(seed).startswith("hifi_"):
        res = await asyncio.to_thread(similar.similar_tracks, seed, req.limit, recent)
    else:
        raise HTTPException(status_code=400, detail="Nothing to seed from")
    tracks = res.get("tracks") or []
    if not tracks:
        raise HTTPException(status_code=404, detail="No similar tracks found")
    with queue_lock:
        playback_queue.clear()
        for t in tracks[1:]:
            tid = str(t.get("track_id"))
            playback_queue.append({"video_id": f"hifi_{tid}", "title": t.get("title", ""), "artist": t.get("artist", ""),
                                   "album": t.get("album", ""), "source": "hifi", "is_cached": hifi_manager.is_track_cached(tid)})
    out = await asyncio.to_thread(activate_hifi_track, "hifi_" + str(tracks[0].get("track_id")))
    out["mix"] = res.get("name")
    out["queued"] = len(tracks) - 1
    return out


# ---- Display (brightness / contrast / warmth via the compositor gamma table; display-ctl) ----
DISPLAY_CTL = "/usr/local/bin/display-ctl"

def _display_ctl(*args) -> Dict[str, Any]:
    env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}", WAYLAND_DISPLAY="wayland-0")
    r = subprocess.run([DISPLAY_CTL, *args], capture_output=True, text=True, timeout=10, env=env)
    try:
        out = json.loads(r.stdout or "{}")
    except Exception:
        return {"error": (r.stderr or r.stdout or "display-ctl failed").strip()}
    eff = out.get("effective") if isinstance(out, dict) else None
    if isinstance(eff, dict) and "brightness" in eff:
        # The HUD renders these itself (brightness/warmth as a multiply overlay, contrast as a colour matrix):
        # the panel has no backlight, no DDC/CI and the KMS output exposes no gamma table.
        with state_lock:
            runtime_state["display"] = {"brightness": float(eff.get("brightness", 1.0)), "contrast": float(eff.get("contrast", 1.0)),
                                        "warmth": int(eff.get("warmth", 6500)), "night_active": bool(eff.get("night_active", False))}
    return out

@app.get("/api/display")
async def get_display():
    return await asyncio.to_thread(_display_ctl, "show")

@app.post("/api/display")
async def set_display(values: Dict[str, Any]):
    args: List[str] = []
    for k, v in values.items():
        if k in ("brightness", "contrast", "warmth", "night", "night_from", "night_to", "night_brightness", "night_warmth"):
            args += [k, "on" if v is True else ("off" if v is False else str(v))]
    if not args:
        raise HTTPException(status_code=400, detail="nothing to set")
    return await asyncio.to_thread(_display_ctl, "set", *args)

async def display_schedule_loop():
    """Re-apply the display table every minute so the night schedule kicks in/out on time."""
    await asyncio.sleep(5)
    try:
        await asyncio.to_thread(_display_ctl, "apply")
    except Exception:
        pass
    while True:
        await asyncio.sleep(60)
        try:
            await asyncio.to_thread(_display_ctl, "apply")
        except Exception:
            pass


# ---- EQ (PipeWire filter-chain via dacpro-ctl) ----
@app.get("/api/audio/eq")
async def get_eq():
    eq = {}
    try:
        eq = (json.load(open(DACPRO_CONF)).get("eq")) or {}
    except Exception:
        pass
    base = {"enabled": False, "preset": "flat", "bass": 0.0, "treble": 0.0, "bands": [0, 0, 0, 0, 0], "loudness": False, "crossfeed": "off"}
    base.update(eq)
    base["bands_hz"] = [60, 250, 1000, 4000, 12000]
    base["presets"] = ["flat", "warm", "bright", "bass", "vocal", "night"]
    return base

@app.post("/api/audio/eq")
async def set_eq(values: Dict[str, Any]):
    """{"preset": "warm"} or any of enabled/bass/treble/bands/loudness. Restarts PipeWire (~1 s gap)."""
    def run():
        if "preset" in values and len(values) == 1:
            r = subprocess.run(["sudo", "-n", DACPRO_CTL, "set", "eq-preset", str(values["preset"])], capture_output=True, text=True, timeout=20)
        else:
            payload = {k: v for k, v in values.items() if k in ("enabled", "preset", "bass", "treble", "bands", "loudness", "crossfeed")}
            if "preset" not in payload and set(payload) != {"crossfeed"}:
                payload["preset"] = "custom"
            r = subprocess.run(["sudo", "-n", DACPRO_CTL, "set", "eq-json", json.dumps(payload)], capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise HTTPException(status_code=500, detail=(r.stderr or r.stdout).strip()[-300:])
        pw_sinks_to_unity()   # the EQ sink is new to WirePlumber: make sure it starts at unity too
        try:
            return json.loads(r.stdout.strip().splitlines()[-1])
        except Exception:
            return {"status": "ok"}
    return await asyncio.to_thread(run)


@app.post("/api/hud/resync")
async def hud_resync():
    """A (re)started HUD asks for the current track again: re-issue a 'load' at the live position in the current
    play state, so the screen and mpv match the daemon instead of a default video."""
    with state_lock:
        active = runtime_state.get("active_video_id")
        if not active or active == "standby":
            cmd = _issue_cmd_locked("stop", playing=False)
        else:
            cmd = _issue_cmd_locked("load", track_id=active, source=_source_of(active), position_s=current_position_s(),
                                    playing=bool(runtime_state.get("is_playing", False)))
    return {"status": "ok", "cmd": cmd}

class DriveSyncRequest(BaseModel):
    folder_url: Optional[str] = None

def trigger_catalog_update_broadcast():
    """Bumps hifi_catalog_version and triggers catalog reload across all listeners."""
    with state_lock:
        runtime_state["hifi_catalog_version"] = int(time.time() * 1000)
    print(f"[Library] Bumped hifi_catalog_version to {runtime_state['hifi_catalog_version']}")

@app.post("/api/hifi/notify_library_update")
async def notify_library_update():
    trigger_catalog_update_broadcast()
    return {"status": "ok", "version": runtime_state.get("hifi_catalog_version")}

@app.get("/api/hifi/drive_folders")
async def get_drive_folders():
    import sync_gdrive
    return {"folders": sync_gdrive.load_drive_folders()}

@app.post("/api/hifi/sync_drive")
async def sync_drive_endpoint(req: Optional[DriveSyncRequest] = None):
    target_url = req.folder_url if (req and req.folder_url and req.folder_url.strip()) else None
    threading.Thread(target=run_background_sync, args=(target_url,), daemon=True).start()
    return {"status": "started", "message": "Google Drive indexing started in background"}


@app.get("/api/hifi/sync_status")
async def get_hifi_sync_status():
    with state_lock:
        return {
            "status": runtime_state.get("hifi_sync_status", "idle"),
            "message": runtime_state.get("hifi_sync_message", "Ready"),
            "catalog_version": runtime_state.get("hifi_catalog_version", 1),
        }

class PlaybackModeRequest(BaseModel):
    shuffle: Optional[bool] = None
    repeat: Optional[str] = None  # "off", "all", "one"

@app.get("/api/playback/modes")
async def get_playback_modes():
    with state_lock:
        return {
            "shuffle": runtime_state.get("shuffle", False),
            "repeat": runtime_state.get("repeat", "all")
        }

@app.post("/api/playback/modes")
async def set_playback_modes(req: PlaybackModeRequest):
    with state_lock:
        if req.shuffle is not None:
            runtime_state["shuffle"] = req.shuffle
        if req.repeat is not None and req.repeat in ("off", "all", "one"):
            runtime_state["repeat"] = req.repeat
        out = {"status": "ok", "shuffle": runtime_state.get("shuffle", False), "repeat": runtime_state.get("repeat", "all")}
    save_settings({"shuffle": out["shuffle"], "repeat": out["repeat"]})   # survives a reboot
    return out

class PlaylistCreateRequest(BaseModel):
    name: str
    tracks: Optional[List[Dict[str, Any]]] = None

class PlaylistAddRequest(BaseModel):
    tracks: Optional[List[Dict[str, Any]]] = None
    track: Optional[Dict[str, Any]] = None
    track_id: Optional[str] = None
    position: Optional[str] = "end"

class PlaylistRemoveRequest(BaseModel):
    track_id: Optional[str] = None
    index: Optional[int] = None

class PlaylistPlayRequest(BaseModel):
    shuffle: Optional[bool] = False

class FavoriteToggleRequest(BaseModel):
    track: Optional[Dict[str, Any]] = None
    track_id: Optional[str] = None

@app.get("/api/hifi/playlists")
async def list_playlists_endpoint():
    return {"playlists": hifi_playlists.get_all_playlists()}

@app.get("/api/hifi/playlists/{playlist_id}")
async def get_playlist_endpoint(playlist_id: str):
    pl = hifi_playlists.get_playlist(playlist_id)
    if not pl:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return pl

@app.post("/api/hifi/playlists")
async def create_playlist_endpoint(req: PlaylistCreateRequest):
    return hifi_playlists.create_playlist(req.name, req.tracks)

@app.post("/api/hifi/playlists/{playlist_id}/add")
async def add_to_playlist_endpoint(playlist_id: str, req: PlaylistAddRequest):
    track_list = list(req.tracks) if req.tracks else []
    if req.track:
        track_list.append(req.track)
    elif req.track_id:
        t = hifi_manager.find_track_by_id(req.track_id)
        if t:
            track_list.append(t)
        else:
            track_list.append({"track_id": req.track_id, "title": "Track", "artist": "HiFi"})
    return hifi_playlists.add_to_playlist(playlist_id, track_list, req.position or "end")

@app.post("/api/hifi/playlists/{playlist_id}/remove")
async def remove_from_playlist_endpoint(playlist_id: str, req: PlaylistRemoveRequest):
    return hifi_playlists.remove_from_playlist(playlist_id, track_id=req.track_id, index=req.index)

@app.delete("/api/hifi/playlists/{playlist_id}")
async def delete_playlist_endpoint(playlist_id: str):
    if hifi_playlists.delete_playlist(playlist_id):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Cannot delete this playlist")

@app.post("/api/hifi/playlists/{playlist_id}/play")
async def play_playlist_endpoint(playlist_id: str, req: PlaylistPlayRequest = PlaylistPlayRequest()):
    pl = hifi_playlists.get_playlist(playlist_id)
    if not pl or not pl.get("tracks"):
        raise HTTPException(status_code=404, detail="Playlist is empty or not found")
    
    tracks = list(pl["tracks"])
    if req.shuffle:
        import random
        random.shuffle(tracks)
        
    first_track = tracks[0]
    first_id = str(first_track.get("track_id") or first_track.get("id"))
    
    with queue_lock:
        playback_queue.clear()
        for t in tracks[1:]:
            tid = str(t.get("track_id") or t.get("id"))
            playback_queue.append({
                "video_id": f"hifi_{tid}",
                "title": t.get("title", "Lossless Audio"),
                "artist": t.get("artist", "Unknown Artist"),
                "album": t.get("album", ""),
                "duration": t.get("duration", ""),
                "source": "hifi",
                "cover_key": t.get("key") or (f"{t.get('artist')}_{t.get('album')}".replace("/", "_").replace("\\", "_") if t.get("artist") and t.get("album") else ""),
                "is_cached": hifi_manager.is_track_cached(tid)
            })
            
    return activate_hifi_track(first_id)

@app.post("/api/hifi/favorites/toggle")
async def toggle_favorite_endpoint(req: FavoriteToggleRequest):
    tr = req.track
    if not tr and req.track_id:
        tr = hifi_manager.find_track_by_id(req.track_id) or {"track_id": req.track_id, "title": "Track"}
    if not tr:
        raise HTTPException(status_code=400, detail="Missing track or track_id")
    res = hifi_playlists.toggle_favorite(tr)
    if res.get("status") != "ok":
        raise HTTPException(status_code=400, detail=res.get("message", "toggle failed"))
    return res   # {"status","track_id","is_favorite","favorites_count"}

@app.get("/api/hifi/favorites/check")
async def check_favorite_endpoint(track_id: str):
    return {"track_id": track_id, "is_favorite": hifi_playlists.is_favorite(track_id)}

@app.get("/api/hifi/smart_playlist")
async def smart_playlist_endpoint(type: str = "random", artist: Optional[str] = None, limit: int = 50, decade: Optional[int] = None):
    hifi_manager.load_raw_catalog()   # keeps the SQLite index current
    def wrap(name, tracks):
        return {"name": name, "type": type, "tracks": [_enrich_db_track(t) for t in tracks]}
    if type == "heavy_rotation":
        return await asyncio.to_thread(lambda: wrap("Heavy rotation", library_db.heavy_rotation(limit=limit)))
    if type == "rediscover":
        return await asyncio.to_thread(lambda: wrap("Rediscover", library_db.rediscover(limit=limit)))
    if type == "never_played":
        return await asyncio.to_thread(lambda: wrap("Never played", library_db.never_played(limit=limit)))
    if type == "decade" and decade:
        return await asyncio.to_thread(lambda: wrap(f"{decade}s", library_db.decade_tracks(int(decade), limit=limit)))
    flat_tracks = hifi_manager.search_library("", limit=5000)
    return hifi_playlists.generate_smart_playlist(type, flat_tracks, artist=artist, limit=limit)


def _enrich_db_track(t: Dict[str, Any]) -> Dict[str, Any]:
    d = dict(t)
    d["key"] = d.get("album_key")
    d["cover_url"] = f"/api/hifi/cover?key={d.get('album_key')}"
    d["is_cached"] = hifi_manager.is_track_cached(str(d.get("track_id")))
    return d


@app.get("/api/hifi/albums")
async def albums_endpoint(sort: str = "name"):
    hifi_manager.load_raw_catalog()
    return {"albums": await asyncio.to_thread(library_db.albums, sort)}


@app.get("/api/hifi/albums/{key}")
async def album_tracks_endpoint(key: str):
    hifi_manager.load_raw_catalog()
    return {"key": key, "tracks": [_enrich_db_track(t) for t in await asyncio.to_thread(library_db.album_tracks, key)]}


@app.get("/api/hifi/decades")
async def decades_endpoint():
    hifi_manager.load_raw_catalog()
    return {"decades": await asyncio.to_thread(library_db.decades)}


@app.get("/api/hifi/stats")
async def listening_stats(track_id: Optional[str] = None, days: int = 30):
    if track_id:
        return await asyncio.to_thread(library_db.stats, track_id)
    return await asyncio.to_thread(library_db.listening_summary, days)


# ---- Lyrics (LRCLIB: free, keyless; synced LRC when they have it) ----
LYRICS_DIR = "/data/lyrics" if os.path.isdir("/data") else os.path.join(os.path.dirname(__file__), "lyrics")


def _fetch_lyrics(track_id: str) -> Dict[str, Any]:
    clean = track_id.replace("hifi_", "")
    os.makedirs(LYRICS_DIR, exist_ok=True)
    cache = os.path.join(LYRICS_DIR, f"{clean}.json")
    if os.path.isfile(cache):
        try:
            return json.load(open(cache))
        except Exception:
            pass
    t = hifi_manager.find_track_by_id(clean)
    out: Dict[str, Any] = {"track_id": clean, "found": False, "synced": None, "plain": None}
    if not t:
        return out
    import urllib.parse, re as _re
    title = _re.sub(r"^\s*\d+[\s.\-]+", "", str(t.get("title") or ""))     # "1-04. Song" -> "Song"
    title = _re.sub(r"\s*\((16|24)\s*[\d.]+\s*kHz\)\s*$", "", title, flags=_re.I)
    artist = str(t.get("artist") or "")
    album = hifi_manager._clean_album_name(str(t.get("album") or "")) if hasattr(hifi_manager, "_clean_album_name") else str(t.get("album") or "")
    params = {"artist_name": artist, "track_name": title}
    if album:
        params["album_name"] = album
    dur = float(t.get("duration_s") or runtime_state.get("duration_seconds") or 0)
    if dur > 0:
        params["duration"] = str(int(dur))
    try:
        for attempt in (params, {"artist_name": artist, "track_name": title}):
            url = "https://lrclib.net/api/get?" + urllib.parse.urlencode(attempt)
            req = urllib.request.Request(url, headers={"User-Agent": "RoundPlayer/1.0 (https://github.com)"})
            try:
                with urllib.request.urlopen(req, timeout=6) as r:
                    d = json.loads(r.read().decode())
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    continue
                raise
            if d.get("syncedLyrics") or d.get("plainLyrics"):
                out.update(found=True, synced=d.get("syncedLyrics"), plain=d.get("plainLyrics"), title=title, artist=artist)
                break
    except Exception as e:
        print(f"[Lyrics] {title!r}: {e}")
        return out   # transient failure: do not cache the miss
    try:
        json.dump(out, open(cache, "w"))
    except Exception:
        pass
    return out


def _fetch_lyrics_by_meta(key: str, title: str, artist: str, duration: float) -> Dict[str, Any]:
    """YouTube / YouTube Music: same LRCLIB lookup from the stream's title + artist ("Artist - Song (Official…)" cleaned)."""
    import urllib.parse, re as _re
    os.makedirs(LYRICS_DIR, exist_ok=True)
    cache = os.path.join(LYRICS_DIR, f"yt_{key}.json")
    if os.path.isfile(cache):
        try:
            return json.load(open(cache))
        except Exception:
            pass
    t = _re.sub(r"\s*[\(\[][^)\]]*(official|video|audio|lyric|remaster|visuali[sz]er|hd|4k)[^)\]]*[\)\]]", "", title, flags=_re.I).strip()
    a = artist
    if " - " in t and (not a or a.lower() in t.lower().split(" - ")[0].lower()):
        a, t = [x.strip() for x in t.split(" - ", 1)]
    out: Dict[str, Any] = {"track_id": key, "found": False, "synced": None, "plain": None}
    try:
        params = {"artist_name": a, "track_name": t}
        if duration > 0:
            params["duration"] = str(int(duration))
        for attempt in (params, {"artist_name": a, "track_name": t}):
            req = urllib.request.Request("https://lrclib.net/api/get?" + urllib.parse.urlencode(attempt), headers={"User-Agent": "RoundPlayer/1.0"})
            try:
                with urllib.request.urlopen(req, timeout=6) as r:
                    d = json.loads(r.read().decode())
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    continue
                raise
            if d.get("syncedLyrics") or d.get("plainLyrics"):
                out.update(found=True, synced=d.get("syncedLyrics"), plain=d.get("plainLyrics"), title=t, artist=a)
                break
    except Exception as e:
        print(f"[Lyrics] {t!r}: {e}")
        return out
    try:
        json.dump(out, open(cache, "w"))
    except Exception:
        pass
    return out


@app.get("/api/lyrics")
async def lyrics_endpoint(track_id: Optional[str] = None):
    tid = track_id or runtime_state.get("active_video_id") or ""
    if tid.startswith("hifi_") or hifi_manager.find_track_by_id(tid.replace("hifi_", "")):
        return await asyncio.to_thread(_fetch_lyrics, tid)
    if tid and tid == runtime_state.get("active_video_id") and not tid.startswith("ext:"):
        return await asyncio.to_thread(_fetch_lyrics_by_meta, tid, str(runtime_state.get("title") or ""), str(runtime_state.get("artist") or ""),
                                       float(runtime_state.get("duration_seconds") or 0))
    return {"track_id": tid, "found": False}

if __name__ == "__main__":
    import uvicorn
    import logging

    class _QuietHudState(logging.Filter):
        def filter(self, record: logging.LogRecord) -> bool:  # the HUD posts /api/hud/state at ~2 Hz
            return "/api/hud/state" not in record.getMessage() and "/api/state" not in record.getMessage()

    logging.getLogger("uvicorn.access").addFilter(_QuietHudState())
    uvicorn.run(app, host="0.0.0.0", port=8000)

