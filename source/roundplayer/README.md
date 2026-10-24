> **Note (2026-10-24):** parts of this README are out of date (for example, YouTube now streams instead of downloading). See `HANDOVER.md` at the root of the handover package.

# Round Media Player (Raspberry Pi 4 + DAC Pro + 5" round HUD)

A music/video player with a 1080×1080 circular touch HUD, bit-perfect output through a Raspberry Pi DAC Pro,
a mobile web remote, YouTube casting, and a lossless Google-Drive-backed Hi-Fi library.

This is the media-player-only port of the Ventuno Q "3-RRS Ballistic Juggler" build. All juggler, motor,
kinematics and machine-vision code has been removed; the beat/BPM analysis stays because the HUD visuals use it.

```
┌───────────────────────────────────────────────────────────────────────┐
│                     Mobile Web Remote  (web_remote.py :8080 / :80)     │
│   YouTube / Shorts / URL casting · queue · Hi-Fi library · DAC tuning  │
└──────────────────────────────────┬────────────────────────────────────┘
                                   │ HTTP + WebSocket proxy
                                   ▼
┌───────────────────────────────────────────────────────────────────────┐
│               Playback Manager  (playback_manager.py :8000)           │
│   yt-dlp 1080p cache · aubio BPM · Hi-Fi FLAC catalog · weather clock  │
│   60 Hz telemetry on /tmp/roundplayer_telemetry.sock                   │
└───────────────┬──────────────────────────────────┬────────────────────┘
                │ yt-cast-receiver (DIAL)          │ telemetry socket
                ▼                                  ▼
   YouTube app "cast to"                ┌────────────────────────────────┐
   Living Room Player                   │  Round HUD  (Flutter, labwc)   │
                                        │  media_kit/mpv → PipeWire →    │
                                        │  DAC Pro (pcm512x, S32LE)      │
                                        └────────────────────────────────┘
```

## Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 4 (64-bit Raspberry Pi OS, desktop image) | labwc Wayland session runs the kiosk |
| Raspberry Pi DAC Pro (PCM5242) | `dtoverlay=rpi-dacpro` → native `pcm512x` ALSA driver; on-board audio disabled |
| Waveshare 5" 1080×1080 round HDMI LCD (sku 24369) | HDMI + USB touch; EDID gives 1080×1080@60 under KMS |

## Install (first time)

On the Mac:

```bash
ssh-copy-id pi@roundplayer.local     # once (or use PI_USER/PI_HOST env)
./deploy.sh install                   # rsync + sudo ./install_pi.sh on the Pi
```

`install_pi.sh` installs apt/pip/npm deps, Node 20, the Flutter SDK (git, arm64), appends
`pi/config-roundplayer.txt` to `/boot/firmware/config.txt`, installs `dacpro-ctl`, the systemd units,
the labwc autostart hook, autologin and the :80→:8080 redirect, then builds the HUD. Reboot when it says so.

Day-to-day:

```bash
./deploy.sh hud        # push + rebuild Flutter HUD + restart it
./deploy.sh restart    # push + restart the Python/Node services
```

## Playback commands (how casting / play / pause stay in sync)

The daemon is the single source of truth for playback *intent*. Every state change (`/api/play/{id}`,
`/api/hifi/play`, queue next/prev, `/api/control` play/pause/seek/idle/stop_cast, cast receiver) issues a
numbered command - `{"seq", "type": load|play|pause|seek|stop, "track_id", "position_s", "playing"}` - carried in
every telemetry packet as `cmd`. The HUD applies each `seq` exactly once (`_applyDaemonCommand`) and reports mpv's
real position/state back via `POST /api/hud/state`; `/api/state` exposes `hud_synced`, which the YouTube cast
receiver waits for before telling the phone "playing". Nothing diffs `is_playing` against local state any more,
so pause can't flap and a cast can't open a half-downloaded file. `tests/test_cast_flow.py` drives the whole
sequence with a fake HUD.

## Web remote

`web_remote.py` is a thin server: it serves the SPA in `web/` and transparently proxies `/api/*` and `/media/*`
to the playback manager, plus `/ws/telemetry` (10 Hz relay of the daemon's socket). Tabs: Now playing, Library
(Hi-Fi tree, search, playlists, smart mixes), YouTube (search/paste link/cached), Queue, Settings (measured
audio path, DAC Pro options, Wi-Fi, player). `tests/test_web_remote.py` is a Playwright smoke test.

## Wi-Fi

`network_manager.py` wraps `nmcli` (NetworkManager, the Pi OS default). `/api/network/{status,scan,saved,connect,
forget,hotspot}` back both the HUD's Settings → Network tab (with on-screen keyboard) and the web remote. A watchdog
brings up the `RoundPlayer-Setup` hotspot (password `roundplayer`) after 3 min with no network so the box stays
reachable. The installer adds a polkit rule so the daemon's user can manage connections.

## Services

| Unit | What |
|---|---|
| `roundplayer_daemon` | playback manager + telemetry (system) |
| `roundplayer_web` | mobile web remote (system) |
| `roundplayer_dial` | YouTube cast receiver (system) |
| `dacpro` | re-applies saved DAC/PipeWire settings at boot (system, oneshot) |
| `round_hud` | Flutter kiosk (user unit, started from `~/.config/labwc/autostart`) |

```bash
sudo systemctl restart roundplayer_daemon roundplayer_web roundplayer_dial
systemctl --user restart round_hud
```

## DAC Pro tuning

Everything the old build poked over I2C is an ALSA mixer control on the Pi, so `dacpro-ctl` wraps `amixer`
and keeps the same CLI the web remote / HUD settings panel call:

```bash
dacpro-ctl show
sudo dacpro-ctl set filter ringless
sudo dacpro-ctl set volume -3
sudo dacpro-ctl set pw-hires on        # S32LE, follows 44.1/48/88.2/96/176.4/192 kHz natively
```

Settings persist in `/etc/dacpro.json`. Channel routing (`channels`) is done in PipeWire's channelmix since
the driver does not expose the DAC crossbar.

## Data layout

```
/data/roundplayer_cache/<video_id>/   video.mp4 audio.wav cover.jpg beats.npy meta.json
/data/hifi_music/                     Drive-indexed lossless catalog + covers
/data/hifi_cache/                     on-demand FLAC LRU cache
/data/hifi_playlists/                 playlists + favorites
/data/roundplayer_settings.json       HUD/remote settings
```

## Layout

```
playback_manager.py   core daemon (FastAPI :8000)
web_remote.py         PWA remote (FastAPI :8080)
hifi_manager.py       lossless catalog / cache / aubio onset
hifi_playlists.py     playlists, favorites, smart mixes
sync_gdrive.py        Google Drive folder indexer
dial_server.py        standalone DIAL fallback (not run as a service)
yt_receiver/          yt-cast-receiver bridge (Node)
round_hud_app/        Flutter HUD
dacpro-ctl            DAC Pro / PipeWire tuning CLI
services/             systemd units (placeholders filled by install_pi.sh)
pi/                   boot config fragment
install_pi.sh         on-Pi installer
deploy.sh             Mac → Pi push / build / restart
```

MIT License.
