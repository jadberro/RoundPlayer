# Round Player — engineering handover

**What it is:** a media player with a 1080×1080 round touch screen, a Raspberry Pi DAC Pro for bit-perfect audio, a phone web remote, YouTube / YouTube Music casting, AirPlay, Spotify Connect, a lossless Google Drive library, and Home Assistant control. It started as the media half of the "Media_Player_Juggler" project (Arduino Ventuno Q / UNO Q). All the juggler, motor and vision code is gone; this is a media player only.

**Snapshot date:** 2026-10-24, version `2026.10.18` plus the fixes listed in §12. Everything in this release matches what was running on the device when verified.

Read this first, then `docs/porting-notes.md`, which is the detailed engineering log (why every decision was made, with dates).

---

## 1. What's in this zip

| Path | Contents |
|---|---|
| `HANDOVER.md` | this document |
| `source/roundplayer/` | **the canonical source tree**, the same code the device runs |
| `prebuilt/round_hud_app-linux-arm64-bundle.tar.gz` | the compiled panel app (Flutter, linux-arm64). Unpack to `round_hud_app/build/linux/arm64/release/bundle` to skip a ~5 min build |
| `system-snapshot/` | config captured from the live Pi: `/etc` units, sudoers, udev rule, `/etc/dacpro.json`, user systemd units, PipeWire / WirePlumber / labwc / shairport config, `config.txt` + `cmdline.txt`, sample `/data` settings (MQTT password redacted), `ENVIRONMENT.md` (OS, package versions, enabled services) |
| `docs/porting-notes.md` | the running engineering log: every round of work, root causes, verifications |
| `docs/roadmap.md` | the early overhaul plan, kept for context |
| `docs/api-reference.md` | all 114 HTTP routes of the daemon, generated from the source |
| `docs/backlog.md` | ideas suggested but not built, in priority order |
| `design/` | UI design directions (HTML; open in a browser), the boot splash |
| `screenshots/` | captured from the panel: Now Playing, library home, clock, YouTube video, display-dimming test |
| `reference/upstream-ventuno-reference.tar.gz` | the original Ventuno Q project, for reference only. Not used at runtime |

**Not included, on purpose:** the Pi's SSH password, Google account credentials, the library's music files, the YouTube video cache, `node_modules`, Flutter build caches. Recreate them with the installers.

---

## 2. Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 4 Model B (4 GB) | Raspberry Pi OS **Trixie** (Debian 13, 64-bit desktop image), kernel 6.18 rpt |
| Raspberry Pi DAC Pro (TI PCM5242) | `dtoverlay=rpi-dacpro`, ALSA card `RPi DAC Pro`, driver `pcm512x`. On-board audio off (`dtparam=audio=off`, `vc4-kms-v3d,noaudio`) |
| Waveshare 5" round 1080×1080 HDMI LCD (sku 24369, panel id KTC WS050R) | HDMI + USB touch. **No backlight control, no DDC/CI, and the Pi 4's HDMI output has no gamma LUT**, so brightness, contrast and warmth are drawn by the app (§6) |

Device on the LAN: default hostname `roundplayer.local`. The web remote is at `http://roundplayer.local/` (port 80 redirects to 8080).

---

## 3. Architecture

