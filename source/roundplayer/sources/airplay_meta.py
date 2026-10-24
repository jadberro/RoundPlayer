#!/usr/bin/env python3
"""airplay_meta.py - follow shairport-sync's metadata pipe and tell the daemon what is playing.

shairport-sync writes XML-ish items to /tmp/shairport-sync-metadata (type/code are 4-char tags as hex, data base64).
We care about: pbeg/pend (session begin/end), minm (title), asar (artist), asal (album), PICT (cover),
prgr (progress "start/current/end" in sample frames), pfls/prsm (pause/resume), snam (sender name).
"""
import base64, json, os, re, time, urllib.request

PIPE = "/tmp/shairport-sync-metadata"
API = "http://127.0.0.1:8000"
RATE = 44100.0


def post(path, body=None):
    try:
        data = json.dumps(body or {}).encode()
        req = urllib.request.Request(API + path, data=data, headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass


def code(hexs):
    try:
        return bytes.fromhex(hexs).decode("ascii", "replace")
    except Exception:
        return "?"


def main():
    item_re = re.compile(r'<item><type>([0-9a-f]+)</type><code>([0-9a-f]+)</code><length>(\d+)</length>(?:\s*<data encoding="base64">\s*([^<]*)</data>)?</item>', re.S)
    meta, in_session, sender = {}, False, None
    while True:
        if not os.path.exists(PIPE):
            time.sleep(2)
            continue
        try:
            with open(PIPE, "rb") as f:
                buf = b""
                while True:
                    chunk = f.read(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while True:
                        m = item_re.search(buf.decode("utf-8", "replace"))
                        if not m:
                            if len(buf) > 4_000_000:
                                buf = b""
                            break
                        buf = buf[m.end():]
                        typ, cd, data = code(m.group(1)), code(m.group(2)), m.group(4)
                        raw = base64.b64decode(data) if data else b""
                        if typ == "ssnc":
                            if cd == "pbeg":
                                in_session = True
                                meta = {}
                                post("/api/source/airplay/start", {"device": sender})
                            elif cd == "pend":
                                in_session = False
                                post("/api/source/airplay/stop")
                            elif cd == "snam":
                                sender = raw.decode("utf-8", "replace")
                                if in_session:
                                    post("/api/source/airplay/meta", {"artist": meta.get("artist") or sender})
                            elif cd == "pfls":
                                post("/api/source/airplay/meta", {"playing": False})
                            elif cd == "prsm":
                                post("/api/source/airplay/meta", {"playing": True})
                            elif cd == "prgr":
                                try:
                                    a, b, c = (int(x) for x in raw.decode().split("/"))
                                    post("/api/source/airplay/meta", {"position_s": (b - a) / RATE, "duration_s": (c - a) / RATE, "playing": True})
                                except Exception:
                                    pass
                            elif cd == "PICT" and raw:
                                post("/api/source/airplay/meta", {"cover_b64": base64.b64encode(raw).decode()})
                            elif cd == "mden":
                                if in_session and meta:
                                    post("/api/source/airplay/meta", meta)
                        elif typ == "core":
                            txt = raw.decode("utf-8", "replace")
                            if cd == "minm":
                                meta["title"] = txt
                            elif cd == "asar":
                                meta["artist"] = txt
                            elif cd == "asal":
                                meta["album"] = txt
        except Exception as e:
            print(f"[airplay_meta] {e}")
            time.sleep(2)


if __name__ == "__main__":
    main()
