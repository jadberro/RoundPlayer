// The contract between the playback engine (main.dart: media_kit player, telemetry, command applier) and the
// v2 screens. The engine builds a fresh HudView on every setState; the 60 Hz values travel as ValueNotifiers so
// the transport/seek widgets repaint without rebuilding the tree.
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

class HudView {
  const HudView({
    required this.activeId,
    required this.title,
    required this.artist,
    required this.album,
    required this.isHiFi,
    required this.audioFormat,
    required this.bitDepth,
    required this.sampleRateHz,
    required this.videoController,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.volume,
    required this.accent,
    required this.vinylRotation,
    this.preparingId,
    this.preparingTitle,
    this.preparingArtist,
    this.preparingStatus = '',
    this.preparingPercent = 0,
    this.hifiTree,
    this.cachedTracks = const [],
    this.searchResults = const [],
    this.hifiSearchResults = const [],
    this.isSearching = false,
    this.weatherCity = '',
    this.weatherTemp = 0,
    this.weatherIcon = Icons.wb_sunny_rounded,
    this.weatherCondition = '',
    this.idleTimeoutSeconds = 120,
    this.audioSettings = const {},
    this.dacReadback = const {},
    this.audioFeedback,
    this.netStatus = const {},
    this.netScan = const [],
    this.netScanning = false,
    this.netConnecting = false,
    this.netMessage = '',
    this.shuffle = false,
    this.repeat = 'all',
    this.upNextTitle,
    this.upNextArtist,
    this.castSenders = const [],
    this.playlists = const [],
    this.cityResults = const [],
    this.cityLoading = false,
    this.autoplaySimilar = true,
    this.clock24h = false,
    this.displayFx,
    this.sleepInS,
    this.volumeCeiling = 100,
    this.alarm = const {},
    this.audioOnly = false,
    this.videoHeight,
    this.hifiSyncStatus = 'idle',
    this.hifiSyncMessage = '',
    this.hifiSyncAdded = 0,
    this.hifiSyncTotal = 0,
  });

  final String activeId; // 'standby', YouTube id, or 'hifi_<id>'
  final String title;
  final String artist;
  final String album;
  final bool isHiFi;
  final String audioFormat;
  final int bitDepth;
  final int sampleRateHz;
  final VideoController videoController;
  final ValueNotifier<Duration> position;
  final ValueNotifier<Duration> duration;
  final ValueNotifier<bool> isPlaying;
  final ValueNotifier<double> volume;
  final ValueNotifier<Color> accent;
  final Animation<double> vinylRotation;

  final String? preparingId;
  final String? preparingTitle;
  final String? preparingArtist;
  final String preparingStatus;
  final int preparingPercent;

  final Map<String, dynamic>? hifiTree;
  final List<Map<String, dynamic>> cachedTracks;
  final List<Map<String, dynamic>> searchResults;
  final List<Map<String, dynamic>> hifiSearchResults;
  final bool isSearching;

  final String weatherCity;
  final double weatherTemp;
  final IconData weatherIcon;
  final String weatherCondition;
  final int idleTimeoutSeconds;

  final Map<String, dynamic> audioSettings;
  final Map<String, dynamic> dacReadback;
  final String? audioFeedback;

  final Map<String, dynamic> netStatus;
  final List<Map<String, dynamic>> netScan;
  final bool netScanning;
  final bool netConnecting;
  final String netMessage;