```
 phone / browser ──► web_remote.py :8080 (PWA, proxies /api /media, WS telemetry relay)
                                   │
 YouTube app ──cast──► yt_receiver (Node, yt-cast-receiver, DIAL :8008) ──┐
 iPhone AirPlay ─────► shairport-sync (user unit) ─► airplay_meta.py ─────┤  HTTP
 Spotify app ────────► librespot (user unit) ─► librespot_event.sh ───────┤
 Home Assistant ◄────► mqtt_bridge.py (inside the daemon) ────────────────┤
                                                                          ▼
                 playback_manager.py  :8000  (FastAPI, THE source of truth)
                 ├─ numbered playback commands {seq,type,track_id,url,position_s,playing}
                 ├─ 60 Hz telemetry on unix socket /tmp/roundplayer_telemetry.sock
                 ├─ Hi-Fi library (hifi_manager / library_db SQLite / similar / playlists)
                 ├─ YouTube streams (yt_stream: yt-dlp → edl:// URL, no download)
                 ├─ DAC + EQ + crossfeed (dacpro-ctl → amixer + PipeWire filter-chain)
                 ├─ display (display-ctl state + schedule → telemetry)
                 └─ backup, OTA, health, alarm, sleep timer, watchdog
                                          │ telemetry (JSON lines)       ▲ POST /api/hud/state (2 Hz), /api/hud/ended,
                                          ▼                              │ /api/hud/advanced, /api/control ...
                 round_hud_app (Flutter, labwc kiosk, user unit) ────────┘
                 media_kit / libmpv 0.40 → PipeWire 1.4 → [RoundPlayer EQ sink] → DAC Pro (S32LE, native rate)
```

### The playback contract (the most important thing to understand)

1. **The daemon owns intent.** Every change (play, pause, seek, load, stop) becomes a numbered command (`cmd`, with `seq`) in `runtime_state`, carried in every telemetry packet.
2. **The panel only executes and reports.** The HUD applies each `seq` exactly once (`_applyDaemonCommand` in `main.dart`). It never changes playback on its own: buttons on the panel *ask* the daemon (`/api/control`), and the daemon answers with a command. It reports mpv's real position and state back (`POST /api/hud/state`; every 0.5 s while playing, at least every 2 s while paused).
3. **`hud_synced`** = panel fresh (< 3 s) + on the commanded track + in the commanded play state. The cast receiver waits for it before telling the phone "playing".
4. **End of track** → `POST /api/hud/ended {track_id}` → daemon decides: repeat-one, queue, next album track, autoplay-similar, or stop. Reports for a track that is no longer active are ignored.
5. **Gapless:** the daemon advertises `up_next` (`ready` = file on disk). The HUD appends it to mpv's playlist (`prefetch-playlist=yes`), mpv crosses the boundary itself, and the HUD calls `POST /api/hud/advanced {track_id, previous}`. The daemon *adopts* the track without issuing a load. Anything unplanned is "corrected" through the normal end-of-track path.
6. **Daemon restart:** the daemon boots in standby and issues a `stop` command. The HUD sees a lower `seq`, re-arms, and applies it. A restarted HUD calls `POST /api/hud/resync` and gets a `load` at the live position.

Bugs this design fixed (keep it): pause/play flapping, a cast disconnect resurrecting an older song, loads dropped while another file was opening, the HUD reporting "standby" after wake.

---

## 4. Repository map (`source/roundplayer/`)

