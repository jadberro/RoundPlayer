"""
Edge cases for selecting Hi-Fi tracks (cached / uncached / switching mid-download / mixing with YouTube and stop),
driven against a running daemon with a fake HUD and a fake, slow "Google Drive".

Setup (sandbox or Pi, daemon NOT running as a service):
    python3 -I tests/test_hifi_flow.py --setup      # writes /data/hifi_music/remote_library.json + fake drive files
    HIFI_FAKE_DRIVE=/tmp/fake_drive ROUNDPLAYER_NO_NET_WATCHDOG=1 python3 playback_manager.py &
    python3 -I tests/test_hifi_flow.py
"""
import json, os, shutil, socket, sys, threading, time, urllib.request, urllib.error

API = "http://127.0.0.1:8000"
SOCK = "/tmp/roundplayer_telemetry.sock"
FAKE = "/tmp/fake_drive"
HIFI_DIR = "/data/hifi_music"
CACHE = "/data/hifi_cache"
TRACKS = [("aaaaaaaaaaa1", "Alpha", 3), ("bbbbbbbbbbb2", "Bravo", 3), ("ccccccccccc3", "Charlie", 3), ("ddddddddddd4", "Delta", 1)]


def setup():
    os.makedirs(FAKE, exist_ok=True); os.makedirs(HIFI_DIR, exist_ok=True); os.makedirs(CACHE, exist_ok=True)
    for tid, name, mb in TRACKS:
        with open(os.path.join(FAKE, f"{name}.flac"), "wb") as f:
            f.write(b"fLaC" + os.urandom(mb * 1024 * 1024))
    cat = {"artists": [{"name": "Test Artist", "albums": [{"name": "Test Album", "tracks": [
        {"track_id": tid, "title": name, "artist": "Test Artist", "album": "Test Album", "track_num": i + 1,
         "format": "FLAC", "file_name": f"{name}.flac", "rel_path": f"Test Artist/Test Album/{name}.flac",
         "gdrive_file_id": "fake" + tid, "size_mb": mb} for i, (tid, name, mb) in enumerate(TRACKS)]}]}],
        "total_tracks": len(TRACKS), "total_albums": 1, "total_artists": 1}
    with open(os.path.join(HIFI_DIR, "remote_library.json"), "w") as f:
        json.dump(cat, f)
    for tid, _, _ in TRACKS:
        for ext in (".flac", ".flac.part", ".flac.beats.npy"):
            p = os.path.join(CACHE, tid + ext)
            if os.path.exists(p): os.remove(p)
    mf = os.path.join(CACHE, "manifest.json")
    if os.path.exists(mf): os.remove(mf)
    print("fake drive + catalog ready")