  final bool shuffle;
  final String repeat;
  final String? upNextTitle;
  final String? upNextArtist;
  final List<String> castSenders;
  final List<Map<String, dynamic>> playlists;
  final List<Map<String, dynamic>> cityResults;
  final bool cityLoading;
  final bool autoplaySimilar;
  final bool clock24h;
  /// Effective brightness/contrast/warmth from the daemon (telemetry): {brightness, contrast, warmth, night_active}.
  final ValueNotifier<Map<String, dynamic>>? displayFx;
  final double? sleepInS;          // sleep timer countdown (telemetry), null = off
  final int volumeCeiling;         // settings.volume_ceiling
  final Map<String, dynamic> alarm; // settings.alarm
  final bool audioOnly;            // YouTube Music / audio-only stream
  final int? videoHeight;          // streamed video height (1080, 720, 360 ...)
  final String hifiSyncStatus;     // 'idle', 'syncing', 'complete', 'error'
  final String hifiSyncMessage;    // Live status or summary string
  final int hifiSyncAdded;         // Number of new tracks added
  final int hifiSyncTotal;         // Total tracks in library

  bool get isStandby => activeId == 'standby';
  bool get isExternal => activeId.startsWith('ext:');   // AirPlay / Spotify Connect: shown, not driven, by the HUD
}

class HudActions {
  const HudActions({
    required this.togglePlay,
    required this.next,
    required this.prev,
    required this.seekTo,
    required this.seekBy,
    required this.setVolume,
    required this.standby,
    required this.wake,
    required this.playHiFi,
    required this.playYouTube,
    required this.playSearchResult,
    required this.addToQueue,
    required this.cancelPreparing,
    required this.loadHiFiTree,
    required this.syncHiFiLibrary,
    required this.loadCachedTracks,
    required this.searchYouTube,
    required this.searchHiFi,
    required this.saveSettings,
    required this.updateAudioSetting,
    required this.loadAudioSettings,
    required this.loadNetworkStatus,
    required this.scanNetworks,
    required this.connectWifi,
    required this.forgetWifi,
    required this.setBand,
    required this.toggleHotspot,
    required this.toggleShuffle,
    required this.toggleRepeat,
    required this.restartServices,
    required this.touch,
    required this.loadPlaylists,
    required this.playPlaylist,
    required this.playSmartMix,
    required this.searchCity,
    required this.selectCity,
    required this.playSimilar,
    required this.setRepeat,
  });

  final VoidCallback togglePlay;
  final VoidCallback next;
  final VoidCallback prev;
  final void Function(Duration) seekTo;
  final void Function(int seconds) seekBy;
  final void Function(double) setVolume;
  final VoidCallback standby;
  final VoidCallback wake;
  final void Function(String trackId, {List<Map<String, dynamic>>? playlist, int? index}) playHiFi;
  final void Function(String videoId) playYouTube;
  final void Function(Map<String, dynamic> track) playSearchResult;
  final void Function(Map<String, dynamic> track) addToQueue;
  final VoidCallback cancelPreparing;
  final Future<void> Function({bool force}) loadHiFiTree;
  final Future<void> Function() syncHiFiLibrary;
  final Future<void> Function() loadCachedTracks;
  final Future<void> Function(String q) searchYouTube;
  final Future<void> Function(String q) searchHiFi;
  final Future<void> Function(Map<String, dynamic> patch) saveSettings;
  final Future<void> Function(String key, dynamic value) updateAudioSetting;
  final Future<void> Function() loadAudioSettings;
  final Future<void> Function() loadNetworkStatus;
  final Future<void> Function() scanNetworks;
  final Future<void> Function(String ssid, String? psk) connectWifi;
  final Future<void> Function(String ssid) forgetWifi;
  final Future<void> Function(String band) setBand;
  final Future<void> Function() toggleHotspot;
  final VoidCallback toggleShuffle;
  final VoidCallback toggleRepeat;
  final Future<void> Function() restartServices;
  final VoidCallback touch; // any touch: resets the engine's inactivity timer
  final Future<void> Function() loadPlaylists;
  final Future<void> Function(String playlistId, {bool shuffle}) playPlaylist;
  final Future<void> Function(String mixType) playSmartMix;
  final Future<void> Function(String q) searchCity;
  final Future<void> Function(String name, {double? lat, double? lon}) selectCity;
  final Future<void> Function({String? trackId, String? artist}) playSimilar;
  final Future<void> Function(String repeat) setRepeat;
}