| File / dir | Role |
|---|---|
| `playback_manager.py` (~4k lines) | Core daemon: playback state machine, all HTTP routes, telemetry, YouTube streaming glue, settings, sleep timer, alarm, backup, OTA, health, MQTT glue, external sources, lyrics |
| `yt_stream.py` | yt-dlp resolver: H.264 ≤1080p video + AAC merged into an `edl://` URL, or audio-only (opus) for YouTube Music. Cached until the URL's `expire=` |
| `hifi_manager.py` | Drive catalog (`/data/hifi_music/remote_library.json`, cached in memory by mtime), FLAC on-demand download with cancel/progress, LRU cache, covers (local → Drive → embedded → iTunes → Deezer) |
| `library_db.py` | SQLite index `/data/library.db`: tracks, FTS5 search, play log (plays, completed, skipped), albums, decades, heavy rotation, rediscover, never played, affinity |
| `similar.py` | "Keep playing like this": Deezer related artists (cached 30 d), same artist / era / format weights × play-log affinity |
| `hifi_playlists.py` | Playlists, favourites, older smart mixes (JSON files in `/data/hifi_playlists/`) |
| `sync_gdrive.py` | Indexes the public Google Drive music folder into the catalog |
| `network_manager.py` | Wi-Fi via nmcli: status, scan, connect, forget, hotspot; watchdog that raises the `RoundPlayer-Setup` hotspot after 3 min offline |
| `mqtt_bridge.py` | Home Assistant MQTT discovery device (paho 2.x) |
| `web_remote.py` + `web/` | Phone remote: single-page app + proxy |
| `yt_receiver/index.mjs` | YouTube cast receiver (yt-cast-receiver 2.1.0). Sends `source:'cast'`, `music:true` for YTMUSIC clients |
| `sources/` | AirPlay metadata bridge, librespot event hook, shairport config |
| `round_hud_app/` | Flutter panel app. `lib/main.dart` = engine (mpv, telemetry, command applier, legacy v1 UI). `lib/ui_v2/` = the current UI: `shell.dart`, `now_playing.dart`, `library.dart`, `settings.dart`, `screensaver.dart`, `tokens.dart` (design tokens + geometry), `model.dart` (HudView / HudActions contract), `keyboard.dart` |
| `round_hud_app/tools/vendor_media_kit_video.sh` | **Required before every build.** Vendors media_kit_video and patches a libmpv GL fence leak (one fd leaked per video frame, black screen after minutes) |
| `dacpro-ctl` | DAC / PipeWire / EQ / crossfeed CLI (root via sudoers). State `/etc/dacpro.json` |
| `display-ctl` | Display state + night schedule. State `/data/roundplayer_display.json` |
| `roundplayer-backup` | Root helper: copies the settings bundle to / from `/boot/firmware/roundplayer-backup.json` |
| `roundplayer-update` | OTA updater: download, stage, build, swap, health-gate, auto-rollback |
| `boot/` | Plymouth splash theme + installer, `readonly.sh` (opt-in read-only root) |
| `services/` | systemd units (`__USER__` / `__HOME__` placeholders filled by `install_pi.sh`) + udev rule |
| `install_pi.sh`, `install_sources.sh`, `deploy.sh` | Install / AirPlay + Spotify install / Mac → Pi push |
| `tests/` | `test_flows.py` (13 playback-flow cases with a fake HUD), `test_hifi_flow.py`, `test_cast_flow.py`, `test_web_remote.py` (Playwright) |
| `design/` | HTML design directions (the chosen one is "D: Gallery × Editorial") |
| `VERSION` | Shown in Diagnostics, used by OTA |

---

## 5. State and data on the device

| Location | What | Survives reboot |
|---|---|---|
| `/data/roundplayer_settings.json` | All player settings: volume, clock, shuffle/repeat, alarm, city, MQTT, update URL, YouTube options… | yes |
| `/data/roundplayer_display.json` | Brightness / contrast / warmth / night schedule | yes |
| `/etc/dacpro.json` | DAC, PipeWire and EQ / crossfeed settings | yes |
| `/data/hifi_music/` | Catalog JSON + album covers | yes |
| `/data/hifi_cache/` | Downloaded FLAC/MP3 (LRU, 10 GB cap, prunes at 8 GB) | yes |
| `/data/library.db` | SQLite index + play log (rebuilt automatically when the catalog changes) | yes |
| `/data/hifi_playlists/*.json` | Playlists, `favorites.json` | yes |
| `/data/roundplayer_history.json` | Recently played (200) | yes |
| `/data/roundplayer_resume.json` | Last track + position for wake / resume after a power cut (cleared when a cast is stopped) | yes |
| `/data/roundplayer_cache/<video_id>/` | YouTube: only `cover.jpg` now (plus a full copy if "keep a copy" is on) | yes |
| `/data/lyrics/` | LRCLIB cache | yes |
| `/data/backups/latest.json` + `/boot/firmware/roundplayer-backup.json` | Settings bundle, refreshed every 5 min when something changed | yes |
| `/data/hifi_related.json` | Deezer related-artist cache | yes |
| `/tmp/roundplayer_telemetry.sock` | Telemetry socket | no |
| `~/bin/hud_check.sh`, `hud_build_restart.sh`, `shot.sh` | Dev helpers (build, restart, screenshot); `/tmp` symlinks are recreated by hand after a reboot | yes (`~/bin`) |

**Data stays put:** `/data` is a directory on the root partition (`mmcblk0p2`). That is why the read-only-root option refuses to enable (§9).

