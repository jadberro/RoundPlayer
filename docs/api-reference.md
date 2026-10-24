# Daemon HTTP API (playback_manager.py, port 8000)

Generated from the source on 2026-10-24. The web remote (web_remote.py, port 8080 / 80) proxies `/api/*` and `/media/*` to this daemon.
The HUD and the remote use these endpoints; the HUD also reads the 60 Hz telemetry stream on the unix socket `/tmp/roundplayer_telemetry.sock` (one JSON object per line), the remote reads the same packets over `ws://<pi>:8080/ws/telemetry`.

114 routes.

## /

| Method | Path | Handler | Notes |
|---|---|---|---|
| ON_EVENT | `startup` | `startup_event` (L1495) |  |

## audio

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/audio/eq` | `get_eq` (L3701) |  |
| POST | `/api/audio/eq` | `set_eq` (L3714) | {"preset": "warm"} or any of enabled/bass/treble/bands/loudness. Restarts PipeWire (~1 s gap). |
| GET | `/api/audio/live` | `get_audio_live` (L2477) | Measured audio path: PipeWire sink rate/format, HUD-reported mpv output, DAC readback. For the 'bit-perfect' indicator. |
| POST | `/api/audio/preset/best-quality` | `apply_best_quality_preset` (L2247) | Applies reference audiophile preset across all 14 parameters without restarting during playback. |
| POST | `/api/audio/reset` | `reset_audio_settings` (L2235) | Resets all DAC Pro and PipeWire audio parameters to factory defaults. |
| GET | `/api/audio/settings` | `get_audio_settings` (L2159) | Returns saved settings from /etc/dacpro.json and live DAC telemetry. |
| POST | `/api/audio/settings` | `update_audio_settings` (L2211) | Updates one or more audio settings and persists them via dacpro-ctl without dropping playback. |
| POST | `/api/audio/volume` | `set_hardware_dac_volume` (L2278) | Sets DAC digital volume directly (-103.5 to 0.0 dB). Lossless 32-bit path. |

## backup

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/backup` | `get_backup` (L3182) |  |
| POST | `/api/backup/restore` | `restore_backup_endpoint` (L3207) |  |
| POST | `/api/backup/save` | `save_backup_now` (L3186) |  |
| GET | `/api/backup/status` | `backup_status` (L3191) |  |

