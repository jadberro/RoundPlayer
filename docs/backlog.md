# Backlog: suggested, not built (as of 2026-10-24)

Ordered by value. Proposed features and future enhancements; nothing below exists in the code yet.

## Do first
1. **[DONE in code] Wi-Fi power save off.** Added NetworkManager drop-in `default-wifi-powersave-disable.conf` and updated `network_manager.py`. Run `nmcli connection modify <ssid> 802-11-wireless.powersave 2` on the Pi to apply live.
2. **Git repo + CI.** Make `source/roundplayer` the initial commit. Add a GitHub Actions arm64 Linux build of `round_hud_app` (run `tools/vendor_media_kit_video.sh` first, build with `--no-tree-shake-icons`) that publishes release tarballs. Point `settings.update.url` at them, so OTA takes ~30 s instead of building on the Pi.
3. **Pre-cache:** on Wi-Fi, keep favourites, heavy rotation and recently played on the card so Drive outages never interrupt.

## Round screen
4. **VU meter mode:** analogue needle meters driven by a PipeWire monitor tap. The single most striking use of a round display.
5. **Spectrum / visualiser mode** (cheap FFT on the monitor tap, sent over telemetry at ~30 Hz).
6. **Watch faces** for the screensaver: analogue, editorial (current), now-playing ring.
7. **Artist page:** photo, bio, related artists (Deezer / Wikipedia), opened from "Go to artist".

## Physical
8. **Haptic knob:** SmartKnob-style detents for volume, spring for scrubbing, click for play/pause. Prototype rig (gimbal BLDC + MT6835 encoder + SimpleFOC on an Arduino) fits; talk to the daemon over USB serial.
9. **Approach-to-wake** with a ToF or PIR sensor on GPIO.

## Listening
10. **Internet radio** via the Radio Browser API (free): favourite stations, "stations like this artist". Biggest content gap.
11. **Loudness matching** (ReplayGain-style): one EBU R128 scan into `library_db`, applied as a DAC offset; off for purists.
12. **Genres / moods** from MusicBrainz / Last.fm into the index: genre and mood mixes, better similar.
13. **Last.fm scrobbling** from the existing play log.
14. **Rule-based playlists** (decade + format + plays + skips) built in the remote.

## Rooms and people
15. **Multi-room** with Snapcast.
16. **Bluetooth** in (phone as source) and out (headphones, with crossfeed).
17. **Profiles and guest lock:** per-person history and favourites; PIN on Settings plus a volume cap.

## Engineering
18. **Golden screenshot tests** of every panel screen in CI (the `HUD_DEBUG_SCREEN` hooks already exist).
19. **[DONE] Delete the legacy v1 UI from main.dart.** Pruned ~7,000 lines of dead v1 UI; HUD engine now directly mounts HudShell.
20. Update `deploy.sh` for macOS rsync (no `--info`), or replace it with git pull + OTA.
21. **[DONE in code] Add the OTA install steps for dacpro-ctl / display-ctl to sudoers.** Whitelisted `/usr/bin/install -m0755` in `install_pi.sh` and sudoers.
22. Move `/data` to its own partition or USB device, then enable the read-only root (`boot/readonly.sh`).