def api(path, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method or ("POST" if data is not None else "GET"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode() or "{}")


class FakeHud(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.applied = []; self.loaded = None; self.playing = False; self.pos = 0.0; self.seq = 0
        self.last = {}; self.gap_max = 0.0

    def run(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK)
        f = s.makefile("r"); last_report = 0; last_pkt = time.time()
        for line in f:
            now = time.time(); self.gap_max = max(self.gap_max, now - last_pkt); last_pkt = now
            d = json.loads(line); self.last = d
            cmd = d.get("cmd")
            if cmd and cmd["seq"] > self.seq:
                self.seq = cmd["seq"]; t = cmd["type"]
                if t == "load":
                    self.loaded = cmd["track_id"]; self.pos = cmd.get("position_s") or 0.0; self.playing = bool(cmd.get("playing", True))
                elif t == "play": self.playing = True
                elif t == "pause": self.playing = False
                elif t == "seek": self.pos = cmd.get("position_s") or 0.0
                elif t == "stop": self.playing = False; self.loaded = None
                self.applied.append((cmd["seq"], t, cmd.get("track_id")))
            if self.playing: self.pos += 1 / 60
            if now - last_report > 0.5:
                last_report = now
                try: api("/api/hud/state", {"track_id": self.loaded, "position_s": self.pos, "duration_s": 200.0, "is_playing": self.playing})
                except Exception: pass


def wait(cond, what, t=15):
    t0 = time.time()
    while time.time() - t0 < t:
        if cond(): return True
        time.sleep(0.05)
    raise AssertionError("timeout waiting for " + what)


def main():
    hud = FakeHud(); hud.start(); time.sleep(0.6)
    A, B, C, D = [f"hifi_{t[0]}" for t in TRACKS]
    loads = lambda: [a for a in hud.applied if a[1] == "load"]
    results = []

    def check(name, ok, info=""):
        results.append((name, ok)); print(("OK  " if ok else "FAIL") + " " + name + ("  " + info if info else ""))

    # 1. uncached -> immediate "preparing" answer, telemetry shows progress, then exactly one load of A
    t0 = time.time(); r = api("/api/hifi/play", {"track_id": A}); dt = time.time() - t0
    check("1 uncached answers at once", r["status"] == "preparing" and dt < 1.0, f"{dt*1000:.0f} ms")
    wait(lambda: hud.last.get("caching_video_id") == A and (hud.last.get("caching_percent") or 0) > 0, "progress for A")
    check("1 progress visible", "Downloading" in str(hud.last.get("caching_progress")), str(hud.last.get("caching_progress")))
    wait(lambda: loads() and loads()[-1][2] == A, "load A", 40)
    wait(lambda: hud.last.get("hud_synced"), "hud synced A")
    check("1 loads A once, caching cleared", len(loads()) == 1 and hud.last.get("caching_video_id") is None and hud.last.get("track_id") == A)

    # 2. switch mid-download: B then C while B is downloading -> B never loads, C does
    api("/api/hifi/play", {"track_id": B})
    wait(lambda: hud.last.get("caching_video_id") == B and (hud.last.get("caching_percent") or 0) >= 5, "B downloading")
    api("/api/hifi/play", {"track_id": C})
    wait(lambda: hud.last.get("caching_video_id") == C, "pill switched to C", 3)
    wait(lambda: loads() and loads()[-1][2] == C, "load C", 60)
    time.sleep(1.5)
    check("2 B superseded by C", [l[2] for l in loads()] == [A, C] and not os.path.exists(f"{CACHE}/{B[5:]}.flac.part"),
          str([l[2] for l in loads()]))

    # 3. uncached B then cached A while B downloads -> A plays immediately, B retires, A still playing 3 s later
    api("/api/hifi/play", {"track_id": B})
    wait(lambda: hud.last.get("caching_video_id") == B, "B downloading again")
    r = api("/api/hifi/play", {"track_id": A})
    wait(lambda: loads()[-1][2] == A and hud.last.get("caching_video_id") is None, "A loaded, pill gone", 5)
    time.sleep(3.0)
    check("3 cached over uncached", r["status"] == "playing" and loads()[-1][2] == A and hud.last.get("track_id") == A)

    # 4. same track tapped twice while preparing -> single download, single load
    if os.path.exists(f"{CACHE}/{D[5:]}.flac"): os.remove(f"{CACHE}/{D[5:]}.flac")   # (the pre-cacher may have fetched it)
    n_before = len(loads())
    api("/api/hifi/play", {"track_id": D}); time.sleep(0.3); api("/api/hifi/play", {"track_id": D})
    wait(lambda: loads() and loads()[-1][2] == D, "load D", 30); time.sleep(1.0)
    check("4 double tap = one load", len(loads()) == n_before + 1)

    # 5. stop/idle while preparing -> nothing loads afterwards
    for tid, _, _ in TRACKS:
        for ext in (".flac",):
            p = f"{CACHE}/{tid}{ext}"
            if tid.startswith("bbb") and os.path.exists(p): os.remove(p)
    api("/api/hifi/play", {"track_id": B})
    wait(lambda: hud.last.get("caching_video_id") == B, "B downloading (5)")
    api("/api/control", {"action": "idle"})
    n = len(loads()); time.sleep(6.0)
    check("5 idle cancels preparation", len(loads()) == n and hud.last.get("caching_video_id") is None and hud.last.get("track_id") == "standby")

    # 6. banner 'x' (/api/prepare/cancel) -> current track keeps playing, nothing loads
    api("/api/hifi/play", {"track_id": A}); wait(lambda: loads()[-1][2] == A, "A again")
    if os.path.exists(f"{CACHE}/{B[5:]}.flac"): os.remove(f"{CACHE}/{B[5:]}.flac")
    api("/api/hifi/play", {"track_id": B}); wait(lambda: hud.last.get("caching_video_id") == B, "B downloading (6)")
    r = api("/api/prepare/cancel", {}); n = len(loads()); time.sleep(5.0)
    check("6 cancel keeps A playing", r.get("canceled") == B and len(loads()) == n and hud.last.get("track_id") == A and hud.last.get("is_playing"))

    # 7. YouTube cached track over an uncached Hi-Fi download -> YouTube loads, Hi-Fi retires
    yt = [t["video_id"] for t in api("/api/tracks")]
    if yt:
        api("/api/hifi/play", {"track_id": B}); wait(lambda: hud.last.get("caching_video_id") == B, "B downloading (7)")
        api(f"/api/play/{yt[0]}", {})
        wait(lambda: loads()[-1][2] == yt[0], "yt load"); n = len(loads()); time.sleep(6.0)
        check("7 youtube over hifi download", len(loads()) == n and hud.last.get("track_id") == yt[0] and hud.last.get("caching_video_id") is None)
    else:
        print("skip 7 (no cached YouTube track)")

    # 8. queue next from a Hi-Fi track to an uncached one -> preparing then load
    api("/api/hifi/play", {"track_id": C}); wait(lambda: loads()[-1][2] == C, "C")
    if os.path.exists(f"{CACHE}/{D[5:]}.flac"): os.remove(f"{CACHE}/{D[5:]}.flac")
    r = api("/api/queue/next", {})
    wait(lambda: loads()[-1][2] == D, "next -> D", 30)
    check("8 queue next prepares uncached", r["status"] in ("preparing", "playing"))

    # 9. the daemon never stalled: telemetry gaps stayed small throughout
    check("9 telemetry never froze", hud.gap_max < 0.5, f"max gap {hud.gap_max*1000:.0f} ms")

    failed = [n for n, ok in results if not ok]
    print("\nALL OK" if not failed else "\nFAILED: " + ", ".join(failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if "--setup" in sys.argv:
        setup()
    else:
        main()