---

## 6. Subsystems: how they work and their gotchas

### Audio path
- mpv: `ao=pipewire`, `audio-samplerate=0`, `audio-format=no`, `replaygain=no`, mpv volume pinned at 100 %. **The volume lives in the DAC** (`Digital Playback Volume`, 0.5 dB steps), so the digital path stays bit-perfect.
- Slider curve: dB = 40·log10(%) (50 % = −12 dB, 10 % = −40 dB, 0 = −103.5 dB). `volume_ceiling` caps it. The daemon persists `volume_pct` and applies it at boot. The HUD slider follows the daemon's telemetry `volume`.
- PipeWire: `51-dacpro.conf` (WirePlumber rule for the DAC) sets S32LE, allowed rates 44.1–192 k, resample quality 14, `session.suspend-timeout-seconds=0` and **`api.alsa.soft-mixer=true`**. Without that last one, WirePlumber restores a stale route volume into the DAC's hardware register every session (the "quiet after boot" bug).
- Boot order problem: the DAC card registers late, and udev's `alsactl restore` used to overwrite our settings. Now `dacpro.service` waits for the card and finishes with `alsactl store`, the `91-dacpro.rules` udev rule re-applies when the card appears, and the daemon's `apply_boot_volume()` does a **sound-check** (`dacpro-ctl verify` reads the registers back; it re-applies up to 3×). The result shows as `boot_check` in `/api/audio/live` and in Settings → Audio.
- **EQ / crossfeed:** a PipeWire filter-chain sink `roundplayer_eq` made default by WirePlumber while active. It is an explicit stereo graph (per-channel bass shelf, 5 peaking bands, treble shelf, optional loudness), plus optional crossfeed (low-pass of the other side mixed in). EQ off and crossfeed off means no filter at all (bit-perfect). Any EQ change restarts PipeWire (~1 s gap).
- The DAC filter is `fir` by default; the HUD recommends `ringless`.

### Library
- The catalog is a JSON tree built from a public Google Drive folder (`GOOGLE_DRIVE_FOLDER_ID` environment variable in `hifi_manager.py`). Files download on demand (prepare-then-play, cancellable; a newer request supersedes an older one via `prep_gen`).
- `library_db` rebuilds automatically whenever the catalog file's mtime changes. Search uses FTS5 with prefix matching and is diacritics-insensitive (~0.2 s for 1,546 tracks).
- Play log: a user pick or "next" within 20 s (or before half the track) counts as a skip; reaching the end counts as completed. `affinity` (0.15–2.5×) multiplies the autoplay weights.

### YouTube
- **Streams, doesn't download.** Resolve takes ~2.5–3 s (sometimes 10+ s on a slow YouTube response). Seeking uses HTTP range requests. YouTube Music casts (`video.client.key === 'YTMUSIC'`) play audio-only (opus) in the art layout with the thumbnail as cover.
- **yt-dlp must be recent.** The distro version (2025.04) only got 360p. The `--user` PyPI install (`yt-dlp[default]`, needs the `yt-dlp-ejs` extra plus a JS runtime; node 20 is there) gets 1080p. The daemon upgrades it weekly; the upgrade takes effect on the next restart. When YouTube breaks: `pip install -U --user --break-system-packages "yt-dlp[default]"`, then restart the daemon.
- Stream URLs expire after ~6 h. `_issue_cmd_locked` re-resolves in the background when a load needs an unknown or expired URL (resume, repeat, resync).
- Stopping a cast = standby **and** forget the resume point (tap → library home), on purpose.
- Pi 4 hardware decode is H.264 only (`hwdec=v4l2m2m-copy`). Never let yt-dlp pick VP9/AV1 for video.

