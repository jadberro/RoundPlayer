# Round Media Player — roadmap

## 2026-10-16 — overhaul plan (after DAC arrived)
Early report: DAC works but muffled vs Ventuno; touch laggy on resume; requesting a song from the list laggy; can't scroll lists. Pi was unreachable at the time (SSH timeout) — verify audio-path facts when back.

Diagnosis:
- Muffled: dacpro-ctl apply/PipeWire config never written (no sudo) → PipeWire at 48k/S16 default, quality-4 resample of 44.1k + 16-bit truncation; replaygain=album + loudnorm on; DSP program fir (Ventuno ran ringless).
- Can't scroll: Flutter GTK embedder delivers touch as mouse → ListViews don't drag-scroll without `ScrollBehavior.dragDevices` incl. touch/mouse.
- Laggy resume/select: single 8.7k-line StatefulWidget, every setState rebuilds everything; mode switch remounts video surface; song tap awaits HTTP before UI changes; 60 Hz JSON parse on UI isolate; 3 s boot sequence.

Plan:
A. Audio (needs sudo once): dacpro.service at boot, S32LE native-rate following, resample q14, dither off, DSP ringless, auto-mute off, volume in DAC, mpv 0 dB, replaygain=no, loudnorm off by default; Settings→Audio shows negotiated rate/bits from pw-dump + PLL lock.
B. HUD overhaul: split into PlayerScreen/Centerpiece/HiFiBrowser/SettingsDeck/QueueSheet with shared AppState; app-wide ScrollBehavior (touch+mouse), ListView.builder + itemExtent; optimistic UI for song select/transport; Offstage video during centerpiece for instant resume; 56 px targets; drop boot sequence; telemetry parse off UI isolate or 15 Hz.
C. Backend: HUD → daemon real mpv position/state; SQLite catalog + paged tree; yt-dlp H.264 ≤1080p; Wi-Fi via NetworkManager (status/scan/connect/forget/hotspot) + Settings→Network tab.
D. Measure: tap-to-paint latency p50/p95 in HUD_PERF; targets <80 ms tap feedback, 60 fps lists, resume <300 ms.
Order: sudo+audio A/B → scroll/optimistic/boot quick wins → widget split + Offstage → backend/Wi-Fi → prioritized punchlist.

(Historical — all of A–C was done in later rounds; see porting-notes.md. The v2 UI in lib/ui_v2 is the result of B.)

## Earlier (2026-10-14) ideas still valid
Gapless/crossfade; mutagen+SQLite library; AirPlay (shairport-sync) + Spotify Connect (librespot); persistent queue/resume; cheap FFT visualiser; idle dim/DPMS wake on touch; HUD watchdog; log rotation.
(Done since: gapless, SQLite library, AirPlay, Spotify Connect, resume, HUD/daemon watchdog. Open: crossfade, visualiser, log rotation.)
