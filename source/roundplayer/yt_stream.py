"""
yt_stream.py - play YouTube / YouTube Music like a normal player: resolve the stream URLs (2-3 s) and let mpv
stream them with range requests, instead of downloading and remuxing the whole video first.

Video: H.264 <= 1080p (the Pi 4's V4L2 decoder can only do H.264) + the AAC audio track, merged for mpv with an
EDL ("edl://!new_stream;...") - the same trick mpv's own ytdl hook uses. Audio only (YouTube Music casts, or
anything without an H.264 video track): the best audio stream on its own.

URLs carry an `expire=` parameter (~6 h); resolved entries are cached until shortly before that.
"""
import os, re, threading, time, urllib.parse, urllib.request
from typing import Any, Dict, Optional

import yt_dlp

_cache: Dict[str, Dict[str, Any]] = {}
_lock = threading.Lock()

VIDEO_FMT = "bestvideo[height<=1080][vcodec^=avc]+bestaudio[acodec^=mp4a]/best[height<=1080][vcodec^=avc]/bestaudio/best"
AUDIO_FMT = "bestaudio[acodec^=opus]/bestaudio[acodec^=mp4a]/bestaudio/best"


def _edl(video_url: str, audio_url: str) -> str:
    def enc(u: str) -> str:
        return f"%{len(u.encode('utf-8'))}%{u}"
    return ("edl://!new_stream;!no_clip;!no_chapters;" + enc(video_url) +
            ";!new_stream;!no_clip;!no_chapters;" + enc(audio_url))


def _expiry(url: str) -> float:
    try:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        return float(q.get("expire", [0])[0]) or (time.time() + 5 * 3600)
    except Exception:
        return time.time() + 5 * 3600


def _clean_artist(info: Dict[str, Any]) -> str:
    a = info.get("artist") or info.get("creator") or info.get("uploader") or info.get("channel") or ""
    if isinstance(a, list):
        a = ", ".join(a)
    return re.sub(r"\s*-\s*Topic$", "", str(a)).strip()


def resolve(video_id: str, audio_only: bool = False, force: bool = False) -> Dict[str, Any]:
    """Returns {url, audio_only, title, artist, album, duration_s, thumbnail, height, acodec, expires}. Raises on failure."""
    key = f"{video_id}:{'a' if audio_only else 'v'}"
    with _lock:
        hit = _cache.get(key)
        if hit and not force and hit["expires"] - time.time() > 600:
            return hit
    opts = {"quiet": True, "no_warnings": True, "noplaylist": True, "skip_download": True,
            "format": AUDIO_FMT if audio_only else VIDEO_FMT}
    t0 = time.time()
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
    fmts = info.get("requested_formats") or [info]
    vfmt = next((f for f in fmts if (f.get("vcodec") or "none") != "none"), None)
    afmt = next((f for f in fmts if (f.get("acodec") or "none") != "none"), None)
    if audio_only or vfmt is None:
        src = afmt or fmts[0]
        url, is_audio = src["url"], True
        height = None
    elif afmt is not None and afmt is not vfmt:
        url, is_audio = _edl(vfmt["url"], afmt["url"]), False
        height = vfmt.get("height")
    else:
        url, is_audio = vfmt["url"], False   # progressive (video + audio in one file)
        height = vfmt.get("height")
    thumb = info.get("thumbnail")
    if not thumb and info.get("thumbnails"):
        thumb = info["thumbnails"][-1].get("url")
    out = {
        "url": url, "audio_only": is_audio,
        "title": info.get("track") or info.get("title") or video_id,
        "artist": _clean_artist(info), "album": info.get("album") or "",
        "duration_s": float(info.get("duration") or 0), "thumbnail": thumb, "height": height,
        "acodec": ((afmt or {}).get("acodec") or "").split(".")[0].upper() or "AAC",
        "abr": (afmt or {}).get("abr"),
        "expires": min(_expiry(fmts[0]["url"]), time.time() + 5.5 * 3600),
        "resolved_in_s": round(time.time() - t0, 2),
    }
    with _lock:
        _cache[key] = out
    return out


def fetch_thumbnail(url: Optional[str], dest: str) -> bool:
    """Square-ish cover for the art layout / lists. Prefers the maxres JPEG."""
    if not url:
        return False
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as r:
            data = r.read()
        if len(data) < 1000:
            return False
        tmp = dest + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        try:
            from PIL import Image
            im = Image.open(tmp).convert("RGB")
            w, h = im.size
            if abs(w - h) > 8:   # YouTube thumbnails are 16:9 letterboxed art for music: take the centre square
                s = min(w, h)
                im = im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))
            im.save(tmp, "JPEG", quality=90)
        except Exception:
            pass
        os.replace(tmp, dest)
        return True
    except Exception:
        return False