### Panel (Flutter)
- The labwc kiosk starts `round_hud.service` (user unit) from `~/.config/labwc/autostart`. `LC_ALL=C` is mandatory (libmpv segfaults otherwise). `LimitNOFILE=65536`.
- **Build:** `flutter build linux --release --no-tree-shake-icons` (tree shaking broke the icon font) **after** `tools/vendor_media_kit_video.sh`. About 5 min on the Pi.
- Geometry: everything important is within a radius of 430 px; diameter buttons at y = 420; constants are in `ui_v2/tokens.dart`.
- Display settings are rendered by the app: a full-panel multiply overlay (brightness × colour-temperature tint) and a colour matrix for contrast. The values come from the daemon's telemetry (`display`). `gammastep` is only used if `ROUNDPLAYER_GAMMASTEP=1` (it does nothing on this hardware).
- Screenshot a specific screen: `~/bin/shot.sh <screen> /tmp/x.png [wait]`. Screen names come from `HUD_DEBUG_SCREEN`: `library`, `queue`, `search`, `youtube`, `saver`, `settings[:audio|wifi|system|eq|display|location|picker|password]`.

### Other sources
- AirPlay: shairport-sync **as a user unit** (Debian's system unit can't reach the user's PipeWire). Pulse backend into PipeWire, so EQ and DAC apply.
- Spotify Connect: librespot 0.8.0 from raspotify, run by our user unit (`--backend pulseaudio`, 320 kbps). raspotify's own service is disabled. Needs Premium.
- Both advertise as "Living Room Player". The daemon shows them as `ext:airplay` / `ext:spotify`.

### Reliability
- systemd `WatchdogSec=90` on the daemon (it pings every 15 s from its event loop).
- `/api/health` and Settings → System → Diagnostics: temperature, throttling, Wi-Fi RSSI and band, disk, memory, panel sync, DAC check, last 300 log lines (`/api/health/log`).
- **Wi-Fi drops SSH for minutes at a time.** This happens often. Power-save off is recommended (`iw wlan0 set power_save off`, made persistent with NetworkManager `wifi.powersave = 2`) but **not done yet**.

---

## 7. Build, deploy, operate

### Fresh device
1. Flash Raspberry Pi OS Trixie 64-bit desktop. User `bouncer` (or set `TARGET_USER`).
2. Copy `source/roundplayer` to `~/roundplayer`, then `sudo ./install_pi.sh`. This installs deps, Flutter, dacpro-ctl, units, sudoers, the NetworkManager polkit rule, the labwc autostart hook, the port 80 redirect and the boot config fragment, then builds the HUD. Reboot.
3. `./install_sources.sh` (AirPlay + Spotify).
4. `sudo ./boot/install_boot_theme.sh` (black boot + splash).
5. Settings restore themselves from `/boot/firmware/roundplayer-backup.json` if present (fresh `/data` + bundle on the card = same box). Otherwise use Settings → Backup → Restore from file on the remote.
6. Sync the library: the HUD or remote Drive sync (folder ID in `hifi_manager.py`).

### Day-to-day
```bash
sudo systemctl restart roundplayer_daemon roundplayer_web roundplayer_dial
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart round_hud
~/bin/hud_build_restart.sh            # analyze + vendor + build + restart HUD (log: /tmp/hud_build_restart.log)
journalctl -u roundplayer_daemon -f   # daemon log
journalctl --user -u round_hud -f     # panel log
dacpro-ctl show | dacpro-ctl verify   # DAC state
curl -s localhost:8000/api/health | python3 -m json.tool
```
- `deploy.sh` (Mac → Pi rsync) exists, but macOS's rsync lacks `--info`; scp per file was used in practice. It needs updating.
- The OTA button needs a source: `settings.update.url` = a `.tar.gz` of this tree (e.g. a GitHub archive URL). **There is no git repo yet; putting this source in one is step one for the new owner** (see backlog #17).

### Tests
```bash
python3 -I tests/test_hifi_flow.py --setup        # creates a fake Drive + catalog
HIFI_FAKE_DRIVE=/tmp/fake_drive ROUNDPLAYER_NO_NET_WATCHDOG=1 python3 playback_manager.py &
python3 -I tests/test_flows.py                     # 13 cases, expect "ALL OK"
```
These run anywhere (no Pi needed). They cover pause→pick, rapid switching, cast ownership and stop, sleep/wake, end of track, repeat-one, autoplay similar, play/pause sequences, stale ended, similar mix, gapless adopt/correct.

---

## 8. Accounts and access the new coder needs

- **Pi SSH:** standard SSH access on user `pi` or configured system user.
- **Google Drive:** the library is a public folder read by ID; no credentials in code.
- **Spotify:** Premium account on the phone (librespot uses zeroconf; nothing stored on the box except `~/.cache/librespot`).
- **Home Assistant:** broker host and user are set from the remote; the password lives in `/data/roundplayer_settings.json` (plaintext) and in the backup bundle.
- **LRCLIB, Deezer, iTunes, Open-Meteo:** public, keyless.

---

## 9. Known issues and open items (prioritised)

1. **Wi-Fi power save.** (Resolved in repo) Added `default-wifi-powersave-disable.conf` to NetworkManager drop-in, updated `network_manager.py` to enforce `powersave = 2`. Needs live application on the Pi (`nmcli connection modify <ssid> 802-11-wireless.powersave 2`).
2. **No git repo / CI.** Source lives in three copies (Mac Desktop, Mac `~/pi-ssh-mcp`, Pi). Make this zip's `source/` the initial commit.
3. **OTA sudoers permissions.** (Resolved in repo) Sudoers updated in `install_pi.sh` and `sudoers.d-roundplayer` to whitelist `/usr/bin/install -m0755` for `dacpro-ctl` and `display-ctl`. `roundplayer-update` updated.
4. **Read-only root** is not enabled: `/data` is on the root partition. `boot/readonly.sh move-data /dev/sdX1` (USB stick), then `enable`.
5. **Things not yet tested by hand:** gapless by ear, AirPlay from an iPhone, Spotify, lyrics, alarm, crossfeed on headphones, MQTT against the real Home Assistant (verified only against a local test broker), a real YouTube Music cast (audio-only path verified only via the resolver + mpv CLI).
6. **Legacy v1 UI in main.dart.** (Resolved in repo) Pruned ~7,000 lines of dead v1 UI code; `main.dart` now cleanly connects the engine directly to `HudShell` (v2).
7. `README.md` inside the source predates several rounds (it says YouTube is downloaded). This handover supersedes it.
8. `dial_server.py` is an unused fallback.
9. YouTube resolve occasionally takes 10+ s (YouTube side). The cast receiver waits up to 30 s.

---

## 10. Backlog (suggested, not built)

See `docs/backlog.md`. Top picks: VU-meter / visualiser mode for the round screen, internet radio (Radio Browser API), a haptic volume knob (gimbal BLDC + MT6835 + SimpleFOC rig, i.e. SmartKnob-style), the Wi-Fi power-save fix, pre-caching favourites and heavy rotation.

---

## 11. Decision log (short)

| Decision | Why |
|---|---|
| Daemon owns playback intent; HUD only applies numbered commands | Removed flapping / resurrection / dropped-load bugs (Oct 16) |
| Volume in the DAC, mpv at 0 dB, PipeWire soft-mixer at unity | Bit-perfect; WirePlumber was writing stale volumes into the DAC |
| Design D "Gallery × Editorial" (Bebas Neue / Inter Tight / IBM Plex Mono, full-bleed cover) | Selected from rendered options; no ring volume, no rotating disc, no power button |
| Display effects rendered in-app | Panel has no backlight, DDC/CI or gamma LUT |
| YouTube streamed (EDL) instead of downloaded | Casts started only after a full download |
| SQLite + FTS5 for the library | Instant search, play log, albums/decades, better autoplay |
| shairport/librespot as *user* units | They must reach the user session's PipeWire for EQ/DAC |
| Cast stop forgets the resume point | "Stop casting" should mean standby, not pause |

## 12. Changes since the last version tag
- Video: the dark gradient now fades out with the controls (it used to dim the lower half permanently).
- Cast stop: full standby, resume point cleared; daemon issues `stop` at startup so a surviving HUD matches.
- `install_sources.sh` no longer installs `bs2b-ladspa` (crossfeed uses PipeWire builtins).
