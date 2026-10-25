import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'ui_v2/model.dart';
import 'ui_v2/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const RoundPlayerApp());
}

/// The Linux/GTK embedder delivers the panel's touches as a *mouse* pointer. Flutter's default
/// ScrollBehavior refuses to drag-scroll lists with a mouse, which is why nothing scrolled on the Pi.
class HudScrollBehavior extends MaterialScrollBehavior {
  const HudScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BouncingScrollPhysics();
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;
}

class RoundPlayerApp extends StatelessWidget {
  const RoundPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Round Media Player',
      scrollBehavior: const HudScrollBehavior(),
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const CircularHudScreen(),
    );
  }
}

enum PlinthMode {
  bootSequence,
  centerpiece,
  activePlayer,
  audiophileDeck,
  settingsMenu,
}

enum RepeatMode {
  off,
  all,
  one,
}

/// Universal tactile button providing instant sub-millisecond visual touch-down

class CircularHudScreen extends StatefulWidget {
  const CircularHudScreen({super.key});

  @override
  State<CircularHudScreen> createState() => _CircularHudScreenState();
}

class _CircularHudScreenState extends State<CircularHudScreen>
    with TickerProviderStateMixin {
  late final Player _player;
  late final VideoController _videoController;

  // Active Plinth Mode & Previous Mode for Modal Navigation
  PlinthMode _currentMode = PlinthMode.bootSequence;

  // Cinematic Boot Sequence
  late final AnimationController _bootController;

  // Luxury Idle Chronometer & Inactivity Management
  Timer? _inactivityTimer;
  Timer? _clockTimer;
  int _idleTimeoutSeconds = 120;

  // Immersive Media Controls & Touch Gesture State
  bool _areControlsVisible = true;
  Timer? _controlsVisibilityTimer;
  Timer? _seekRippleTimer;

  // Settings Modal State

  // Animation controllers for kick beats and organic liquid wave motion
  late final AnimationController _beatPulseController;
  late final AnimationController _waveController;
  late final AnimationController _secondPulseController;

  // Subscriptions for media player state
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;

  // Media Player State Notifiers
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier = ValueNotifier<Duration>(const Duration(seconds: 225));
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);

  // WebSocket telemetry
  WebSocketChannel? _telemetryChannel;
  Timer? _reconnectTimer;

  // Real-time telemetry values (Driven via ValueNotifier for 0-allocation 60 FPS repaints)
  final ValueNotifier<int> _bpmNotifier = ValueNotifier<int>(126);

  // Search & Track states
  bool _isSearchOpen = false;
  bool _isQueueOpen = false;
  bool _isRadialCarouselOpen = false;
  Socket? _telemetrySocket;
  StreamSubscription? _socketSub;
  bool _isShiftUpper = true;
  bool _isArabicKeyboard = false;
  String _searchQuery = '';
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _cachedTracks = [];
  bool _isLoadingTracks = false;
  bool _isSwitchingTrack = false;
  Timer? _searchDebounceTimer;

  // Hi-Fi Lossless & Audiophile Deck State
  bool _isHiFi = false;
  bool _audioOnly = false;   // YouTube Music / audio-only stream: art layout, no video surface
  int? _videoHeight;
  String _audioFormat = 'FLAC';
  int _bitDepth = 24;
  int _sampleRateHz = 44100;
  String _currentAlbumName = '';
  int _hifiCatalogVersion = 0;
  String _hifiSyncStatus = 'idle';
  String _hifiSyncMessage = '';
  int _hifiSyncAdded = 0;
  int _hifiSyncTotal = 0;
  bool _isHiFiBrowserOpen = false;
  Map<String, dynamic>? _hifiTree;
  List<Map<String, dynamic>> _currentHiFiPlaylist = [];
  List<Map<String, dynamic>> _hifiTrackList = [];
  int _currentHiFiTrackIndex = 0;
  List<Map<String, dynamic>> _hifiFlatTrackIndex = [];
  List<Map<String, dynamic>> _hifiSearchResults = [];
  List<Map<String, dynamic>> _hifiPlaylists = [];
  bool _autoplaySimilar = true;
  bool _clock24h = false;
  double? _sleepInS;
  int _volumeCeiling = 100;
  Map<String, dynamic> _alarm = const {};
  final ValueNotifier<Map<String, dynamic>> _displayFx = ValueNotifier<Map<String, dynamic>>(const {});
  String? _upNextTitle;
  String? _upNextArtist;
  List<String> _castSenders = const [];
  late final AnimationController _vinylRotationController;
  bool _isShuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.all;

  // Audiophile DAC Pro (PCM5242) & PipeWire Settings State
  Map<String, dynamic> _audioSettings = {
    'filter': 'ringless',
    'analog-gain': '0',
    'pw-resample-quality': 14,
    'pw-keep-awake': 'on',
    'ramp': '1/0.5dB',
    'volume': 0.0,
    'channels': 'stereo',
  };
  Map<String, dynamic> _liveDacReadback = {
    'volume L/R': '+0.0 dB / +0.0 dB',
    'filter': 'ringless',
    'state': 'playing',
    'PLL': 'locked',
  };
  String? _audioSettingsFeedback;

  Future<void> _loadAudioSettings() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/audio/settings')).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (mounted) {
          setState(() {
            if (data['settings'] != null) {
              _audioSettings = Map<String, dynamic>.from(data['settings']);
            }
            if (data['live'] != null) {
              _liveDacReadback = Map<String, dynamic>.from(data['live']);
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _updateAudioSetting(String key, dynamic value) async {
    setState(() {
      _audioSettings[key] = value;
      _audioSettingsFeedback = 'Applying $key: $value...';
    });
    try {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/audio/settings'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({key: value.toString()}),
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        if (mounted) {
          setState(() => _audioSettingsFeedback = '✓ $key: $value saved (survives reboot)');
        }
        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) setState(() => _audioSettingsFeedback = null);
      }
      _loadAudioSettings();
    } catch (_) {
      if (mounted) setState(() => _audioSettingsFeedback = null);
    }
  }



  // City Search Overlay & On-Screen Touch Keyboard State
  // Wi-Fi settings (NetworkManager via the daemon's /api/network/*)
  Map<String, dynamic> _netStatus = {};
  List<Map<String, dynamic>> _netScan = [];
  bool _netScanning = false;
  bool _netConnecting = false;
  String _netMessage = '';
  Map<String, dynamic>? _wifiTarget; // network being joined (password overlay open when non-null)
  String _wifiPassword = '';
  bool _wifiShowPassword = false;
  bool _wifiShift = false;
  bool _wifiSymbols = false;

  List<Map<String, dynamic>> _citySearchResults = [];
  bool _isLoadingCities = false;
  Timer? _citySearchDebounceTimer;
  String? _lastTelemetryTrackId;

  // Real-time Network Weather & Circadian State
  String _weatherCity = 'Sheffield';
  double _weatherTemp = 12.0;
  int _weatherCode = 0;
  int _weatherIsDay = 1;
  String _weatherCondition = 'Clear';
  Color _weatherThemeColor = const Color(0xFF38BDF8);
  Timer? _weatherPollTimer;

  IconData _getWeatherIcon(int code, int isDay) {
    if (code <= 1) {
      return isDay == 1 ? Icons.wb_sunny_rounded : Icons.nightlight_round;
    } else if (code <= 3) {
      return isDay == 1 ? Icons.cloud_rounded : Icons.nights_stay_rounded;
    } else if (code == 45 || code == 48) {
      return Icons.foggy;
    } else if (code >= 51 && code <= 67) {
      return Icons.grain_rounded;
    } else if (code >= 71 && code <= 77) {
      return Icons.ac_unit_rounded;
    } else if (code >= 80 && code <= 82) {
      return Icons.water_drop_rounded;
    } else if (code >= 95) {
      return Icons.thunderstorm_rounded;
    }
    return Icons.cloud_rounded;
  }

  Future<void> _fetchWeather() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/weather')).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final city = data['city'] as String? ?? 'Sheffield';
        final temp = (data['temperature'] as num?)?.toDouble() ?? 12.0;
        final code = (data['weather_code'] as num?)?.toInt() ?? 0;
        final isDay = (data['is_day'] as num?)?.toInt() ?? 1;
        final cond = data['condition'] as String? ?? 'Clear';
        final colorHex = data['circadian_color'] as String? ?? '#38BDF8';
        final color = Color(int.parse(colorHex.replaceFirst('#', '0xFF')));

        if (mounted) {
          setState(() {
            _weatherCity = city;
            _weatherTemp = temp;
            _weatherCode = code;
            _weatherIsDay = isDay;
            _weatherCondition = cond;
            _weatherThemeColor = color;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _selectCity(String cityName, {double? lat, double? lon}) async {
    final query = cityName.startsWith('Auto') ? 'auto' : cityName;
    try {
      final payload = <String, dynamic>{'city': query};
      if (lat != null && lon != null) {
        payload['lat'] = lat;
        payload['lon'] = lon;
      }
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/weather/city'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final w = data['weather'] as Map<String, dynamic>?;
        if (w != null && mounted) {
          final colorHex = w['circadian_color'] as String? ?? '#38BDF8';
          final color = Color(int.parse(colorHex.replaceFirst('#', '0xFF')));
          setState(() {
            _weatherCity = w['city'] ?? cityName;
            _weatherTemp = (w['temperature'] as num?)?.toDouble() ?? _weatherTemp;
            _weatherCondition = w['condition'] ?? _weatherCondition;
            _weatherCode = (w['weather_code'] as num?)?.toInt() ?? _weatherCode;
            _weatherIsDay = (w['is_day'] as num?)?.toInt() ?? 1;
            _weatherThemeColor = color;
          });
        }
      }
    } catch (e) {
      debugPrint('Error selecting weather city: $e');
    }
  }


  Future<void> _performCitySearch(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.length < 2) {
      if (mounted) {
        setState(() {
          _citySearchResults = [];
          _isLoadingCities = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _isLoadingCities = true);
    try {
      final res = await http
          .get(Uri.parse('http://127.0.0.1:8000/api/weather/search?q=${Uri.encodeComponent(cleanQuery)}'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List list = data['results'] as List? ?? [];
        if (mounted) {
          setState(() {
            _citySearchResults = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            _isLoadingCities = false;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('City search error: $e');
    }
    if (mounted) setState(() => _isLoadingCities = false);
  }




  // Volume state
  final ValueNotifier<double> _volumeNotifier = ValueNotifier<double>(100.0);
  double _lastVolumeBeforeMute = 100.0;
  Timer? _volumeSyncDebounce;

  // Dynamic prominent glow color (Smooth Organic Blending)
  final ValueNotifier<Color> _dominantColorNotifier = ValueNotifier<Color>(const Color(0xFF00E5FF));
  late final AnimationController _colorBlendController;
  Color _fromColor = const Color(0xFF00E5FF);
  Color _targetColor = const Color(0xFF00E5FF);

  void _smoothTransitionDominantColor(Color newColor) {
    if (newColor == _targetColor) return;
    _fromColor = _dominantColorNotifier.value;
    _targetColor = newColor;
    _colorBlendController.reset();
    _colorBlendController.forward();
  }

  // True aubio beats.npy tracking
  List<double> _beatTimestamps = [];
  double _currentTrackBpm = 103.0;
  DateTime _lastPositionUpdateTime = DateTime.now();
  double _lastKnownPositionSec = 0.0;

  // Current track state (Default to official motion music video for Daft Punk - Burnin')
  String _currentTrackTitle = "Daft Punk - Burnin' (Official Music Video)";
  String _currentArtist = 'Daft Punk';
  String _activeVideoId = 'DBHipNYuAZk';
  int _currentPlaylistIndex = 0;

  // Background 1080p preparation queue state (plays current song while downloading next)
  String? _preparingVideoId;
  String? _preparingTrackTitle;
  String? _preparingTrackArtist;
  double _preparingProgress = 0.0;
  int _preparingPercent = 0;
  String _preparingStatus = '';
  Timer? _preparingPollTimer;
  // Telemetry (60 Hz) must not wipe a pill the HUD just raised locally before the daemon has echoed it,
  // nor a failure message that is meant to stay on screen for a few seconds.
  DateTime _preparingHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _hudStateReportTimer;
  int _appliedCmdSeq = 0;          // last daemon command applied (telemetry "cmd.seq")
  String? _loadedMediaId;          // what mpv currently has open ('hifi_<id>' or a YouTube id)
  String _lastHudStateJson = '';
  DateTime _lastHudStateSent = DateTime.fromMillisecondsSinceEpoch(0);

  // Pre-cast state memory to cleanly revert upon Stop Cast

  @override
  void initState() {
    super.initState();

    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _player.setVolume(100.0);
    try {
      final p = _player.platform as dynamic;
      p.setProperty('ao', 'pipewire');
      p.setProperty('audio-samplerate', '0');
      p.setProperty('audio-format', 'no');
      p.setProperty('af', '');
      p.setProperty('gapless-audio', 'yes');
      p.setProperty('prefetch-playlist', 'yes');   // open the next playlist entry before the current one ends
      p.setProperty('volume-max', '100');
      p.setProperty('replaygain', 'no'); // bit-perfect: no gain processing in mpv (DAC does volume)
      // Raspberry Pi 4: H.264 1080p via the V4L2 stateful decoder (bcm2835-codec).
      // '-copy' keeps frames in system memory so media_kit's GL texture path works.
      p.setProperty('hwdec', 'v4l2m2m-copy');
      p.setProperty('vd-lavc-threads', '4');
      // NB: the per-frame GL fence leak in libmpv's render backend is handled in the vendored
      // media_kit_video plugin (packages/media_kit_video/linux/video_output.cc), not here.
    } catch (e) {
      debugPrint('Failed to set audiophile mpv properties: $e');
    }
    _loadAudioSettings();
    // H/W texture path (mpv renders into a shared EGL texture). Needs the vendored media_kit_video in
    // packages/ (see tools/vendor_media_kit_video.sh) - stock media_kit + libmpv leaks a DRM fence fd per
    // video frame on Mesa/v3d. HUD_VIDEO_HW=0 falls back to the S/W pixel-buffer path (slow on the Pi).
    final hwVideo = Platform.environment['HUD_VIDEO_HW'] != '0';
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(enableHardwareAcceleration: hwVideo),
    );
    _startFrameTimingLog();

    _bootController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700), // was a 3.2 s fake "calibration" sequence
    )..addListener(() {
      setState(() {});
    });

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
        });
      }
    });

    _currentMode = PlinthMode.centerpiece;   // v2 boots straight into the shell
    _bootController.forward().whenComplete(() {
      if (mounted) {
        setState(() {
          _currentMode = PlinthMode.centerpiece;
        });
        _resetInactivityTimer();
      }
    });

    _colorBlendController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400), // Organic 2.4s liquid color bleed
    )..addListener(() {
      final curved = Curves.easeInOutCubic.transform(_colorBlendController.value);
      _dominantColorNotifier.value = Color.lerp(_fromColor, _targetColor, curved) ?? _targetColor;
    });

    _beatPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 582), // 103 BPM default
    )..repeat();

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000), // 8s smooth continuous liquid flow
    )..repeat();

    _secondPulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1), // 1s second pulse
    )..repeat();

    _vinylRotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800), // 33.3 RPM rotation feel
    );

    _setupPlayerListeners();
    _startHudStateReporter();
    _connectTelemetry();
    _loadCachedTracks();
    _loadHiFiTree();
    _fetchSettings();
    _fetchWeather();
    _weatherPollTimer = Timer.periodic(const Duration(minutes: 10), (_) => _fetchWeather());

    // Start playing official music video in standby on boot
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialPlayback();
    });
  }

  // Logs average build/raster times and effective FPS every 5 s to stderr (journal) when HUD_PERF=1.
  void _startFrameTimingLog() {
    if (Platform.environment['HUD_PERF'] != '1') return;
    int frames = 0;
    double buildMs = 0, rasterMs = 0, worstMs = 0;
    DateTime last = DateTime.now();
    WidgetsBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        frames++;
        buildMs += t.buildDuration.inMicroseconds / 1000.0;
        rasterMs += t.rasterDuration.inMicroseconds / 1000.0;
        final total = t.totalSpan.inMicroseconds / 1000.0;
        if (total > worstMs) worstMs = total;
      }
      final now = DateTime.now();
      final dt = now.difference(last).inMilliseconds;
      if (dt >= 5000 && frames > 0) {
        debugPrint('[perf] ${(frames * 1000 / dt).toStringAsFixed(1)} fps  build ${(buildMs / frames).toStringAsFixed(1)} ms  '
            'raster ${(rasterMs / frames).toStringAsFixed(1)} ms  worst ${worstMs.toStringAsFixed(0)} ms  mode=$_currentMode');
        frames = 0; buildMs = 0; rasterMs = 0; worstMs = 0; last = now;
      }
    });
  }

  // The daemon used to estimate playback position from a wall clock. The HUD owns mpv, so it reports the
  // truth at 2 Hz (only when something changed) and the daemon/web remote read that instead.
  void _startHudStateReporter() {
    _hudStateReportTimer?.cancel();
    _hudStateReportTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final payload = jsonEncode({
        'track_id': _activeVideoId,
        'position_s': (_positionNotifier.value.inMilliseconds / 1000.0),
        'duration_s': (_durationNotifier.value.inMilliseconds / 1000.0),
        'is_playing': _isPlayingNotifier.value,
      });
      // Paused: still report at least every 2 s, otherwise the daemon's 3 s freshness window lapses and
      // hud_synced drops to false for a paused track (seen on sleep -> wake).
      final now = DateTime.now();
      if (payload == _lastHudStateJson && !_isPlayingNotifier.value && now.difference(_lastHudStateSent).inMilliseconds < 2000) return;
      _lastHudStateJson = payload;
      _lastHudStateSent = now;
      http
          .post(Uri.parse('http://127.0.0.1:8000/api/hud/state'),
              headers: {'Content-Type': 'application/json'}, body: payload)
          .timeout(const Duration(milliseconds: 1500))
          .catchError((_) => http.Response('', 599));   // (status 0 is rejected by package:http -> unhandled exception)
    });
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_idleTimeoutSeconds <= 0) return; // Never sleep
    _inactivityTimer = Timer(Duration(seconds: _idleTimeoutSeconds), () {
      if (mounted && (_currentMode == PlinthMode.activePlayer || _currentMode == PlinthMode.audiophileDeck) && !_isPlayingNotifier.value) {
        setState(() {
          _currentMode = PlinthMode.centerpiece;
        });
      }
    });
  }

  Future<void> _fetchSettings() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/settings')).timeout(const Duration(seconds: 2));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (mounted) {
          setState(() {
            _idleTimeoutSeconds = (data['idle_timeout_seconds'] as num?)?.toInt() ?? 120;
            _autoplaySimilar = data['autoplay_similar'] != false;
            _clock24h = data['clock_24h'] == true;
            _volumeCeiling = (data['volume_ceiling'] as num?)?.toInt() ?? 100;
            _alarm = data['alarm'] is Map ? Map<String, dynamic>.from(data['alarm'] as Map) : const {};
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSettings(Map<String, dynamic> patch) async {
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/settings'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(patch),
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _setupPlayerListeners() {
    _positionSub = _player.stream.position.listen((pos) {
      _positionNotifier.value = pos;
      _lastKnownPositionSec = pos.inMicroseconds / 1000000.0;
      _lastPositionUpdateTime = DateTime.now();
    });
    _durationSub = _player.stream.duration.listen((dur) {
      if (dur > Duration.zero) {
        _durationNotifier.value = dur;
      }
    });
    _playingSub = _player.stream.playing.listen((playing) {
      _isPlayingNotifier.value = playing;
      if (playing) {
        _lastPositionUpdateTime = DateTime.now();
        if (_isHiFi) {
          _vinylRotationController.repeat();
        }
        if (_currentMode == PlinthMode.centerpiece) {
          if (_activeVideoId == 'standby') {
            _player.pause();
            _isPlayingNotifier.value = false;
            return;
          }
          setState(() {
            _currentMode = _isHiFi ? PlinthMode.audiophileDeck : PlinthMode.activePlayer;
          });
        }
        _resetControlsVisibilityTimer();
      } else {
        if (_isHiFi) {
          _vinylRotationController.stop();
        }
        _controlsVisibilityTimer?.cancel();
        if (mounted && !_areControlsVisible) {
          setState(() => _areControlsVisible = true);
        }
        _resetInactivityTimer();
      }
    });
    _completedSub = _player.stream.completed.listen((completed) {
      if (completed && _loadedMediaId != null) {
        final ended = _loadedMediaId;
        if (_gaplessNext != null) {
          // mpv has the next entry pre-opened and will advance by itself; if that somehow does not happen, fall back
          _advanceFallback?.cancel();
          _advanceFallback = Timer(const Duration(milliseconds: 2500), () {
            if (_loadedMediaId == ended && _gaplessNext != null) {
              debugPrint('[gapless] no advance after completed - reporting ended');
              _gaplessNext = null;
              _reportEnded(ended!);
            }
          });
          return;
        }
        _reportEnded(ended!);
      }
    });
    _playlistSub = _player.stream.playlist.listen(_onPlaylistChanged);
  }

  void _reportEnded(String ended) {
    // The daemon decides what follows (repeat-one, queue, album, autoplay) and answers with a numbered command.
    http.post(Uri.parse('http://127.0.0.1:8000/api/hud/ended'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'track_id': ended}))
        .timeout(const Duration(seconds: 3))
        .catchError((_) => http.Response('', 599));
  }

  Future<void> _fetchBeatsAndColor(String videoId) async {
    if (videoId.startsWith('hifi_')) {
      final cleanId = videoId.replaceFirst('hifi_', '');
      try {
        final res = await http.get(Uri.parse('http://127.0.0.1:8000/media/hifi/$cleanId/beats')).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final rawBeats = data['beats'] as List? ?? [];
          _beatTimestamps = rawBeats.map((e) => (e as num).toDouble()).toList();
          final bpmVal = (data['bpm'] as num?)?.toDouble() ?? 120.0;
          _currentTrackBpm = bpmVal;
          _bpmNotifier.value = bpmVal.round();
        }
      } catch (_) {}
      return;
    }

    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/media/$videoId/beats')).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final rawBeats = data['beats'] as List? ?? [];
        _beatTimestamps = rawBeats.map((e) => (e as num).toDouble()).toList();
        final bpmVal = (data['bpm'] as num?)?.toDouble() ?? 103.0;
        _currentTrackBpm = bpmVal;
        _bpmNotifier.value = bpmVal.round();
      }
    } catch (_) {}

    try {
      final colorRes = await http.get(Uri.parse('http://127.0.0.1:8000/media/$videoId/dominant_color')).timeout(const Duration(seconds: 2));
      if (colorRes.statusCode == 200) {
        final data = jsonDecode(colorRes.body);
        final hex = data['color'] as String?;
        if (hex != null && hex.startsWith('#') && hex.length == 7) {
          final colorVal = Color(int.parse(hex.replaceFirst('#', '0xFF')));
          _smoothTransitionDominantColor(colorVal);
        }
      }
    } catch (_) {}
  }

  Future<void> _startInitialPlayback() async {
    // Ask the daemon to re-issue its current track as a numbered 'load' (at the live position, in the current
    // play state) so a restarted HUD shows and plays exactly what the daemon thinks is on. Falls back to the
    // stock video, paused, if the daemon is not up yet (it will send a command when it is).
    for (int attempt = 0; attempt < 10; attempt++) {
      try {
        final res = await http.post(Uri.parse('http://127.0.0.1:8000/api/hud/resync')).timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) return;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    try {
      _fetchBeatsAndColor(_activeVideoId);
      final initialUrl = 'http://127.0.0.1:8000/media/$_activeVideoId/video.mp4';
      _loadedMediaId = _activeVideoId;
      await _player.open(Media(initialUrl), play: false);
      await _player.setVolume(_volumeNotifier.value);
      await _player.pause();
      _isPlayingNotifier.value = false;
    } catch (e) {
      debugPrint('Initial playback standby error: $e');
    }
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    _controlsVisibilityTimer?.cancel();
    _seekRippleTimer?.cancel();
    _volumeSyncDebounce?.cancel();
    _weatherPollTimer?.cancel();
    _clockTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _citySearchDebounceTimer?.cancel();
    _reconnectTimer?.cancel();
    _socketSub?.cancel();
    _telemetrySocket?.destroy();
    _telemetryChannel?.sink.close();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _playlistSub?.cancel();
    _advanceFallback?.cancel();
    _preparingPollTimer?.cancel();
    _hudStateReportTimer?.cancel();

    _bootController.dispose();
    _beatPulseController.dispose();
    _waveController.dispose();
    _secondPulseController.dispose();
    _vinylRotationController.dispose();
    _colorBlendController.dispose();
    _player.dispose();

    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _isPlayingNotifier.dispose();
    _volumeNotifier.dispose();
    _dominantColorNotifier.dispose();

    _bpmNotifier.dispose();
    super.dispose();
  }

  void _handleTelemetryJson(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      _bpmNotifier.value = (data['bpm'] as num?)?.toInt() ?? 103;
      if (data['color'] != null) {
        final hex = data['color'].toString();
        if (hex.startsWith('#') && hex.length == 7) {
          _smoothTransitionDominantColor(Color(int.parse(hex.replaceFirst('#', '0xFF'))));
        }
      }

      if (data['is_hifi'] != null) {
        _isHiFi = data['is_hifi'] as bool? ?? false;
        final ao = data['audio_only'] == true;
        final vh = (data['video_height'] as num?)?.toInt();
        if (ao != _audioOnly || vh != _videoHeight) {
          _audioOnly = ao;
          _videoHeight = vh;
          if (mounted) setState(() {});
        }
      }
      // The daemon owns the volume (it persists it and applies it to the DAC at boot). Follow it unless the user
      // is mid-drag (a sync post is pending) - that also picks up changes made from the phone remote.
      final disp = data['display'];
      if (disp is Map) {
        final m = Map<String, dynamic>.from(disp);
        final cur = _displayFx.value;
        if (cur['brightness'] != m['brightness'] || cur['contrast'] != m['contrast'] || cur['warmth'] != m['warmth'] || cur['night_active'] != m['night_active']) {
          _displayFx.value = m;
        }
      }
      final dv = (data['volume'] as num?)?.toDouble();
      if (dv != null && _volumeSyncDebounce == null && (dv - _volumeNotifier.value).abs() > 0.5) {
        _volumeNotifier.value = dv.clamp(0.0, 100.0);
      }
      if (data['audio_format'] != null) {
        _audioFormat = data['audio_format'].toString();
      }
      if (data['bit_depth'] != null) {
        _bitDepth = (data['bit_depth'] as num?)?.toInt() ?? 16;
      }
      if (data['sample_rate_hz'] != null) {
        _sampleRateHz = (data['sample_rate_hz'] as num?)?.toInt() ?? 44100;
      }
      if (data['title'] != null && data['title'].toString().isNotEmpty) {
        _currentTrackTitle = data['title'].toString();
      }
      if (data['artist'] != null && data['artist'].toString().isNotEmpty) {
        _currentArtist = data['artist'].toString();
      }
      if (data['album'] != null && data['album'].toString().isNotEmpty) {
        _currentAlbumName = data['album'].toString();
      }

      // Live catalog version sync: when GDrive or library changes, auto-refresh catalog
      if (data['hifi_catalog_version'] != null) {
        final v = (data['hifi_catalog_version'] as num?)?.toInt() ?? 0;
        if (_hifiCatalogVersion != 0 && v > _hifiCatalogVersion) {
          _hifiCatalogVersion = v;
          _loadHiFiTree();
        } else {
          _hifiCatalogVersion = v;
        }
      }

      if (data['hifi_sync_status'] != null) {
        final newStatus = data['hifi_sync_status'].toString();
        final newMsg = data['hifi_sync_message']?.toString() ?? '';
        final newAdded = (data['hifi_sync_added'] as num?)?.toInt() ?? 0;
        final newTotal = (data['hifi_sync_total'] as num?)?.toInt() ?? 0;
        if (_hifiSyncStatus != newStatus || _hifiSyncMessage != newMsg) {
          if (_hifiSyncStatus == 'syncing' && newStatus == 'complete') {
            _loadHiFiTree();
          }
          _hifiSyncStatus = newStatus;
          _hifiSyncMessage = newMsg;
          _hifiSyncAdded = newAdded;
          _hifiSyncTotal = newTotal;
        }
      }

      if (data['shuffle'] != null && data['shuffle'] is bool) {
        _isShuffleEnabled = data['shuffle'] as bool;
      }
      if (data['repeat'] != null) {
        final rStr = data['repeat'].toString();
        if (rStr == 'one') {
          _repeatMode = RepeatMode.one;
        } else if (rStr == 'all') {
          _repeatMode = RepeatMode.all;
        } else if (rStr == 'off') {
          _repeatMode = RepeatMode.off;
        }
      }

      // Synchronize track playback from Master Playback Manager
      final trackId = data['track_id'] as String?;

      // Auto-wake & track live preparation if track is being cached
      final cachingVideoId = data['caching_video_id'] as String?;
      if (cachingVideoId != null && cachingVideoId.isNotEmpty) {
        if (_preparingVideoId == null && _activeVideoId != 'standby' && _activeVideoId != cachingVideoId) {
        }
        if (_currentMode == PlinthMode.centerpiece) {
          if (mounted) {
            setState(() {
              _currentMode = _isHiFi ? PlinthMode.audiophileDeck : PlinthMode.activePlayer;
            });
            _resetInactivityTimer();
          }
        }
        final cTitle = data['caching_title'] as String? ?? 'Incoming Cast';
        final cArtist = data['caching_artist'] as String? ?? '';
        final cPercent = (data['caching_percent'] as num?)?.toInt() ?? 0;
        final cStepRaw = data['caching_progress'];
        final cStep = (cStepRaw is String && cStepRaw.isNotEmpty) ? cStepRaw : 'Preparing 1080p...';

        if (_preparingVideoId != cachingVideoId || _preparingPercent != cPercent || _preparingStatus != cStep) {
          if (mounted) {
            setState(() {
              _preparingVideoId = cachingVideoId;
              _preparingTrackTitle = cTitle;
              _preparingTrackArtist = cArtist;
              _preparingProgress = (cPercent / 100.0).clamp(0.0, 1.0);
              _preparingPercent = cPercent;
              _preparingStatus = cStep;
            });
          }
        }
      } else if (_preparingVideoId != null && (cachingVideoId == null || cachingVideoId.isEmpty) &&
          DateTime.now().isAfter(_preparingHoldUntil)) {
        if (mounted) {
          setState(() {
            _preparingVideoId = null;
          });
        }
      }

      _lastTelemetryTrackId = trackId;

      // Playback is driven by numbered commands from the daemon (single source of truth). Each seq is
      // applied exactly once; nothing here diffs is_playing/track_id against local state any more.
      // Up-next + cast senders (v2 Now Playing)
      final un = data['up_next'];
      final unTitle = un is Map && un['same'] != true ? un['title']?.toString() : null;
      final unArtist = un is Map && un['same'] != true ? un['artist']?.toString() : null;
      final cs = (data['cast_senders'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
      if (unTitle != _upNextTitle || unArtist != _upNextArtist || cs.join('|') != _castSenders.join('|')) {
        if (mounted) setState(() { _upNextTitle = unTitle; _upNextArtist = unArtist; _castSenders = cs; });
      }
      _syncGapless(un is Map ? un : null);
      final sl = (data['sleep_in_s'] as num?)?.toDouble();
      if ((sl == null) != (_sleepInS == null) || (sl != null && _sleepInS != null && (sl / 60).ceil() != (_sleepInS! / 60).ceil())) {
        if (mounted) setState(() => _sleepInS = sl); else _sleepInS = sl;
      } else {
        _sleepInS = sl;
      }

      final cmd = data['cmd'];
      if (cmd is Map) {
        final seq = (cmd['seq'] as num?)?.toInt() ?? 0;
        if (seq < _appliedCmdSeq) {
          // Daemon restarted (its sequence counter reset): re-arm so its next command is applied.
          _appliedCmdSeq = 0;
        }
        if (seq > _appliedCmdSeq) {
          _appliedCmdSeq = seq;
          _applyDaemonCommand(Map<String, dynamic>.from(cmd));
        }
      }
    } catch (_) {}
  }

  Future<void> _applyDaemonCommand(Map<String, dynamic> cmd) async {
    final type = cmd['type']?.toString() ?? '';
    final trackId = cmd['track_id']?.toString();
    final position = (cmd['position_s'] as num?)?.toDouble();
    final playing = cmd['playing'] as bool?;
    debugPrint('[cmd] #${cmd['seq']} $type ${trackId ?? ''} pos=$position playing=$playing');
    try {
      switch (type) {
        case 'load':
          if (trackId == null || trackId.isEmpty || trackId == 'standby') {
            await _applyStop();
          } else if (_loadedMediaId != trackId) {
            await _loadMedia(trackId, position: position ?? 0.0, play: playing ?? true, url: cmd['url']?.toString());
          } else {
            // Same media already open (HUD-initiated play echoed back, or wake after sleep kept the file loaded):
            // reconcile state. The track must become active again or the HUD keeps reporting "standby".
            if (_activeVideoId != trackId && mounted) setState(() => _activeVideoId = trackId);
            if (position != null && (position - _positionNotifier.value.inMilliseconds / 1000.0).abs() > 2.0) {
              await _player.seek(Duration(milliseconds: (position * 1000).round()));
            }
            if (playing == true) {
              await _enterPlayerModeFor(trackId);
              await _player.play();
            } else if (playing == false) {
              await _player.pause();
            }
          }
          break;
        case 'play':
          if (_loadedMediaId == null || _activeVideoId == 'standby') return;
          await _enterPlayerModeFor(_loadedMediaId!);
          if (_isHiFi) _vinylRotationController.repeat();
          await _player.play();
          _resetControlsVisibilityTimer();
          break;
        case 'pause':
          if (_isHiFi) _vinylRotationController.stop();
          await _player.pause();
          _controlsVisibilityTimer?.cancel();
          if (mounted && !_areControlsVisible) setState(() => _areControlsVisible = true);
          break;
        case 'seek':
          if (position != null) await _player.seek(Duration(milliseconds: (position * 1000).round()));
          break;
        case 'stop':
          await _applyStop();
          break;
      }
    } catch (e) {
      debugPrint('[cmd] apply error: $e');
    }
  }

  Future<void> _enterPlayerModeFor(String trackId) async {
    final hifi = trackId.startsWith('hifi_');
    if (_currentMode == PlinthMode.centerpiece || _isHiFi != hifi ||
        (_currentMode != PlinthMode.audiophileDeck && _currentMode != PlinthMode.activePlayer && _currentMode != PlinthMode.settingsMenu)) {
      if (mounted) {
        setState(() {
          _isHiFi = hifi;
          if (_currentMode != PlinthMode.settingsMenu) {
            _currentMode = hifi ? PlinthMode.audiophileDeck : PlinthMode.activePlayer;
          }
        });
      }
      _resetInactivityTimer();
    }
  }

  Future<void> _applyStop() async {
    _isPlayingNotifier.value = false;
    if (_isHiFi) _vinylRotationController.stop();
    _activeVideoId = 'standby';
    _lastTelemetryTrackId = 'standby';
    _preparingVideoId = null;
    _preparingPollTimer?.cancel();
    unawaited(_player.pause().catchError((_) {}));
    if (mounted && _currentMode != PlinthMode.centerpiece && _currentMode != PlinthMode.settingsMenu) {
      setState(() {
        _currentMode = PlinthMode.centerpiece;
        _isSearchOpen = false;
        _isQueueOpen = false;
        _isHiFiBrowserOpen = false;
        _isRadialCarouselOpen = false;
      });
      _resetInactivityTimer();
    }
  }

  /// Opens media in mpv for a daemon 'load' command. The only place (besides the optimistic local
  /// selection paths, which set _loadedMediaId themselves) that calls _player.open().
  ({String trackId, double position, bool play, String? url})? _pendingLoad;

  // ---- Gapless: the daemon advertises up_next (ready = file on disk); we append it to mpv's playlist so mpv
  // pre-opens it and crosses the boundary itself. When mpv advances we tell the daemon (/api/hud/advanced) and it
  // adopts the track without issuing a load. Anything else (user pick, queue change) resets it via _player.open().
  String? _gaplessNext;
  StreamSubscription<Playlist>? _playlistSub;
  Timer? _advanceFallback;

  String _mediaUrlFor(String trackId) => trackId.startsWith('hifi_')
      ? 'http://127.0.0.1:8000/media/hifi/${trackId.replaceFirst('hifi_', '')}/stream'
      : 'http://127.0.0.1:8000/media/$trackId/video.mp4';

  Future<void> _syncGapless(Map? upNext) async {
    final loaded = _loadedMediaId;
    final want = (upNext is Map && upNext['ready'] == true && loaded != null && loaded.startsWith('hifi_')) ? upNext['track_id']?.toString() : null;
    final valid = want != null && want.startsWith('hifi_') && want != loaded && !_isSwitchingTrack;
    if ((valid ? want : null) == _gaplessNext) return;
    try {
      // Drop a previously pre-opened entry that is no longer the plan
      if (_gaplessNext != null) {
        final pl = _player.state.playlist;
        final oldUrl = _mediaUrlFor(_gaplessNext!);
        final idx = pl.medias.indexWhere((m) => m.uri == oldUrl);
        if (idx > pl.index) await _player.remove(idx);
        _gaplessNext = null;
      }
      if (valid) {
        await _player.add(Media(_mediaUrlFor(want)));
        _gaplessNext = want;
        debugPrint('[gapless] pre-opened $want after $loaded');
      }
    } catch (e) {
      debugPrint('[gapless] sync error: $e');
      _gaplessNext = null;
    }
  }

  void _onPlaylistChanged(Playlist pl) {
    final next = _gaplessNext;
    if (next == null || pl.index < 0 || pl.index >= pl.medias.length) return;
    if (pl.medias[pl.index].uri != _mediaUrlFor(next)) return;
    // mpv crossed the boundary on its own
    final previous = _loadedMediaId;
    _advanceFallback?.cancel();
    _gaplessNext = null;
    _loadedMediaId = next;
    _activeVideoId = next;
    if (mounted) setState(() {});
    _fetchBeatsAndColor(next);
    debugPrint('[gapless] advanced $previous -> $next');
    http.post(Uri.parse('http://127.0.0.1:8000/api/hud/advanced'), headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'track_id': next, 'previous': previous}))
        .timeout(const Duration(seconds: 4))
        .catchError((_) => http.Response('', 599));
    // Keep the playlist tidy: the finished entry is no longer needed
    if (pl.index > 0) { _player.remove(0).catchError((_) {}); }
  }

  Future<void> _loadMedia(String trackId, {double position = 0.0, bool play = true, String? url}) async {
    if (_isSwitchingTrack) {
      // A load is in flight (a FLAC over HTTP can take >300 ms to open). Never drop this one: remember the newest
      // request and apply it as soon as the current open finishes. Intermediate requests are superseded.
      _pendingLoad = (trackId: trackId, position: position, play: play, url: url);
      return;
    }
    _isSwitchingTrack = true;
    _gaplessNext = null;   // open() replaces mpv's playlist
    _advanceFallback?.cancel();
    try {
      _activeVideoId = trackId;
      _loadedMediaId = trackId;
      if (mounted && _preparingVideoId == trackId) setState(() => _preparingVideoId = null);
      _fetchBeatsAndColor(trackId);
      await _enterPlayerModeFor(trackId);
      final hifi = trackId.startsWith('hifi_');
      // A YouTube track that is not cached arrives with a resolved stream URL (an edl:// merging the 1080p H.264
      // and AAC streams, or a plain audio URL for YouTube Music): mpv streams it with range requests.
      final mediaUrl = url ?? (hifi
          ? 'http://127.0.0.1:8000/media/hifi/${trackId.replaceFirst('hifi_', '')}/stream'
          : 'http://127.0.0.1:8000/media/$trackId/video.mp4');
      // When mpv starts a stream at a position it can seek during open (no download-then-seek dance)
      if (url != null && position > 0.5) {
        try { (_player.platform as dynamic).setProperty('start', position.toStringAsFixed(2)); } catch (_) {}
      } else {
        try { (_player.platform as dynamic).setProperty('start', 'none'); } catch (_) {}
      }
      await _player.open(Media(mediaUrl), play: play);
      await _player.setVolume(100.0);
      if (position > 0.5 && url == null) {
        // mpv needs the file open before it can seek; retry briefly if the duration isn't known yet
        for (int i = 0; i < 10; i++) {
          if (_durationNotifier.value.inMilliseconds > 0) break;
          await Future.delayed(const Duration(milliseconds: 150));
        }
        await _player.seek(Duration(milliseconds: (position * 1000).round()));
      }
      if (hifi && play) _vinylRotationController.repeat();
      _resetControlsVisibilityTimer();
    } catch (e) {
      debugPrint('[cmd] load error for $trackId: $e');
      _loadedMediaId = null;
    } finally {
      _isSwitchingTrack = false;
    }
    final next = _pendingLoad;
    if (next != null) {
      _pendingLoad = null;
      if (next.trackId != _loadedMediaId) {
        await _loadMedia(next.trackId, position: next.position, play: next.play, url: next.url);
      }
    }
  }

  void _connectTelemetry() {
    _reconnectTimer?.cancel();
    if (Platform.isLinux) {
      _connectUnixSocket();
    } else {
      _connectWebSocket();
    }
  }

  void _connectUnixSocket() async {
    try {
      final sock = await Socket.connect(
        InternetAddress('/tmp/roundplayer_telemetry.sock', type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 2),
      );
      _telemetrySocket = sock;
      _socketSub = sock.listen(
        (data) {
          final text = utf8.decode(data);
          for (final line in text.split('\n')) {
            if (line.trim().isNotEmpty) {
              _handleTelemetryJson(line);
            }
          }
        },
        onError: (_) {
          _socketSub?.cancel();
          _telemetrySocket?.destroy();
          _scheduleReconnect();
        },
        onDone: () {
          _socketSub?.cancel();
          _telemetrySocket?.destroy();
          _scheduleReconnect();
        },
      );
    } catch (_) {
      // Daemon not up yet (or restarting): keep retrying the unix socket - it is the only path on the Pi.
      // (Falling back to the WebSocket here used to raise an unhandled "connection refused" and stall reconnection.)
      _scheduleReconnect();
    }
  }

  void _connectWebSocket() async {
    try {
      final ch = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:8000/ws/telemetry'),
      );
      await ch.ready;
      _telemetryChannel = ch;
      _telemetryChannel!.stream.listen(
        (message) {
          if (message is String && message.trim().isNotEmpty) {
            _handleTelemetryJson(message);
          }
        },
        onError: (_) => _scheduleReconnect(),
        onDone: () => _scheduleReconnect(),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _connectTelemetry();
    });
  }

  Future<void> _loadCachedTracks() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/tracks')).timeout(const Duration(seconds: 2));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        setState(() {
          _cachedTracks = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _performSearch(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      if (mounted) setState(() => _isLoadingTracks = false);
      return;
    }
    if (mounted) setState(() => _isLoadingTracks = true);
    try {
      final res = await http
          .get(Uri.parse('http://127.0.0.1:8000/search?q=${Uri.encodeComponent(cleanQuery)}'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        if (mounted) {
          setState(() {
            _searchResults = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            _isLoadingTracks = false;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('Search error: $e');
    }
    if (mounted) {
      setState(() => _isLoadingTracks = false);
    }
  }

  Future<void> _performHiFiSearch(String query) async {
    final cleanQuery = query.trim().toLowerCase();
    if (cleanQuery.isEmpty) {
      if (mounted) {
        setState(() {
          _hifiSearchResults = [];
          _isLoadingTracks = false;
        });
      }
      return;
    }

    // Fast in-memory instant search if flat track index is loaded
    if (_hifiFlatTrackIndex.isNotEmpty) {
      final matches = _hifiFlatTrackIndex.where((t) {
        final title = (t['title'] as String? ?? '').toLowerCase();
        final artist = (t['artist'] as String? ?? '').toLowerCase();
        final album = (t['album'] as String? ?? '').toLowerCase();
        return title.contains(cleanQuery) || artist.contains(cleanQuery) || album.contains(cleanQuery);
      }).toList();

      matches.sort((a, b) {
        final aTitle = (a['title'] as String? ?? '').toLowerCase();
        final bTitle = (b['title'] as String? ?? '').toLowerCase();
        final aStarts = aTitle.startsWith(cleanQuery) ? 0 : 1;
        final bStarts = bTitle.startsWith(cleanQuery) ? 0 : 1;
        if (aStarts != bStarts) return aStarts.compareTo(bStarts);
        return aTitle.compareTo(bTitle);
      });

      if (mounted) {
        setState(() {
          _hifiSearchResults = matches;
          _isLoadingTracks = false;
        });
      }
      return;
    }

    // Fallback: Query backend Hi-Fi search endpoint
    if (mounted) setState(() => _isLoadingTracks = true);
    try {
      final res = await http
          .get(Uri.parse('http://127.0.0.1:8000/api/hifi/search?q=${Uri.encodeComponent(cleanQuery)}'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        if (mounted) {
          setState(() {
            _hifiSearchResults = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            _isLoadingTracks = false;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('Hi-Fi search error: $e');
    }
    if (mounted) setState(() => _isLoadingTracks = false);
  }



  Future<void> _playTrack(Map<String, dynamic> track) async {
    final videoId = track['video_id'];
    if (videoId == null) return;

    final isAlreadyCached = track['is_cached'] == true;

    // Immediately close search and queue drawers so the user returns to the HUD
    setState(() {
      _isSearchOpen = false;
      _isQueueOpen = false;
    });

    if (isAlreadyCached) {
      _preparingPollTimer?.cancel();
      setState(() {
        _preparingVideoId = null;
        _currentTrackTitle = track['title'] ?? 'Selected Track';
        _currentArtist = track['artist'] ?? 'Artist';
        _activeVideoId = videoId;
      });
      await _switchAndPlay(videoId);
      return;
    }

    // New track not yet cached: queue in background without disrupting current playing track!
    setState(() {
      _preparingVideoId = videoId;
      _preparingTrackTitle = track['title'] ?? 'Queued Track';
      _preparingTrackArtist = track['artist'] ?? '';
      _preparingProgress = 0.05;
      _preparingPercent = 5;
      _preparingStatus = 'Starting 1080p download...';
    });

    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/play/$videoId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'title': track['title'] ?? '', 'artist': track['artist'] ?? ''}),
      ).timeout(const Duration(seconds: 3));
      _startPreparingPolling(videoId);
    } catch (e) {
      debugPrint('Playback trigger error: $e');
    }
  }

  void _startPreparingPolling(String videoId) {
    _preparingPollTimer?.cancel();
    _preparingPollTimer = Timer.periodic(const Duration(milliseconds: 750), (timer) async {
      if (!mounted || _preparingVideoId != videoId) {
        timer.cancel();
        return;
      }
      try {
        final res = await http.get(Uri.parse('http://127.0.0.1:8000/cache/status/$videoId'));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final status = data['status'] as String? ?? 'downloading';
          final progress = (data['progress'] as num?)?.toDouble() ?? 0.05;
          final percent = (data['percent'] as num?)?.toInt() ?? (progress * 100).round();

          if (status == 'ready') {
            timer.cancel();
            if (mounted) {
              setState(() {
                _preparingProgress = 1.0;
                _preparingPercent = 100;
                _preparingStatus = '1080p Ready! Launching...';
              });
            }
            // Seamless transition to the new track
            await Future.delayed(const Duration(milliseconds: 600));
            if (!mounted || _preparingVideoId != videoId) return;

            setState(() {
              _currentTrackTitle = _preparingTrackTitle ?? 'Selected Track';
              _currentArtist = _preparingTrackArtist ?? '';
              _preparingVideoId = null;
            });
            // The daemon issues a 'load' command when the file is ready; nothing to open here.
            _loadCachedTracks();
          } else if (status == 'error') {
            timer.cancel();
            if (mounted) {
              setState(() {
                _preparingStatus = 'Download failed: ${data['error'] ?? 'Unknown error'}';
              });
              Future.delayed(const Duration(seconds: 4), () {
                if (mounted && _preparingVideoId == videoId) {
                  setState(() => _preparingVideoId = null);
                }
              });
            }
          } else {
            String label = 'Downloading 1080p...';
            if (status == 'processing_1080p') {
              label = 'Optimizing 1080p Video...';
            } else if (status == 'analyzing_beats') {
              label = 'Aubio Beat Extraction...';
            } else if (status == 'color_and_metadata') {
              label = 'Extracting Dominant Palette...';
            }

            if (mounted) {
              setState(() {
                _preparingProgress = progress.clamp(0.0, 1.0);
                _preparingPercent = percent.clamp(0, 100);
                _preparingStatus = label;
              });
            }
          }
        }
      } catch (_) {}
    });
  }

  /// Local selection of a cached YouTube track: optimistic UI, then ask the daemon. The daemon answers
  /// with a numbered 'load' command (applied in _applyDaemonCommand) which does the actual mpv open.
  Future<void> _switchAndPlay(String videoId) async {
    _activeVideoId = videoId;
    _fetchBeatsAndColor(videoId);
    if (mounted) {
      setState(() {
        _isHiFi = false;
        _currentMode = PlinthMode.activePlayer;
      });
      _resetInactivityTimer();
    }
    try {
      final playRes = await http.post(Uri.parse('http://127.0.0.1:8000/api/play/$videoId')).timeout(const Duration(seconds: 3));
      if (playRes.statusCode == 200) {
        final data = jsonDecode(playRes.body);
        final detectedBpm = (data['bpm'] as num?)?.toDouble();
        if (detectedBpm != null && detectedBpm > 40 && detectedBpm < 240) {
          _bpmNotifier.value = detectedBpm.round();
          _currentTrackBpm = detectedBpm;
        }
        final hex = data['dominant_color'] as String?;
        if (hex != null && hex.startsWith('#') && hex.length == 7) {
          _smoothTransitionDominantColor(Color(int.parse(hex.replaceFirst('#', '0xFF'))));
        }
      }
    } catch (e) {
      debugPrint('Error asking daemon to play $videoId: $e');
    }
  }

  Future<void> _goToIdleStandby() async {
    _preparingPollTimer?.cancel();
    _inactivityTimer?.cancel();
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/control'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'action': 'idle'}),
      ).timeout(const Duration(milliseconds: 1500));
    } catch (_) {}
  }

  /// Wake from sleep: the daemon reloads the last track, paused, at the position it stopped.
  Future<void> _resumeFromIdle() async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/resume')).timeout(const Duration(milliseconds: 2500));
    } catch (_) {}
  }


  Future<void> _togglePlayPause() async {
    // The HUD only asks; the daemon answers with a numbered play/pause command (~1 frame later) which is the one
    // thing that touches mpv. One source of truth, no flapping.
    final wantPlay = !_isPlayingNotifier.value;
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/control'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'action': wantPlay ? 'play' : 'pause'}),
      ).timeout(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('Error asking daemon to ${wantPlay ? 'play' : 'pause'}: $e');
    }
  }

  Future<void> _playNextTrack() async {
    // The daemon picks the track and answers with a numbered 'load' command; the HUD only asks.
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/queue/next'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('Error requesting next track: $e');
    }
  }

  Future<void> _playPreviousTrack() async {
    // The daemon picks the track and answers with a numbered 'load' command; the HUD only asks.
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/queue/prev'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('Error requesting prev track: $e');
    }
  }

  void _toggleShuffle() {
    setState(() {
      _isShuffleEnabled = !_isShuffleEnabled;
    });
    try {
      http.post(
        Uri.parse('http://127.0.0.1:8000/api/playback/modes'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'shuffle': _isShuffleEnabled}),
      ).timeout(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('Error syncing shuffle: $e');
    }
  }

  void _toggleRepeat() {
    setState(() {
      switch (_repeatMode) {
        case RepeatMode.off:
          _repeatMode = RepeatMode.all;
          break;
        case RepeatMode.all:
          _repeatMode = RepeatMode.one;
          break;
        case RepeatMode.one:
          _repeatMode = RepeatMode.off;
          break;
      }
    });
    try {
      final repStr = _repeatMode == RepeatMode.one ? 'one' : (_repeatMode == RepeatMode.all ? 'all' : 'off');
      http.post(
        Uri.parse('http://127.0.0.1:8000/api/playback/modes'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repeat': repStr}),
      ).timeout(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('Error syncing repeat: $e');
    }
  }

  void _resetControlsVisibilityTimer() {
    _controlsVisibilityTimer?.cancel();
    if (!_areControlsVisible) {
      if (mounted) setState(() => _areControlsVisible = true);
    }
    final isPlayerMode = (_currentMode == PlinthMode.activePlayer || _currentMode == PlinthMode.audiophileDeck);
    if (_isPlayingNotifier.value &&
        !_isSearchOpen &&
        !_isQueueOpen &&
        !_isRadialCarouselOpen &&
        !_isHiFiBrowserOpen &&
        isPlayerMode) {
      _controlsVisibilityTimer = Timer(const Duration(seconds: 12), () {
        if (mounted &&
            _isPlayingNotifier.value &&
            !_isSearchOpen &&
            !_isQueueOpen &&
            !_isRadialCarouselOpen &&
            !_isHiFiBrowserOpen &&
            (_currentMode == PlinthMode.activePlayer || _currentMode == PlinthMode.audiophileDeck)) {
          setState(() => _areControlsVisible = false);
        }
      });
    }
  }

  void _toggleControlsVisibility() {
    if (_areControlsVisible) {
      _controlsVisibilityTimer?.cancel();
      if (mounted) setState(() => _areControlsVisible = false);
    } else {
      _resetControlsVisibilityTimer();
    }
  }

  int _lastBackdropTapTime = 0;
  Offset _lastBackdropTapPos = Offset.zero;


  void _handleVideoDoubleTap(TapDownDetails details, double size) {
    final tapX = details.localPosition.dx;
    final isLeft = tapX < size / 2;
    final seekSec = isLeft ? -10 : 10;
    _seekRelative(seekSec);

    _seekRippleTimer?.cancel();
    if (mounted) {
    }
    _seekRippleTimer = Timer(const Duration(milliseconds: 900), () {
    });

    _resetControlsVisibilityTimer();
  }

  Future<void> _askSeek(double seconds) async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/control'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'action': 'seek', 'seek_seconds': seconds})).timeout(const Duration(milliseconds: 1500));
    } catch (_) {}
  }

  void _seekRelative(int seconds) {
    final current = _positionNotifier.value;
    final target = current + Duration(seconds: seconds);
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(0, _durationNotifier.value.inMilliseconds),
    );
    _player.seek(clamped);
  }


  void _setVolume(double volume) {
    final clamped = volume.clamp(0.0, 100.0);
    _volumeNotifier.value = clamped;
    // Always keep player software volume at 100% (0 dB) to avoid digital truncation clipping.
    _player.setVolume(100.0);
    _resetControlsVisibilityTimer();
    _volumeSyncDebounce?.cancel();
    _volumeSyncDebounce = Timer(const Duration(milliseconds: 100), () async {
      try {
        await http.post(
          Uri.parse('http://127.0.0.1:8000/api/audio/volume'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'volume_pct': clamped}),
        ).timeout(const Duration(seconds: 4));
      } catch (_) {}
      _volumeSyncDebounce = null;
    });
  }



  // ---------------------------------------------------------------------------------------------------------
  // v2 interface: the engine (player, telemetry, commands) stays here; lib/ui_v2 only decides what is on screen.
  HudView _v2View() => HudView(
        activeId: _activeVideoId,
        title: _currentTrackTitle,
        artist: _currentArtist,
        album: _currentAlbumName,
        isHiFi: _isHiFi,
        audioOnly: _audioOnly,
        videoHeight: _videoHeight,
        audioFormat: _audioFormat,
        bitDepth: _bitDepth,
        sampleRateHz: _sampleRateHz,
        videoController: _videoController,
        position: _positionNotifier,
        duration: _durationNotifier,
        isPlaying: _isPlayingNotifier,
        volume: _volumeNotifier,
        accent: _dominantColorNotifier,
        vinylRotation: _vinylRotationController,
        preparingId: _preparingVideoId,
        preparingTitle: _preparingTrackTitle,
        preparingArtist: _preparingTrackArtist,
        preparingStatus: _preparingStatus,
        preparingPercent: _preparingPercent,
        hifiTree: _hifiTree,
        cachedTracks: _cachedTracks,
        searchResults: _searchResults,
        hifiSearchResults: _hifiSearchResults,
        isSearching: _isLoadingTracks,
        weatherCity: _weatherCity,
        weatherTemp: _weatherTemp,
        weatherIcon: _getWeatherIcon(_weatherCode, _weatherIsDay),
        weatherCondition: _weatherCondition,
        idleTimeoutSeconds: _idleTimeoutSeconds,
        audioSettings: _audioSettings,
        dacReadback: _liveDacReadback,
        audioFeedback: _audioSettingsFeedback,
        netStatus: _netStatus,
        netScan: _netScan,
        netScanning: _netScanning,
        netConnecting: _netConnecting,
        netMessage: _netMessage,
        shuffle: _isShuffleEnabled,
        repeat: _repeatMode.name,
        upNextTitle: _upNextTitle,
        upNextArtist: _upNextArtist,
        castSenders: _castSenders,
        playlists: _hifiPlaylists,
        cityResults: _citySearchResults,
        cityLoading: _isLoadingCities,
        autoplaySimilar: _autoplaySimilar,
        clock24h: _clock24h,
        displayFx: _displayFx,
        sleepInS: _sleepInS,
        volumeCeiling: _volumeCeiling,
        alarm: _alarm,
        hifiSyncStatus: _hifiSyncStatus,
        hifiSyncMessage: _hifiSyncMessage,
        hifiSyncAdded: _hifiSyncAdded,
        hifiSyncTotal: _hifiSyncTotal,
      );

  HudActions? _v2ActionsCache;
  HudActions _v2Actions() => _v2ActionsCache ??= HudActions(
        togglePlay: _togglePlayPause,
        next: _playNextTrack,
        prev: _playPreviousTrack,
        seekTo: (d) => _askSeek(d.inMilliseconds / 1000.0),
        seekBy: (secs) {
          final target = (_positionNotifier.value.inMilliseconds / 1000.0 + secs).clamp(0.0, _durationNotifier.value.inMilliseconds / 1000.0);
          _askSeek(target);
        },
        setVolume: _setVolume,
        standby: _goToIdleStandby,
        wake: _resumeFromIdle,
        playHiFi: (id, {playlist, index}) => _playHiFiTrack(id, playlist: playlist, index: index),
        playYouTube: _switchAndPlay,
        playSearchResult: _playTrack,
        addToQueue: (t) async {
          try {
            await http.post(Uri.parse('http://127.0.0.1:8000/api/queue/add'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'video_id': t['video_id'], 'title': t['title'] ?? '', 'artist': t['artist'] ?? '',
                                  'source': t['source'] ?? 'youtube', 'position': t['position'] ?? 'end'})).timeout(const Duration(seconds: 3));
          } catch (_) {}
        },
        cancelPreparing: _cancelPreparing,
        loadHiFiTree: ({force = false}) => _loadHiFiTree(force: force),
        syncHiFiLibrary: _syncHiFiLibrary,
        loadCachedTracks: _loadCachedTracks,
        searchYouTube: _performSearch,
        searchHiFi: _performHiFiSearch,
        saveSettings: (patch) async {
          if (patch['idle_timeout_seconds'] != null && mounted) {
            setState(() => _idleTimeoutSeconds = (patch['idle_timeout_seconds'] as num).toInt());
          }
          if (patch['autoplay_similar'] != null && mounted) {
            setState(() => _autoplaySimilar = patch['autoplay_similar'] == true);
          }
          if (patch['clock_24h'] != null && mounted) {
            setState(() => _clock24h = patch['clock_24h'] == true);
          }
          if (patch['volume_ceiling'] != null && mounted) {
            setState(() => _volumeCeiling = (patch['volume_ceiling'] as num).toInt());
          }
          if (patch['alarm'] is Map && mounted) {
            setState(() => _alarm = Map<String, dynamic>.from(patch['alarm'] as Map));
          }
          await _saveSettings(patch);
        },
        updateAudioSetting: _updateAudioSetting,
        loadAudioSettings: _loadAudioSettings,
        loadNetworkStatus: _loadNetworkStatus,
        scanNetworks: _scanNetworks,
        connectWifi: _connectWifi,
        forgetWifi: _forgetWifi,
        setBand: _setBandPreference,
        toggleHotspot: _toggleHotspot,
        toggleShuffle: _toggleShuffle,
        toggleRepeat: _toggleRepeat,
        restartServices: () async {
          try {
            await http.post(Uri.parse('http://127.0.0.1:8000/api/system/restart-services')).timeout(const Duration(seconds: 5));
          } catch (_) {}
        },
        touch: _resetInactivityTimer,
        loadPlaylists: _loadHiFiPlaylists,
        playPlaylist: (id, {shuffle = false}) => _playPlaylist(id, shuffle: shuffle),
        playSmartMix: (type) => _playSmartMix(type),
        searchCity: _performCitySearch,
        selectCity: (name, {lat, lon}) => _selectCity(name, lat: lat, lon: lon),
        playSimilar: ({trackId, artist}) async {
          try {
            await http.post(Uri.parse('http://127.0.0.1:8000/api/hifi/similar/play'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({if (trackId != null) 'track_id': trackId, if (artist != null) 'artist': artist, 'limit': 50})).timeout(const Duration(seconds: 20));
          } catch (e) {
            debugPrint('similar play: $e');
          }
        },
        setRepeat: (r) async {
          if (mounted) setState(() => _repeatMode = r == 'one' ? RepeatMode.one : (r == 'all' ? RepeatMode.all : RepeatMode.off));
          try {
            await http.post(Uri.parse('http://127.0.0.1:8000/api/playback/modes'),
                headers: {'Content-Type': 'application/json'}, body: jsonEncode({'repeat': r})).timeout(const Duration(seconds: 3));
          } catch (_) {}
        },
      );


  // ---------------------------------------------------------------- Wi-Fi ---
  Future<void> _loadNetworkStatus() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/network/status')).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200 && mounted) {
        setState(() => _netStatus = Map<String, dynamic>.from(jsonDecode(res.body) as Map));
      }
    } catch (_) {}
  }

  Future<void> _scanNetworks() async {
    if (_netScanning) return;
    setState(() { _netScanning = true; _netMessage = ''; });
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/network/scan')).timeout(const Duration(seconds: 40));
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map;
        final List list = data['networks'] as List? ?? [];
        setState(() => _netScan = list.map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (e) {
      if (mounted) setState(() => _netMessage = 'Scan failed');
    }
    if (mounted) setState(() => _netScanning = false);
    _loadNetworkStatus();
  }

  Future<void> _connectWifi(String ssid, String? psk) async {
    setState(() { _netConnecting = true; _netMessage = 'Connecting to $ssid…'; });
    try {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/network/connect'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ssid': ssid, 'psk': (psk == null || psk.isEmpty) ? null : psk}),
      ).timeout(const Duration(seconds: 70));
      final data = jsonDecode(res.body) as Map;
      if (!mounted) return;
      if (data['status'] == 'ok') {
        setState(() { _netMessage = 'Connected to $ssid  ·  ${data['ip'] ?? ''}'; _wifiTarget = null; _wifiPassword = ''; });
      } else {
        setState(() => _netMessage = 'Failed: ${data['message'] ?? 'unknown error'}');
      }
    } catch (e) {
      if (mounted) setState(() => _netMessage = 'Failed: $e');
    }
    if (mounted) setState(() => _netConnecting = false);
    _loadNetworkStatus();
  }

  Future<void> _forgetWifi(String ssid) async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/network/forget'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ssid': ssid})).timeout(const Duration(seconds: 8));
    } catch (_) {}
    _scanNetworks();
  }

  Future<void> _setBandPreference(String band) async {
    setState(() => _netMessage = band == '5' ? 'Preferring 5 GHz…' : (band == '2.4' ? '2.4 GHz only…' : 'Band: auto…'));
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/network/prefs'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'band': band})).timeout(const Duration(seconds: 60));
      if (mounted) setState(() => _netMessage = '');
    } catch (e) {
      if (mounted) setState(() => _netMessage = 'Failed: $e');
    }
    _loadNetworkStatus();
  }

  Future<void> _toggleHotspot() async {
    final on = _netStatus['hotspot'] == true;
    setState(() => _netMessage = on ? 'Stopping hotspot…' : 'Starting hotspot…');
    try {
      final res = await http.post(Uri.parse('http://127.0.0.1:8000/api/network/hotspot'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'enable': !on})).timeout(const Duration(seconds: 40));
      final data = jsonDecode(res.body) as Map;
      if (mounted) {
        setState(() => _netMessage = data['status'] == 'ok'
            ? (data['enabled'] == true ? 'Hotspot "${data['ssid']}"  ·  password ${data['password']}' : 'Hotspot off')
            : 'Failed: ${data['message']}');
      }
    } catch (e) {
      if (mounted) setState(() => _netMessage = 'Failed: $e');
    }
    _loadNetworkStatus();
  }


  Future<void> _syncHiFiLibrary() async {
    setState(() {
      _hifiSyncStatus = 'syncing';
      _hifiSyncMessage = 'Connecting to Google Drive...';
      _hifiSyncAdded = 0;
    });
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/hifi/sync_drive'),
        headers: {'Content-Type': 'application/json'},
        body: '{}',
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (mounted) {
        setState(() {
          _hifiSyncStatus = 'error';
          _hifiSyncMessage = 'Connection error: $e';
        });
      }
    }
  }

  Future<void> _loadHiFiTree({bool force = false}) async {
    try {
      if (force) {
        _syncHiFiLibrary();
      }
      final url = 'http://127.0.0.1:8000/api/hifi/tree';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final artists = (data['artists'] as List? ?? []).cast<Map<String, dynamic>>();
        final List<Map<String, dynamic>> flatTracks = [];
        for (final artist in artists) {
          final artistName = artist['name']?.toString() ?? 'Unknown Artist';
          final albums = (artist['albums'] as List? ?? []).cast<Map<String, dynamic>>();
          for (final album in albums) {
            final albumName = album['name']?.toString() ?? 'Unknown Album';
            final tracks = (album['tracks'] as List? ?? []).cast<Map<String, dynamic>>();
            for (final track in tracks) {
              flatTracks.add({
                'track_id': track['track_id']?.toString() ?? '',
                'title': track['title']?.toString() ?? 'Unknown Track',
                'artist': artistName,
                'album': albumName,
                'format': track['format']?.toString() ?? 'FLAC',
                'duration_seconds': track['duration_seconds'] ?? 0,
                'cover_key': '${artistName}_$albumName',
              });
            }
          }
        }
        setState(() {
          _hifiTree = data;
          _hifiFlatTrackIndex = flatTracks;
        });
        _loadHiFiPlaylists();
      } else {
      }
    } catch (_) {
    }
  }

  Future<void> _loadHiFiPlaylists() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists')).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = (data['playlists'] as List? ?? []).cast<Map<String, dynamic>>();
        setState(() {
          _hifiPlaylists = list;
        });
        return;
      }
    } catch (_) {}
  }


  Future<void> _playPlaylist(String playlistId, {bool shuffle = false}) async {
    try {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/hifi/playlists/$playlistId/play'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'shuffle': shuffle}),
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final trackId = data['track_id']?.toString() ?? '';
        final cleanId = trackId.replaceFirst('hifi_', '');
        
        final plRes = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists/$playlistId'));
        if (plRes.statusCode == 200) {
          final plData = jsonDecode(plRes.body);
          final tracks = (plData['tracks'] as List? ?? []).cast<Map<String, dynamic>>();
          setState(() {
            _currentHiFiPlaylist = tracks;
            _currentHiFiTrackIndex = tracks.indexWhere((t) => (t['track_id']?.toString() ?? '') == cleanId);
            if (_currentHiFiTrackIndex < 0) _currentHiFiTrackIndex = 0;
            _isHiFi = true;
            _isHiFiBrowserOpen = false;
            _currentMode = PlinthMode.audiophileDeck;
          });
        }
        _fetchBeatsAndColor('hifi_$cleanId');
      }
    } catch (e) {
      debugPrint('[Play Playlist Error] $e');
    }
  }

  Future<void> _playSmartMix(String mixType, {String? artist}) async {
    try {
      String url = 'http://127.0.0.1:8000/api/hifi/smart_playlist?type=$mixType&limit=50';
      if (artist != null) {
        url += '&artist=${Uri.encodeComponent(artist)}';
      }
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final tracks = (data['tracks'] as List? ?? []).cast<Map<String, dynamic>>();
        if (tracks.isNotEmpty) {
          final first = tracks.first;
          final firstId = first['track_id']?.toString() ?? first['id']?.toString() ?? '';
          setState(() {
            _currentHiFiPlaylist = List.from(tracks);
            _currentHiFiTrackIndex = 0;
            _isHiFiBrowserOpen = false;
          });
          await _playHiFiTrack(firstId, playlist: tracks, index: 0);
        }
      }
    } catch (e) {
      debugPrint('[Smart Mix Error] $e');
    }
  }

  void _showPreparingFailure(String fullId, String message) {
    if (!mounted || _preparingVideoId != fullId) return;
    setState(() {
      _preparingHoldUntil = DateTime.now().add(const Duration(seconds: 4));
      _preparingStatus = message;
      _preparingPercent = 0;
      _preparingProgress = 0.0;
    });
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _preparingVideoId == fullId) setState(() => _preparingVideoId = null);
    });
  }

  /// Banner 'x': abort the download on the daemon too, so it does not start playing later on its own.
  Future<void> _cancelPreparing() async {
    _preparingPollTimer?.cancel();
    if (mounted) setState(() => _preparingVideoId = null);
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/prepare/cancel')).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> _playHiFiTrack(String trackId, {List<Map<String, dynamic>>? playlist, int? index}) async {
    try {
      final cleanId = trackId.replaceFirst('hifi_', '');
      if (playlist != null && playlist.length > 1) {
        _currentHiFiPlaylist = List.from(playlist);
        _currentHiFiTrackIndex = index ?? playlist.indexWhere((t) => (t['track_id']?.toString() ?? t['id']?.toString() ?? '') == cleanId);
        if (_currentHiFiTrackIndex < 0) _currentHiFiTrackIndex = 0;
      } else if (_currentHiFiPlaylist.isEmpty || _currentHiFiPlaylist.length <= 1) {
        if (_hifiTrackList.length > 1 && _hifiTrackList.any((t) => (t['track_id']?.toString() ?? t['id']?.toString() ?? '') == cleanId)) {
          _currentHiFiPlaylist = List.from(_hifiTrackList);
          _currentHiFiTrackIndex = _currentHiFiPlaylist.indexWhere((t) => (t['track_id']?.toString() ?? t['id']?.toString() ?? '') == cleanId);
          if (_currentHiFiTrackIndex < 0) _currentHiFiTrackIndex = 0;
        } else if (_hifiFlatTrackIndex.isNotEmpty) {
          _currentHiFiPlaylist = List.from(_hifiFlatTrackIndex);
          _currentHiFiTrackIndex = _currentHiFiPlaylist.indexWhere((t) => (t['track_id']?.toString() ?? t['id']?.toString() ?? '') == cleanId);
          if (_currentHiFiTrackIndex < 0) _currentHiFiTrackIndex = 0;
        }
      }

      // Optimistic instant UI update
      final pool = _currentHiFiPlaylist.isNotEmpty ? _currentHiFiPlaylist : _hifiFlatTrackIndex;
      final match = pool.firstWhere(
        (t) => (t['track_id']?.toString() ?? t['id']?.toString() ?? '') == cleanId,
        orElse: () => <String, dynamic>{},
      );
      final fullId = 'hifi_$cleanId';
      final title = match['title']?.toString() ?? 'Hi-Fi track';
      final artist = match['artist']?.toString() ?? '';

      if (mounted) {
        setState(() {
          _isHiFiBrowserOpen = false;
          _isHiFi = true;
          _currentMode = PlinthMode.audiophileDeck;
          // Show the preparing pill right away (the daemon's telemetry takes over within a frame or two)
          _preparingHoldUntil = DateTime.now().add(const Duration(milliseconds: 2500));
          _preparingVideoId = fullId;
          _preparingTrackTitle = title;
          _preparingTrackArtist = artist;
          _preparingPercent = 0;
          _preparingProgress = 0.0;
          _preparingStatus = 'Requesting...';
        });
      }
      _resetInactivityTimer();
      _resetControlsVisibilityTimer();

      // The daemon owns playback: it answers "playing" (file on disk -> a 'load' command follows in telemetry at once)
      // or "preparing" (Google Drive download in the background; telemetry caching_* drives the pill). The HUD never
      // opens the stream itself any more - that used to open a URL the daemon then blocked on for the whole download.
      try {
        final res = await http
            .post(
              Uri.parse('http://127.0.0.1:8000/api/hifi/play'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'track_id': cleanId}),
            )
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final status = data['status']?.toString() ?? '';
          if (status == 'error') {
            _showPreparingFailure(fullId, data['message']?.toString() ?? 'Track unavailable');
            return;
          }
          if (data['bit_depth'] != null) _bitDepth = (data['bit_depth'] as num).toInt();
          if (data['sample_rate_hz'] != null) _sampleRateHz = (data['sample_rate_hz'] as num).toInt();
          final hex = data['dominant_color'] as String?;
          if (hex != null && hex.startsWith('#') && hex.length == 7) {
            _smoothTransitionDominantColor(Color(int.parse(hex.replaceFirst('#', '0xFF'))));
          }
          if (mounted) {
            setState(() {
              _currentTrackTitle = data['title']?.toString() ?? title;
              _currentArtist = data['artist']?.toString() ?? artist;
              _currentAlbumName = data['album']?.toString() ?? _currentAlbumName;
              if (status == 'preparing' && _preparingVideoId == fullId && _preparingStatus == 'Requesting...') {
                _preparingStatus = 'Connecting to Google Drive...';
              }
            });
          }
        } else {
          _showPreparingFailure(fullId, 'Player error ${res.statusCode}');
        }
      } catch (e) {
        debugPrint('Error requesting Hi-Fi play: $e');
        _showPreparingFailure(fullId, 'Player not responding');
      }
    } catch (e) {
      debugPrint('Error playing Hi-Fi track: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = math.min(constraints.maxWidth, constraints.maxHeight);
          return Center(child: HudShell(view: _v2View(), actions: _v2Actions(), size: size));
        },
      ),
    );
  }
}
