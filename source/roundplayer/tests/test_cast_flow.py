"""
Exercises the daemon's command sequence the way the HUD + cast receiver use it, with a fake HUD.
Run with playback_manager.py on :8000 (no Pi needed):  python3 -I tests/test_cast_flow.py
"""
import json, socket, threading, time, urllib.request

API = "http://127.0.0.1:8000"
SOCK = "/tmp/roundplayer_telemetry.sock"

def api(path, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method or ("POST" if data is not None else "GET"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode() or "{}")

class FakeHud(threading.Thread):
    """Applies each telemetry cmd once (like _applyDaemonCommand) and reports state like _startHudStateReporter."""
    def __init__(self):
        super().__init__(daemon=True)
        self.applied = []          # (seq, type, track_id, playing, position)
        self.loaded = None; self.playing = False; self.pos = 0.0; self.seq = 0; self.stop = False
    def run(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK)
        f = s.makefile("r")
        last_report = 0
        for line in f:
            if self.stop: break
            d = json.loads(line)
            cmd = d.get("cmd")
            if cmd and cmd["seq"] > self.seq:
                self.seq = cmd["seq"]
                t = cmd["type"]
                if t == "load":
                    if self.loaded != cmd["track_id"]:
                        self.loaded = cmd["track_id"]; self.pos = cmd.get("position_s") or 0.0
                    self.playing = bool(cmd.get("playing", True))
                elif t == "play": self.playing = True
                elif t == "pause": self.playing = False
                elif t == "seek": self.pos = cmd.get("position_s") or 0.0
                elif t == "stop": self.playing = False; self.loaded = None
                self.applied.append((cmd["seq"], t, cmd.get("track_id"), self.playing, self.pos))
            if self.playing: self.pos += 1 / 60
            if time.time() - last_report > 0.5:
                last_report = time.time()
                try: api("/api/hud/state", {"track_id": self.loaded, "position_s": self.pos, "duration_s": 223.0, "is_playing": self.playing})
                except Exception: pass

hud = FakeHud(); hud.start(); time.sleep(0.5)
seq0 = api("/api/state")["cmd_seq"]

def wait(cond, what, t=10):
    t0 = time.time()
    while time.time() - t0 < t:
        if cond(): return True
        time.sleep(0.1)
    raise AssertionError("timeout waiting for " + what)

# 1. cast a cached track from a sender at position 30s (what yt-cast-receiver doPlay does)
cached = [t["video_id"] for t in api("/api/tracks")]
assert cached, "need at least one cached track"
vid = cached[0]
r = api(f"/api/play/{vid}", {"title": "T", "artist": "A", "position": 30})
wait(lambda: hud.loaded == vid and hud.playing, "load+play")
wait(lambda: api("/api/state")["hud_synced"], "hud_synced")
st = api("/api/state"); assert abs(st["playback_position_s"] - hud.pos) < 1.5, st
print("1 cast start: loaded", hud.loaded, "pos", round(hud.pos, 1), "synced", st["hud_synced"])

# 2. pause / resume from the sender - must not flap
api("/api/control", {"action": "pause"}); wait(lambda: not hud.playing, "pause")
p1 = hud.pos; time.sleep(1.0); assert abs(hud.pos - p1) < 0.01, "position moved while paused (flap)"
api("/api/control", {"action": "play"}); wait(lambda: hud.playing, "resume")
print("2 pause/resume ok, no flap")

# 3. seek
api("/api/control", {"action": "seek", "seek_seconds": 100}); wait(lambda: abs(hud.pos - 100) < 2, "seek")
wait(lambda: abs(api("/api/state")["playback_position_s"] - hud.pos) < 1.5, "daemon reads real pos after seek")
print("3 seek ok")

# 4. "play a new thing" while playing: second cached track or same track again (same-id must not reload)
loads_before = sum(1 for a in hud.applied if a[1] == "load")
api(f"/api/play/{vid}", {"title": "T"}); time.sleep(0.6)
other = cached[1] if len(cached) > 1 else None
if other:
    api(f"/api/play/{other}", {"title": "T2"}); wait(lambda: hud.loaded == other and hud.playing, "switch track")
print("4 new track ok; loads so far:", sum(1 for a in hud.applied if a[1] == "load"))

# 5. switch to Hi-Fi (if the library has anything) and back
tree = api("/api/hifi/tree"); tracks = [t for a in tree.get("artists", []) for al in a.get("albums", []) for t in al.get("tracks", [])]
if tracks:
    tid = tracks[0]["track_id"]
    api("/api/hifi/play", {"track_id": tid}); wait(lambda: hud.loaded == "hifi_" + tid, "hifi load")
    api(f"/api/play/{vid}", {"title": "T"}); wait(lambda: hud.loaded == vid, "back to youtube")
    print("5 hifi <-> youtube ok")
else:
    print("5 hifi skipped (empty library)")

# 6. stop cast: the last play was the user's own (/api/play without source=cast) -> a phone "stop" changes nothing;
#    a cast-owned track stops. No history resurrection either way.
before = (hud.loaded, hud.playing)
api("/api/control", {"action": "stop_cast"}); time.sleep(0.8)
assert (hud.loaded, hud.playing) == before, (before, hud.loaded, hud.playing)
api(f"/api/play/{vid}", {"title": "T", "source": "cast"}); wait(lambda: hud.loaded == vid and hud.playing, "cast-owned play")
api("/api/control", {"action": "stop_cast"}); wait(lambda: hud.loaded is None and not hud.playing, "cast-owned stop")
print("6 stop_cast: user's track untouched, cast-owned track stopped")

# 7. idle
api("/api/control", {"action": "idle"}); wait(lambda: hud.loaded is None and not hud.playing, "idle/stop")
print("7 idle ok")
print("applied:", [(a[0], a[1], (a[2] or '')[:8]) for a in hud.applied])
hud.stop = True
print("ALL OK")