## cache

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/cache/clear` | `clear_cached_music` (L1734) |  |
| GET | `/api/cache/status/{video_id}` | `get_cache_status` (L1764) |  |
| POST | `/api/cache/{video_id}` | `trigger_cache` (L1753) |  |
| POST | `/cache/clear` | `clear_cached_music` (L1734) |  |
| GET | `/cache/status/{video_id}` | `get_cache_status` (L1764) |  |
| POST | `/cache/{video_id}` | `trigger_cache` (L1753) |  |

## cast

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/cast/senders` | `cast_senders` (L2809) | yt-cast-receiver reports the phones currently connected (for the HUD's CASTING pill). |

## control

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/control` | `handle_control` (L1906) |  |
| POST | `/control` | `handle_control` (L1906) |  |

## display

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/display` | `get_display` (L3671) |  |
| POST | `/api/display` | `set_display` (L3675) |  |

## external

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/external/cover` | `external_cover` (L3362) |  |

## health

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/health` | `health_endpoint` (L3515) |  |
| GET | `/api/health/log` | `health_log` (L3520) |  |

## hifi

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/hifi/albums` | `albums_endpoint` (L3937) |  |
| GET | `/api/hifi/albums/{key}` | `album_tracks_endpoint` (L3943) |  |
| POST | `/api/hifi/cache/prune` | `post_hifi_cache_prune` (L2773) |  |
| GET | `/api/hifi/cache/stats` | `get_hifi_cache_stats` (L2768) |  |
| GET | `/api/hifi/cover` | `get_hifi_cover` (L2739) | Album cover: local file, else Drive, else the picture embedded in a cached track, else iTunes/Deezer lookup |
| GET | `/api/hifi/decades` | `decades_endpoint` (L3949) |  |
| GET | `/api/hifi/drive_folders` | `get_drive_folders` (L3762) |  |
| GET | `/api/hifi/favorites/check` | `check_favorite_endpoint` (L3908) |  |
| POST | `/api/hifi/favorites/toggle` | `toggle_favorite_endpoint` (L3896) |  |
| POST | `/api/hifi/notify_library_update` | `notify_library_update` (L3757) |  |
| POST | `/api/hifi/play` | `play_hifi_endpoint` (L2797) |  |
| GET | `/api/hifi/playlists` | `list_playlists_endpoint` (L3827) |  |
| POST | `/api/hifi/playlists` | `create_playlist_endpoint` (L3838) |  |
| DELETE | `/api/hifi/playlists/{playlist_id}` | `delete_playlist_endpoint` (L3859) |  |
| GET | `/api/hifi/playlists/{playlist_id}` | `get_playlist_endpoint` (L3831) |  |
| POST | `/api/hifi/playlists/{playlist_id}/add` | `add_to_playlist_endpoint` (L3842) |  |
| POST | `/api/hifi/playlists/{playlist_id}/play` | `play_playlist_endpoint` (L3865) |  |
| POST | `/api/hifi/playlists/{playlist_id}/remove` | `remove_from_playlist_endpoint` (L3855) |  |
| POST | `/api/hifi/scan` | `trigger_hifi_scan` (L2733) |  |
| GET | `/api/hifi/search` | `search_hifi_endpoint` (L2707) |  |
| GET | `/api/hifi/similar` | `similar_endpoint` (L3607) | A mix of library tracks like the given track (or artist radio). Used by Smart mixes and the phone remote. |
| POST | `/api/hifi/similar/play` | `similar_play_endpoint` (L3625) | Build the mix on the daemon and play it: first track now, the rest queued (one round-trip for the HUD). |
| GET | `/api/hifi/smart_playlist` | `smart_playlist_endpoint` (L3912) |  |
| GET | `/api/hifi/stats` | `listening_stats` (L3955) |  |
| POST | `/api/hifi/sync_drive` | `sync_drive_endpoint` (L3767) |  |
| GET | `/api/hifi/sync_status` | `get_hifi_sync_status` (L3774) |  |
| GET | `/api/hifi/tree` | `get_hifi_tree` (L2702) |  |

## history

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/history` | `history_endpoint` (L3572) |  |

## hud

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/hud/advanced` | `hud_advanced` (L2888) | Gapless: mpv moved on its own into the track the HUD pre-opened. If it is the one we planned, adopt it as |
| POST | `/api/hud/ended` | `hud_ended` (L2863) | mpv reached the end of the active track. Repeat-one replays it; otherwise the queue / album / autoplay decides. |
| POST | `/api/hud/resync` | `hud_resync` (L3735) | A (re)started HUD asks for the current track again: re-issue a 'load' at the live position in the current |
| GET | `/api/hud/state` | `get_hud_state` (L2412) | What the HUD last reported (debug / remote). |
| POST | `/api/hud/state` | `post_hud_state` (L2417) | The HUD reports mpv's real position/duration/state (~2 Hz). Everything else reads it via current_position_s(). |

## lyrics

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/lyrics` | `lyrics_endpoint` (L4055) |  |

## media

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/media/hifi/{track_id}/beats` | `get_hifi_beats` (L2759) |  |
| GET | `/media/hifi/{track_id}/stream` | `stream_hifi_track` (L2748) | Serves a cached Hi-Fi file. Never downloads inline (that used to freeze the whole daemon for the duration of a |
| GET | `/media/{video_id}/audio.wav` | `serve_audio` (L2612) |  |
| GET | `/media/{video_id}/beats` | `serve_beats` (L2634) |  |
| GET | `/media/{video_id}/cover.jpg` | `serve_cover` (L2619) |  |
| GET | `/media/{video_id}/dominant_color` | `get_color` (L2649) |  |
| GET | `/media/{video_id}/video.mp4` | `serve_video` (L2605) |  |

## network

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/network/connect` | `network_connect` (L2535) |  |
| POST | `/api/network/forget` | `network_forget` (L2557) |  |
| POST | `/api/network/hotspot` | `network_hotspot` (L2561) |  |
| GET | `/api/network/prefs` | `network_prefs` (L2539) |  |
| POST | `/api/network/prefs` | `network_set_prefs` (L2543) |  |
| POST | `/api/network/regdomain` | `network_regdomain` (L2553) |  |
| GET | `/api/network/saved` | `network_saved` (L2531) |  |
| GET | `/api/network/scan` | `network_scan` (L2527) |  |
| GET | `/api/network/status` | `network_status` (L2523) |  |

## play

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/play/{video_id}` | `set_active_track` (L1784) |  |
| POST | `/play/{video_id}` | `set_active_track` (L1784) |  |

## playback

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/playback/modes` | `get_playback_modes` (L3787) |  |
| POST | `/api/playback/modes` | `set_playback_modes` (L3795) |  |

## prepare

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/prepare/cancel` | `cancel_prepare_endpoint` (L2802) |  |

## queue

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/queue` | `get_queue` (L1957) |  |
| POST | `/api/queue/add` | `add_to_queue` (L1962) |  |
| POST | `/api/queue/clear` | `clear_queue` (L2000) |  |
| POST | `/api/queue/next` | `play_next_in_queue_endpoint` (L2006) |  |
| POST | `/api/queue/prev` | `play_prev_in_history` (L2049) |  |
| POST | `/api/queue/remove/{index}` | `remove_from_queue` (L1992) |  |

## resume

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/resume` | `resume_endpoint` (L2919) |  |
| GET | `/api/resume/info` | `resume_info` (L3561) | What a wake would bring back (for the Home screen's 'Continue listening'). |

## search

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/search` | `search` (L1658) |  |
| POST | `/api/search/history/clear` | `clear_search_history` (L2599) |  |
| GET | `/search` | `search` (L1658) |  |

## settings

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/settings` | `get_settings` (L2140) |  |
| POST | `/api/settings` | `update_settings` (L2144) |  |

## sleep_timer

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/sleep_timer` | `get_sleep_timer` (L2958) |  |
| POST | `/api/sleep_timer` | `set_sleep_timer` (L2948) |  |

## source

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/source/{name}/meta` | `external_meta` (L3272) |  |
| POST | `/api/source/{name}/start` | `external_start` (L3237) |  |
| POST | `/api/source/{name}/stop` | `external_stop` (L3330) |  |

## sources

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/sources/status` | `sources_status` (L3347) |  |

## state

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/state` | `get_system_state` (L1602) |  |

## system

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/system/ip` | `get_system_ip` (L2566) |  |
| GET | `/api/system/qr.png` | `get_system_qr` (L2571) |  |
| POST | `/api/system/restart-services` | `restart_services` (L2594) |  |

## tracks

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/tracks` | `list_tracks` (L1633) |  |
| GET | `/tracks` | `list_tracks` (L1633) |  |

## update

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/update/rollback` | `update_rollback` (L3442) |  |
| POST | `/api/update/start` | `update_start` (L3435) |  |
| GET | `/api/update/status` | `update_status` (L3423) |  |

## weather

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/weather` | `get_weather` (L1539) |  |
| POST | `/api/weather/city` | `set_weather_city` (L1569) |  |
| GET | `/api/weather/search` | `search_weather_city` (L1545) |  |

## ws

| Method | Path | Handler | Notes |
|---|---|---|---|
| WEBSOCKET | `/ws/telemetry` | `websocket_telemetry` (L2663) |  |
