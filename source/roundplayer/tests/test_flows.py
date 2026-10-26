"""
Playback flows that must be rock solid, driven against a running daemon with a fake HUD (applies numbered commands,
reports state, reports end-of-track) and a fake slow Google Drive.

    python3 -I tests/test_hifi_flow.py --setup
    HIFI_FAKE_DRIVE=/tmp/fake_drive ROUNDPLAYER_NO_NET_WATCHDOG=1 python3 playback_manager.py &
    python3 -I tests/test_flows.py
"""
import json, os, socket, sys, threading, time, urllib.request, urllib.error

API = "http://127.0.0.1:8000"
SOCK = "/tmp/roundplayer_telemetry.sock"
CACHE = "/data/hifi_cache"
TRACKS = [("aaaaaaaaaaa1", "Alpha"), ("bbbbbbbbbbb2", "Bravo"), ("ccccccccccc3", "Charlie"), ("ddddddddddd4", "Delta")]
A, B, C, D = [f"hifi_{t[0]}" for t in TRACKS]


def api(path, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method or ("POST" if data is not None else "GET"), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return {"http_error": e.code, "body": e.read().decode()[:200]}


class FakeHud(threading.Thread):
    """Mirrors the real HUD: applies each cmd once, reports mpv state every 0.5 s, reports end-of-track."""
    def __init__(self):
        super().__init__(daemon=True)
        self.applied = []; self.loaded = None; self.playing = False; self.pos = 0.0; self.seq = 0; self.last = {}
        self.duration = 20.0; self.ended_sent = set()

    def run(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK)
        f = s.makefile("r"); last_report = 0; last_tick = time.time()
        for line in f:
            d = json.loads(line); self.last = d
            cmd = d.get("cmd")
            if cmd and cmd["seq"] != self.seq:
                self.seq = cmd["seq"]; t = cmd["type"]
                if t == "load":
                    self.loaded = cmd["track_id"]; self.pos = cmd.get("position_s") or 0.0; self.playing = bool(cmd.get("playing", True)); self.ended_sent.discard(self.loaded)
                elif t == "play": self.playing = True
                elif t == "pause": self.playing = False
                elif t == "seek": self.pos = cmd.get("position_s") or 0.0
                elif t == "stop": self.playing = False; self.loaded = None
                self.applied.append((cmd["seq"], t, cmd.get("track_id"), bool(cmd.get("playing", True)) if t == "load" else None))
            # the daemon sends on change + a 4 Hz heartbeat, so position follows the wall clock, not the packet count
            now = time.time()
            if self.playing and self.loaded: self.pos += now - last_tick
            last_tick = now
            if self.loaded and self.playing and self.pos >= self.duration and self.loaded not in self.ended_sent:
                self.ended_sent.add(self.loaded); self.playing = False
                try: api("/api/hud/ended", {"track_id": self.loaded})
                except Exception: pass
            if now - last_report > 0.5:
                last_report = now
                try: api("/api/hud/state", {"track_id": self.loaded, "position_s": self.pos, "duration_s": self.duration, "is_playing": self.playing})
                except Exception: pass


def wait(cond, what, t=15):
    t0 = time.time()
    while time.time() - t0 < t:
        if cond(): return True
        time.sleep(0.05)
    raise AssertionError("timeout waiting for " + what)


def main():
    for tid, _ in TRACKS:
        p = f"{CACHE}/{tid}.flac"
        if os.path.exists(p): os.remove(p)
    hud = FakeHud(); hud.start(); time.sleep(0.6)
    loads = lambda: [a for a in hud.applied if a[1] == "load"]
    results = []
    def check(name, ok, info=""):
        results.append((name, ok)); print(("OK  " if ok else "FAIL") + " " + name + ("  " + info if info else ""))

    # warm the cache for A, C, D so switches between cached tracks are instant
    for t in (A, C, D):
        api("/api/hifi/play", {"track_id": t}); wait(lambda: hud.loaded == t, f"load {t}", 40)
    api("/api/control", {"action": "idle"}); wait(lambda: hud.loaded is None, "idle")
    hud.applied.clear()

    # 1. pause, then pick another track -> the other track plays; the paused one never comes back
    api("/api/hifi/play", {"track_id": A}); wait(lambda: hud.loaded == A and hud.playing, "A")
    api("/api/control", {"action": "pause"}); wait(lambda: not hud.playing, "paused")
    api("/api/hifi/play", {"track_id": C}); wait(lambda: hud.loaded == C and hud.playing, "C"); time.sleep(3)
    check("1 pause then pick another", hud.loaded == C and hud.playing and hud.last.get("track_id") == C and hud.last.get("is_playing"))

    # 2. rapid A -> D -> C on cached tracks: ends on C, every intermediate load was superseded cleanly
    n0 = len(loads())
    api("/api/hifi/play", {"track_id": A}); api("/api/hifi/play", {"track_id": D}); api("/api/hifi/play", {"track_id": C})
    wait(lambda: loads() and loads()[-1][2] == C, "C last", 10); time.sleep(3)
    check("2 rapid A>D>C ends on C", hud.loaded == C and hud.last.get("track_id") == C and hud.playing, str([l[2][-3:] for l in loads()[n0:]]))

    # 3. a cast session: cast owns its track; the phone dropping off (stop_cast) while the user already moved on = no-op
    yt = [t["video_id"] for t in api("/api/tracks")]
    if yt:
        api(f"/api/play/{yt[0]}", {"title": "Cast", "artist": "Phone", "position": 0, "source": "cast"}); wait(lambda: hud.loaded == yt[0], "cast load")
        api("/api/hifi/play", {"track_id": A}); wait(lambda: hud.loaded == A, "A after cast")
        api("/api/control", {"action": "stop_cast"}); time.sleep(2.5)
        check("3 phone disconnect after user moved on = nothing changes", hud.loaded == A and hud.playing and hud.last.get("track_id") == A)
        # 4. phone stops its own cast -> the box stops, it does not dig up an older track
        api(f"/api/play/{yt[0]}", {"title": "Cast", "artist": "Phone", "position": 0, "source": "cast"}); wait(lambda: hud.loaded == yt[0], "cast load 2")
        api("/api/control", {"action": "stop_cast"}); wait(lambda: hud.loaded is None, "stopped", 5); time.sleep(1)
        r4 = api("/api/resume", {}); time.sleep(1)
        check("4 cast stop -> idle, no history resurrection, tap does not bring it back", hud.loaded is None and hud.last.get("track_id") == "standby" and not r4.get("resumed"))
    else:
        print("skip 3/4 (no cached YouTube track)")

    # 5. sleep -> wake: last track comes back paused at the same position
    api("/api/hifi/play", {"track_id": C}); wait(lambda: hud.loaded == C and hud.playing, "C again"); time.sleep(2.5)
    pos_before = hud.pos
    api("/api/control", {"action": "idle"}); wait(lambda: hud.loaded is None, "asleep")
    r = api("/api/resume", {}); wait(lambda: hud.loaded == C, "resumed", 5); time.sleep(1)
    check("5 sleep -> wake resumes paused at position", r.get("resumed") and hud.loaded == C and not hud.playing and abs(hud.pos - pos_before) < 1.5, f"{pos_before:.1f}s -> {hud.pos:.1f}s")
    api("/api/control", {"action": "play"}); wait(lambda: hud.playing, "playing after wake")

    # 6. end of track -> next album track via /api/hud/ended (fake HUD ends at 20 s; jump near the end)
    api("/api/playback/modes", {"repeat": "all", "shuffle": False})
    api("/api/hifi/play", {"track_id": A}); wait(lambda: hud.loaded == A and hud.playing, "A for ending")
    api("/api/control", {"action": "seek", "seek_seconds": 19.5}); wait(lambda: hud.loaded != A, "advanced after end", 30)
    check("6 track end -> next track", hud.loaded is not None and hud.loaded != A and hud.playing, str(hud.loaded))

    # 7. repeat one: the same track restarts
    api("/api/playback/modes", {"repeat": "one"})
    api("/api/hifi/play", {"track_id": C}); wait(lambda: hud.loaded == C and hud.playing, "C repeat one")
    api("/api/control", {"action": "seek", "seek_seconds": 19.5}); time.sleep(3)
    check("7 repeat one restarts", hud.loaded == C and hud.playing and hud.pos < 10, f"pos {hud.pos:.1f}")
    api("/api/playback/modes", {"repeat": "off"})

    # 8. autoplay similar: album (single track D) ends with repeat off -> something else plays (no stop)
    api("/api/settings", {"autoplay_similar": True})
    api("/api/hifi/play", {"track_id": D}); wait(lambda: hud.loaded == D and hud.playing, "D")
    api("/api/control", {"action": "seek", "seek_seconds": 19.5}); wait(lambda: hud.loaded not in (D, None), "autoplay picked", 30); time.sleep(1)
    check("8 autoplay similar after album end", hud.loaded not in (D, None) and hud.playing, str(hud.loaded))

    # 9. HUD play/pause never flaps: 6 toggles in a row land on the expected state
    api("/api/hifi/play", {"track_id": A}); wait(lambda: hud.loaded == A and hud.playing, "A toggles")
    want = True
    for _ in range(6):
        want = not want
        api("/api/control", {"action": "play" if want else "pause"}); time.sleep(0.4)
    time.sleep(1.5)
    check("9 play/pause sequence lands", hud.playing == want and hud.last.get("is_playing") == want)

    # 10. hud/ended for a track that is no longer active is ignored
    r = api("/api/hud/ended", {"track_id": B})
    check("10 stale ended ignored", r.get("status") == "ignored")

    # 11. similar endpoint returns a mix seeded by the playing track
    r = api("/api/hifi/similar?limit=5")
    check("11 similar mix", isinstance(r.get("tracks"), list) and len(r["tracks"]) >= 1, f"{len(r.get('tracks', []))} tracks")

    # 12. gapless: mpv crosses into the pre-opened next track by itself; the daemon adopts it without a load command
    api("/api/playback/modes", {"repeat": "all", "shuffle": False})
    api("/api/hifi/play", {"track_id": A}); wait(lambda: hud.loaded == A and hud.playing, "A gapless"); time.sleep(1.5)
    un = hud.last.get("up_next") or {}
    nxt = un.get("track_id")
    n_loads = len(loads())
    hud.loaded = nxt; hud.pos = 0.0   # what mpv does on its own with prefetch-playlist
    r = api("/api/hud/advanced", {"track_id": nxt, "previous": A}); time.sleep(2)
    check("12 gapless advance adopted", un.get("ready") is True and r.get("status") == "adopted" and hud.last.get("track_id") == nxt and len(loads()) == n_loads, f"next={str(nxt)[-3:]} r={r.get('status')} loads+{len(loads()) - n_loads}")

    # 13. gapless advance into something that is no longer the plan -> corrected by a proper load command
    api("/api/hifi/play", {"track_id": C}); wait(lambda: hud.loaded == C and hud.playing, "C for correction"); time.sleep(1)
    n_loads = len(loads())
    r = api("/api/hud/advanced", {"track_id": B, "previous": C}); time.sleep(2.5)
    check("13 wrong advance corrected", r.get("status") == "corrected" and len(loads()) > n_loads and hud.loaded not in (None, C), f"loaded={str(hud.loaded)[-3:]}")

    failed = [n for n, ok in results if not ok]
    print("\nALL OK" if not failed else "\nFAILED: " + ", ".join(failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
