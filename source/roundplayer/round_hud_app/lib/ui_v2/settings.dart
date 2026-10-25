// Settings: a short menu, one page per subject, one setting per 112 px row. A choice row shows its current value
// and opens a picker page (rows with a check) instead of a wall of chips. Same geometry as the Library screen.
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'keyboard.dart';
import 'model.dart';
import 'tokens.dart';

enum _Page { menu, audio, audioAdvanced, eq, display, wifi, wifiPassword, system, picker, location, alarm, diagnostics, update }

class _Choice {
  const _Choice(this.key, this.title, this.options, {this.audio = true});
  final String key;
  final String title;
  final List<(String, String)> options; // (value, label)
  final bool audio; // true: DAC setting via updateAudioSetting, false: player setting via saveSettings
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.view, required this.actions, required this.onClose, this.liveAudio});
  final HudView view;
  final HudActions actions;
  final VoidCallback onClose;
  final Map<String, dynamic>? liveAudio;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final List<_Page> _stack = [_Page.menu];
  _Choice? _picker;
  Map<String, dynamic>? _joining;
  // Display + EQ live here (self-contained: fetched from the daemon, posted back)
  Map<String, dynamic> _display = {};
  String? _backupMsg;
  double? _alarmVolLocal;
  Map<String, dynamic> _eq = {};
  Timer? _displayThrottle;
  bool _eqBusy = false;
  String _city = '';
  bool _cityResults = false;
  Timer? _cityDebounce;
  String _psk = '';
  bool _showPsk = false;
  final _ctl = <_Page, ScrollController>{};

  _Page get _page => _stack.last;
  ScrollController _c(_Page p) => _ctl.putIfAbsent(p, ScrollController.new);

  static const _filter = _Choice('filter', 'Digital filter', [('ringless', 'Ringless (recommended)'), ('fir', 'FIR sharp roll-off'), ('iir', 'IIR low latency'), ('high-atten', 'High attenuation'), ('fixed', 'Fixed')]);
  static const _hires = _Choice('pw-hires', 'Output mode', [('on', 'Native rate · 32-bit (bit-perfect)'), ('off', '48 kHz · 16-bit')]);
  static const _gain = _Choice('analog-gain', 'Analogue gain', [('0', '0 dB · 2 V (line)'), ('-6', '−6 dB · 1 V')]);
  static const _deemph = _Choice('deemphasis', 'De-emphasis', [('off', 'Off (normal)'), ('on', 'On (50/15 µs, old CDs)')]);
  static const _channels = _Choice('channels', 'Channels', [('stereo', 'Stereo'), ('swap', 'Swap left / right'), ('mono-left', 'Mono from left'), ('mono-right', 'Mono from right')]);
  static const _automute = _Choice('auto-mute', 'Auto-mute on silence', [('off', 'Off'), ('106ms', 'After 106 ms'), ('1.07s', 'After 1 s')]);
  static const _ramp = _Choice('ramp', 'Volume ramp', [('1/0.5dB', 'Smooth'), ('1/1dB', 'Normal'), ('instant', 'Instant')]);
  static const _after = _Choice('after_album', 'After the album', [('similar', 'Keep playing similar music'), ('repeat', 'Repeat the album'), ('one', 'Repeat this track'), ('stop', 'Stop')], audio: false);
  static const _ceiling = _Choice('volume_ceiling', 'Maximum volume', [('100', '100 % · full'), ('80', '80 %'), ('60', '60 %'), ('40', '40 % · late night')], audio: false);
  static const _sleep = _Choice('sleep_timer', 'Sleep timer', [('0', 'Off'), ('15', '15 minutes'), ('30', '30 minutes'), ('45', '45 minutes'), ('60', '1 hour'), ('90', '1½ hours')], audio: false);
  static const _alarmDays = _Choice('alarm_days', 'Alarm days', [('weekdays', 'Weekdays'), ('daily', 'Every day'), ('weekend', 'Weekends')], audio: false);
  static const _alarmSource = _Choice('alarm_source', 'Alarm plays', [('last', 'Where you left off'), ('favorites', 'Favourites, shuffled'), ('similar', 'Music like the last track')], audio: false);
  static const _idle = _Choice('idle_timeout_seconds', 'Screensaver after', [('60', '1 minute'), ('120', '2 minutes'), ('300', '5 minutes'), ('900', '15 minutes'), ('0', 'Never')], audio: false);

  @override
  void initState() {
    super.initState();
    widget.actions.loadAudioSettings();
    widget.actions.loadNetworkStatus();
    _loadDisplay();
    _loadEq();
    final dbg = Platform.environment['HUD_DEBUG_SCREEN'] ?? '';
    if (dbg == 'settings:audio') _stack.add(_Page.audio);
    if (dbg == 'settings:wifi') { _stack.add(_Page.wifi); widget.actions.scanNetworks(); }
    if (dbg == 'settings:system') _stack.add(_Page.system);
    if (dbg == 'settings:picker') { _picker = _filter; _stack.add(_Page.picker); }
    if (dbg == 'settings:password') { _joining = {'ssid': 'Example-5G'}; _stack.add(_Page.wifiPassword); }
    if (dbg == 'settings:location') { _stack.add(_Page.system); _stack.add(_Page.location); }
    if (dbg == 'settings:eq') { _stack.add(_Page.audio); _stack.add(_Page.eq); }
    if (dbg == 'settings:display') { _stack.add(_Page.display); }
  }

  @override
  void dispose() {
    _cityDebounce?.cancel();
    _updPoll?.cancel();
    for (final c in _ctl.values) c.dispose();
    super.dispose();
  }

  void _push(_Page p) { widget.actions.touch(); setState(() => _stack.add(p)); }

  void _back() {
    widget.actions.touch();
    if (_stack.length > 1) {
      setState(() { _stack.removeLast(); if (_page != _Page.wifiPassword) { _joining = null; _psk = ''; } });
    } else {
      widget.onClose();
    }
  }

  String _afterValue() {
    final v = widget.view;
    if (v.repeat == 'all') return 'repeat';
    if (v.repeat == 'one') return 'one';
    return v.autoplaySimilar ? 'similar' : 'stop';
  }

  String _current(_Choice ch) {
    if (ch.key == 'after_album') {
      for (final (val, label) in ch.options) { if (val == _afterValue()) return label; }
    }
    if (ch.key == 'sleep_timer') {
      final sl = widget.view.sleepInS;
      return sl == null ? 'Off' : 'Sleeps in ${(sl / 60).ceil()} min';
    }
    if (ch.key == 'alarm_days') {
      final d = (widget.view.alarm['days'] as List?)?.map((e) => (e as num).toInt()).toList() ?? [0, 1, 2, 3, 4];
      final key = d.length >= 7 ? 'daily' : (d.toSet().containsAll({5, 6}) && d.length == 2 ? 'weekend' : 'weekdays');
      for (final (val, label) in ch.options) { if (val == key) return label; }
    }
    if (ch.key == 'alarm_source') {
      final src = (widget.view.alarm['source'] ?? 'last').toString();
      for (final (val, label) in ch.options) { if (val == src) return label; }
    }
    final v = ch.audio ? widget.view.audioSettings[ch.key] : (ch.key == 'idle_timeout_seconds' ? widget.view.idleTimeoutSeconds : (ch.key == 'volume_ceiling' ? widget.view.volumeCeiling : null));
    final s = v?.toString() ?? '';
    for (final (val, label) in ch.options) {
      if (val == s) return label;
    }
    return s.isEmpty ? '—' : s;
  }

  Future<void> _choose(_Choice ch, String value) async {
    widget.actions.touch();
    if (ch.key == 'after_album') {
      await widget.actions.setRepeat(value == 'repeat' ? 'all' : (value == 'one' ? 'one' : 'off'));
      await widget.actions.saveSettings({'autoplay_similar': value == 'similar'});
      if (mounted) _back();
      return;
    }
    if (ch.key == 'sleep_timer') {
      try {
        await http.post(Uri.parse('http://127.0.0.1:8000/api/sleep_timer'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'minutes': int.tryParse(value) ?? 0})).timeout(const Duration(seconds: 4));
      } catch (_) {}
      if (mounted) _back();
      return;
    }
    if (ch.key == 'alarm_days') {
      final days = value == 'daily' ? [0, 1, 2, 3, 4, 5, 6] : (value == 'weekend' ? [5, 6] : [0, 1, 2, 3, 4]);
      await _saveAlarm({'days': days});
      if (mounted) _back();
      return;
    }
    if (ch.key == 'alarm_source') {
      await _saveAlarm({'source': value});
      if (mounted) _back();
      return;
    }
    if (ch.audio) {
      await widget.actions.updateAudioSetting(ch.key, value);
    } else {
      await widget.actions.saveSettings({ch.key: int.tryParse(value) ?? value});
    }
    if (mounted) _back();
  }

  (String, String) _titles() {
    switch (_page) {
      case _Page.menu: return ('SETTINGS', '');
      case _Page.audio: return ('AUDIO', 'DAC Pro');
      case _Page.audioAdvanced: return ('AUDIO', 'Advanced');
      case _Page.wifi: return ('WI-FI', widget.view.netStatus['wifi']?['ssid']?.toString() ?? 'Not connected');
      case _Page.wifiPassword: return ('JOIN NETWORK', _joining?['ssid']?.toString() ?? '');
      case _Page.system: return ('SYSTEM', 'Player');
      case _Page.picker: return ('CHOOSE', _picker?.title ?? '');
      case _Page.location: return ('CLOCK & WEATHER', widget.view.weatherCity.isEmpty ? 'Location' : widget.view.weatherCity);
      case _Page.eq: return ('AUDIO', 'Equaliser');
      case _Page.display: return ('DISPLAY', 'Screen');
      case _Page.alarm: return ('ALARM', widget.view.alarm['enabled'] == true ? (widget.view.alarm['time'] ?? '07:30').toString() : 'Off');
      case _Page.diagnostics: return ('SYSTEM', 'Diagnostics');
      case _Page.update: return ('SYSTEM', 'Software update');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (eyebrow, heading) = _titles();
    return Container(
      color: T.bg,
      child: Stack(
        children: [
          Positioned(
            left: T.headerInset, right: T.headerInset, top: T.headerTop,
            child: Column(
              children: [
                Text(eyebrow, style: T.eyebrow),
                const SizedBox(height: 4),
                Text(heading.isEmpty ? 'Settings' : heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h),
              ],
            ),
          ),
          Positioned(
            left: 96, top: T.diameterY,
            child: RoundButton(onTap: _back, child: Icon(_stack.length > 1 ? Icons.arrow_back_rounded : Icons.close_rounded, size: 52, color: T.fg)),
          ),
          if (_page == _Page.wifi)
            Positioned(
              right: 96, top: T.diameterY,
              child: RoundButton(
                onTap: () { widget.actions.touch(); if (!widget.view.netScanning) widget.actions.scanNetworks(); },
                child: widget.view.netScanning
                    ? const SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 4, color: T.fg))
                    : const Icon(Icons.radar_rounded, size: 50, color: T.fg),
              ),
            ),
          if (_page == _Page.wifiPassword)
            ..._passwordEntry()
          else if (_page == _Page.location && !_cityResults)
            ..._locationEntry()
          else
            Positioned(left: T.bodyInset, right: T.bodyInset, top: T.bodyTop, bottom: T.bodyBottom, child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_page) {
      case _Page.menu: return _menu();
      case _Page.audio: return _audio();
      case _Page.audioAdvanced: return _audioAdvanced();
      case _Page.wifi: return _wifi();
      case _Page.system: return _system();
      case _Page.picker: return _pickerPage();
      case _Page.wifiPassword: return const SizedBox.shrink();
      case _Page.location: return _locationResults();
      case _Page.eq: return _eqPage();
      case _Page.display: return _displayPage();
      case _Page.alarm: return _alarmPage();
      case _Page.diagnostics: return _diagnosticsPage();
      case _Page.update: return _updatePage();
    }
  }

  Widget _rows(_Page key, List<Widget> rows) => ListView.separated(
        controller: _c(key),
        physics: const BouncingScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => rows[i],
      );

  Widget _choiceRow(_Choice ch, {IconData icon = Icons.tune_rounded}) => BigRow(
        title: ch.title,
        subtitle: _current(ch),
        leading: _lead(icon),
        actionIcon: Icons.chevron_right_rounded,
        onTap: () { setState(() => _picker = ch); _push(_Page.picker); },
        onAction: () { setState(() => _picker = ch); _push(_Page.picker); },
      );

  Widget _lead(IconData icon, {Color color = T.fg}) => Container(color: T.cardRaised, child: Icon(icon, size: 44, color: color));

  // ---- Menu
  Widget _menu() {
    final v = widget.view;
    final wifi = v.netStatus['wifi'] as Map? ?? {};
    final connected = wifi['state'] == 'connected';
    final bp = widget.liveAudio?['bit_perfect'] == true;
    return _rows(_Page.menu, [
      BigRow(title: 'Audio', subtitle: bp ? 'Bit-perfect · ${_current(_filter)}' : 'DAC Pro · ${_current(_filter)}', leading: _lead(Icons.graphic_eq_rounded, color: T.gold), actionIcon: Icons.chevron_right_rounded, onTap: () => _push(_Page.audio), onAction: () => _push(_Page.audio)),
      BigRow(title: 'Wi-Fi', subtitle: connected ? '${wifi['ssid']} · ${wifi['band'] ?? ''} · ${v.netStatus['ip'] ?? ''}' : (v.netStatus['hotspot'] == true ? 'Hotspot RoundPlayer-Setup' : 'Not connected'), leading: _lead(connected ? Icons.wifi_rounded : Icons.wifi_off_rounded, color: connected ? T.good : T.bad), actionIcon: Icons.chevron_right_rounded, onTap: () => _push(_Page.wifi), onAction: () => _push(_Page.wifi)),
      BigRow(title: 'Display', subtitle: _display.isEmpty ? 'Brightness, contrast, warmth, night mode' : 'Brightness ${((_display['settings']?['brightness'] ?? 1.0) * 100).round()}% · ${_display['settings']?['night'] == true ? 'night mode on' : 'night mode off'}', leading: _lead(Icons.brightness_6_rounded), actionIcon: Icons.chevron_right_rounded, onTap: () { _loadDisplay(); _push(_Page.display); }, onAction: () { _loadDisplay(); _push(_Page.display); }),
      BigRow(title: 'System', subtitle: 'Screensaver ${_current(_idle).toLowerCase()} · remote http://${v.netStatus['ip'] ?? 'raspberrypi.local'}/', leading: _lead(Icons.settings_rounded), actionIcon: Icons.chevron_right_rounded, onTap: () => _push(_Page.system), onAction: () => _push(_Page.system)),
    ]);
  }

  // ---- Audio
  Widget _audio() {
    final live = widget.liveAudio ?? const {};
    final sink = (live['pipewire'] as Map?)?['sink'] as Map?;
    final src = live['source'] as Map?;
    final bp = live['bit_perfect'] == true && sink != null;
    String kHz(num? hz) => hz == null || hz == 0 ? '—' : '${(hz / 1000).toStringAsFixed(1)} kHz';
    return _rows(_Page.audio, [
      Container(
        height: T.rowH,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(color: bp ? T.good.withValues(alpha: 0.10) : T.card, borderRadius: BorderRadius.circular(24), border: Border.all(color: bp ? T.good : T.line, width: 2)),
        child: Row(children: [
          Icon(bp ? Icons.verified_rounded : Icons.info_outline_rounded, size: 44, color: bp ? T.good : T.mute),
          const SizedBox(width: 22),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(bp ? 'Bit-perfect' : 'Audio path', style: T.rowTitle.copyWith(color: bp ? T.good : T.fg)),
              Text(
                sink == null
                    ? 'Nothing playing through the DAC right now'
                    : '${src?['format'] ?? 'Source'} ${src?['bit_depth'] != null ? '${src!['bit_depth']}-bit ' : ''}${kHz(src?['rate_hz'] as num?)}  →  DAC ${sink['format'] ?? ''} ${kHz(sink['rate'] as num?)}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: T.rowSub),
            ]),
          ),
        ]),
      ),
      if (widget.view.audioFeedback != null) Padding(padding: const EdgeInsets.only(left: 6), child: Text(widget.view.audioFeedback!, style: T.body.copyWith(color: T.good))),
      if (live['boot_check'] is Map)
        BigRow(
          title: (live['boot_check'] as Map)['ok'] == true ? 'DAC verified at boot' : 'DAC check failed at boot',
          subtitle: (live['boot_check'] as Map)['ok'] == true ? 'Registers read back exactly as saved' : ((live['boot_check'] as Map)['issues'] as List? ?? []).join(' · '),
          leading: _lead((live['boot_check'] as Map)['ok'] == true ? Icons.check_circle_rounded : Icons.error_outline_rounded, color: (live['boot_check'] as Map)['ok'] == true ? T.good : T.bad),
        ),
      BigRow(title: 'Equaliser', subtitle: _eq.isEmpty ? 'Bass, treble, 5 bands, presets' : (_eq['enabled'] == true ? 'On · ${(_eq['preset'] ?? 'custom').toString()}' : 'Off · bit-perfect path'), leading: _lead(Icons.equalizer_rounded, color: _eq['enabled'] == true ? T.good : T.fg), active: _eq['enabled'] == true, accent: T.good, actionIcon: Icons.chevron_right_rounded, onTap: () { _loadEq(); _push(_Page.eq); }, onAction: () { _loadEq(); _push(_Page.eq); }),
      _choiceRow(_filter, icon: Icons.filter_tilt_shift_rounded),
      _choiceRow(_hires, icon: Icons.high_quality_rounded),
      _choiceRow(_gain, icon: Icons.volume_up_rounded),
      BigRow(title: 'Advanced', subtitle: 'De-emphasis, channels, auto-mute, ramp', leading: _lead(Icons.tune_rounded), actionIcon: Icons.chevron_right_rounded, onTap: () => _push(_Page.audioAdvanced), onAction: () => _push(_Page.audioAdvanced)),
    ]);
  }

  Widget _audioAdvanced() => _rows(_Page.audioAdvanced, [
        _choiceRow(_deemph, icon: Icons.album_rounded),
        _choiceRow(_channels, icon: Icons.speaker_group_rounded),
        _choiceRow(_automute, icon: Icons.volume_off_rounded),
        _choiceRow(_ramp, icon: Icons.trending_up_rounded),
      ]);

  // ---- Picker
  Widget _pickerPage() {
    final ch = _picker;
    if (ch == null) return const SizedBox.shrink();
    final cur = ch.key == 'after_album' ? _afterValue() : (ch.audio ? widget.view.audioSettings[ch.key]?.toString() : widget.view.idleTimeoutSeconds.toString());
    return _rows(_Page.picker, [
      for (final (val, label) in ch.options)
        BigRow(title: label, active: cur == val, actionIcon: cur == val ? Icons.check_rounded : null, accent: ch.audio ? T.gold : T.cyan, onTap: () => _choose(ch, val)),
    ]);
  }

  // ---- Wi-Fi
  Widget _wifi() {
    final v = widget.view;
    final wifi = v.netStatus['wifi'] as Map? ?? {};
    final connected = wifi['state'] == 'connected';
    final hotspot = v.netStatus['hotspot'] == true;
    final prefs = v.netStatus['prefs'] as Map? ?? {};
    final band = prefs['band']?.toString() ?? '5';
    final scan = v.netScan.where((n) => n['active'] != true).toList();
    return _rows(_Page.wifi, [
      BigRow(
        title: connected ? (wifi['ssid']?.toString() ?? '') : (hotspot ? 'Hotspot RoundPlayer-Setup' : 'Not connected'),
        subtitle: v.netMessage.isNotEmpty ? v.netMessage : (connected ? '${wifi['band'] ?? ''} · signal ${wifi['signal'] ?? 0}% · ${v.netStatus['ip'] ?? ''}' : 'Tap the radar to scan'),
        leading: _lead(connected ? Icons.wifi_rounded : Icons.wifi_off_rounded, color: connected ? T.good : T.bad),
        active: connected,
        accent: T.good,
      ),
      for (final n in scan)
        BigRow(
          title: n['ssid']?.toString() ?? '',
          subtitle: '${n['band'] ?? ''} · ${n['signal'] ?? 0}%${(n['security'] ?? 'open') == 'open' ? ' · open' : ''}${n['saved'] == true ? ' · saved' : ''}',
          leading: _lead((n['signal'] ?? 0) >= 60 ? Icons.network_wifi_rounded : Icons.network_wifi_2_bar_rounded),
          actionIcon: n['saved'] == true ? Icons.delete_outline_rounded : Icons.lock_outline_rounded,
          onTap: () {
            widget.actions.touch();
            if (n['saved'] == true || (n['security'] ?? 'open') == 'open') {
              widget.actions.connectWifi(n['ssid'].toString(), null);
            } else {
              setState(() { _joining = n; _psk = ''; _showPsk = false; });
              _push(_Page.wifiPassword);
            }
          },
          onAction: () { widget.actions.touch(); if (n['saved'] == true) widget.actions.forgetWifi(n['ssid'].toString()); },
        ),
      if (scan.isEmpty && !v.netScanning)
        BigRow(title: 'Scan for networks', subtitle: 'Takes a few seconds', leading: _lead(Icons.radar_rounded), onTap: () { widget.actions.touch(); widget.actions.scanNetworks(); }),
      BigRow(
        title: 'Preferred band',
        subtitle: band == '5' ? '5 GHz when available' : (band == '2.4' ? '2.4 GHz only' : 'Automatic'),
        leading: _lead(Icons.cell_tower_rounded),
        actionIcon: Icons.swap_horiz_rounded,
        onTap: () { widget.actions.touch(); widget.actions.setBand(band == '5' ? 'auto' : (band == 'auto' ? '2.4' : '5')); },
        onAction: () { widget.actions.touch(); widget.actions.setBand(band == '5' ? 'auto' : (band == 'auto' ? '2.4' : '5')); },
      ),
      BigRow(
        title: hotspot ? 'Stop hotspot' : 'Start setup hotspot',
        subtitle: 'RoundPlayer-Setup · password roundplayer',
        leading: _lead(Icons.router_rounded, color: hotspot ? T.good : T.fg),
        active: hotspot,
        accent: T.good,
        onTap: () { widget.actions.touch(); widget.actions.toggleHotspot(); },
      ),
    ]);
  }

  List<Widget> _passwordEntry() {
    final ssid = _joining?['ssid']?.toString() ?? '';
    final v = widget.view;
    return [
      // field 236..340 (chord 2x446); keyboard 546..912 (bottom row 620 wide inside chord 2x391)
      Positioned(
        left: 230, right: 230, top: 236,
        child: BigField(
          text: _psk,
          obscure: !_showPsk,
          placeholder: 'Password',
          trailing: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showPsk = !_showPsk),
            child: Icon(_showPsk ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 40, color: T.mute),
          ),
        ),
      ),
      if (v.netConnecting || v.netMessage.isNotEmpty)
        Positioned(left: 250, right: 250, top: 356, child: Text(v.netMessage, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.body.copyWith(color: v.netMessage.startsWith('Failed') ? T.bad : T.good))),
      Positioned(
        left: 0, right: 0, bottom: 168,
        child: Center(
          child: BigKeyboard(
            submitLabel: v.netConnecting ? '…' : 'Connect',
            onKey: (c) => setState(() => _psk += c),
            onBackspace: () { if (_psk.isNotEmpty) setState(() => _psk = _psk.substring(0, _psk.length - 1)); },
            onSubmit: () async {
              widget.actions.touch();
              if (_psk.length < 8 || v.netConnecting) return;
              await widget.actions.connectWifi(ssid, _psk);
              if (!mounted) return;
              final ok = widget.view.netStatus['wifi']?['ssid'] == ssid || widget.view.netMessage.startsWith('Connected');
              if (ok) setState(() { _stack.removeLast(); _joining = null; _psk = ''; });
            },
          ),
        ),
      ),
    ];
  }

  // ---- Clock & weather location: type a city, pick from the geocoder's matches (Open-Meteo), weather follows.
  void _cityKey(String c) {
    setState(() => _city += c);
    _cityDebounce?.cancel();
    _cityDebounce = Timer(const Duration(milliseconds: 400), () => widget.actions.searchCity(_city));
  }

  List<Widget> _locationEntry() {
    final v = widget.view;
    return [
      Positioned(
        left: 230, right: 230, top: 236,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _cityResults = false),
          child: BigField(text: _city, placeholder: 'City, e.g. Glasgow', trailing: v.cityLoading ? const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3, color: T.mute)) : (v.cityResults.isNotEmpty ? Text('${v.cityResults.length}', style: T.mono) : null)),
        ),
      ),
      Positioned(
        left: 250, right: 250, top: 356,
        child: Text(v.weatherCity.isEmpty ? 'Weather and the screensaver clock use this place.' : 'Now: ${v.weatherCity} · ${v.weatherTemp.round()}° ${v.weatherCondition}', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.body.copyWith(color: T.mute)),
      ),
      Positioned(
        left: 0, right: 0, bottom: 168,
        child: Center(
          child: BigKeyboard(
            submitLabel: 'Find',
            onKey: _cityKey,
            onBackspace: () { if (_city.isNotEmpty) setState(() => _city = _city.substring(0, _city.length - 1)); _cityDebounce?.cancel(); _cityDebounce = Timer(const Duration(milliseconds: 400), () => widget.actions.searchCity(_city)); },
            onSubmit: () async {
              widget.actions.touch();
              if (_city.trim().length < 2) return;
              await widget.actions.searchCity(_city);
              if (mounted) setState(() => _cityResults = true);
            },
          ),
        ),
      ),
    ];
  }

  Widget _locationResults() {
    final v = widget.view;
    if (v.cityResults.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.search_off_rounded, size: 72, color: T.mute), const SizedBox(height: 16),
        Text('No place called "$_city"', style: T.body.copyWith(color: T.mute)), const SizedBox(height: 20),
        TabPill(label: 'Try again', icon: Icons.keyboard_rounded, on: false, onTap: () => setState(() => _cityResults = false)),
      ]));
    }
    return _rows(_Page.location, [
      for (final r in v.cityResults)
        BigRow(
          title: r['name']?.toString() ?? '',
          subtitle: [r['admin1'], r['country']].where((x) => x != null && x.toString().isNotEmpty).join(', '),
          leading: _lead(Icons.place_rounded),
          actionIcon: Icons.check_rounded,
          onTap: () async {
            widget.actions.touch();
            await widget.actions.selectCity(r['name'].toString(), lat: (r['latitude'] as num?)?.toDouble(), lon: (r['longitude'] as num?)?.toDouble());
            if (mounted) _back();
          },
          onAction: () async {
            widget.actions.touch();
            await widget.actions.selectCity(r['name'].toString(), lat: (r['latitude'] as num?)?.toDouble(), lon: (r['longitude'] as num?)?.toDouble());
            if (mounted) _back();
          },
        ),
      BigRow(title: 'Edit search', subtitle: _city, leading: _lead(Icons.keyboard_rounded), onTap: () { widget.actions.touch(); setState(() => _cityResults = false); }),
    ]);
  }

  // ---- Display (compositor gamma table via display-ctl): live while dragging, throttled to ~8/s
  Future<void> _loadDisplay() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/display')).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && mounted) setState(() => _display = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
    } catch (_) {}
  }

  void _setDisplay(Map<String, dynamic> patch, {bool now = false}) {
    final st = Map<String, dynamic>.from(_display['settings'] as Map? ?? {});
    st.addAll(patch);
    setState(() => _display = {..._display, 'settings': st});
    _displayThrottle?.cancel();
    _displayThrottle = Timer(Duration(milliseconds: now ? 0 : 120), () async {
      try {
        final r = await http.post(Uri.parse('http://127.0.0.1:8000/api/display'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(patch)).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200 && mounted) setState(() => _display = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
      } catch (_) {}
    });
  }

  Widget _displayPage() {
    final st = _display['settings'] as Map? ?? {};
    final eff = _display['effective'] as Map? ?? {};
    double d(String k, double def) => (st[k] as num?)?.toDouble() ?? def;
    final night = st['night'] == true;
    return _rows(_Page.display, [
      if (eff['night_active'] == true)
        BigRow(title: 'Night mode is active', subtitle: 'Dimmer and warmer until ${st['night_to'] ?? '07:00'}', leading: _lead(Icons.nightlight_round, color: T.gold), active: true, accent: T.gold),
      SliderRow(label: 'Brightness', value: d('brightness', 1.0), min: 0.2, max: 1.0, display: '${(d('brightness', 1.0) * 100).round()}%', onChanged: (x) => _setDisplay({'brightness': x}), onChangeEnd: (x) => _setDisplay({'brightness': x}, now: true)),
      SliderRow(label: 'Contrast', value: d('contrast', 1.0), min: 0.6, max: 1.4, center: 1.0, display: '${((d('contrast', 1.0) - 1.0) * 100).round() >= 0 ? '+' : ''}${((d('contrast', 1.0) - 1.0) * 100).round()}%', onChanged: (x) => _setDisplay({'contrast': x}), onChangeEnd: (x) => _setDisplay({'contrast': x}, now: true)),
      SliderRow(label: 'Warmth', value: d('warmth', 6500), min: 2500, max: 6500, display: '${d('warmth', 6500).round()} K', accent: T.gold, onChanged: (x) => _setDisplay({'warmth': x.round()}), onChangeEnd: (x) => _setDisplay({'warmth': x.round()}, now: true)),
      BigRow(title: 'Night mode', subtitle: night ? '${st['night_from'] ?? '22:00'} – ${st['night_to'] ?? '07:00'} · ${((d('night_brightness', 0.45)) * 100).round()}% · ${d('night_warmth', 3400).round()} K' : 'Off', leading: _lead(Icons.bedtime_rounded, color: night ? T.gold : T.fg), active: night, accent: T.gold, actionIcon: Icons.swap_horiz_rounded,
          onTap: () => _setDisplay({'night': !night}, now: true), onAction: () => _setDisplay({'night': !night}, now: true)),
      if (night) ...[
        SliderRow(label: 'Night brightness', value: d('night_brightness', 0.45), min: 0.1, max: 1.0, display: '${(d('night_brightness', 0.45) * 100).round()}%', onChanged: (x) => _setDisplay({'night_brightness': x}), onChangeEnd: (x) => _setDisplay({'night_brightness': x}, now: true)),
        SliderRow(label: 'Night warmth', value: d('night_warmth', 3400), min: 2000, max: 6500, display: '${d('night_warmth', 3400).round()} K', accent: T.gold, onChanged: (x) => _setDisplay({'night_warmth': x.round()}), onChangeEnd: (x) => _setDisplay({'night_warmth': x.round()}, now: true)),
        BigRow(title: 'Starts', subtitle: (st['night_from'] ?? '22:00').toString(), leading: _lead(Icons.schedule_rounded), actionIcon: Icons.add_rounded, onTap: () => _setDisplay({'night_from': _shiftTime((st['night_from'] ?? '22:00').toString(), -30)}, now: true), onAction: () => _setDisplay({'night_from': _shiftTime((st['night_from'] ?? '22:00').toString(), 30)}, now: true)),
        BigRow(title: 'Ends', subtitle: (st['night_to'] ?? '07:00').toString(), leading: _lead(Icons.schedule_rounded), actionIcon: Icons.add_rounded, onTap: () => _setDisplay({'night_to': _shiftTime((st['night_to'] ?? '07:00').toString(), -30)}, now: true), onAction: () => _setDisplay({'night_to': _shiftTime((st['night_to'] ?? '07:00').toString(), 30)}, now: true)),
      ],
      BigRow(title: 'Reset display', subtitle: 'Full brightness, neutral contrast, 6500 K', leading: _lead(Icons.restart_alt_rounded), onTap: () => _setDisplay({'brightness': 1.0, 'contrast': 1.0, 'warmth': 6500}, now: true)),
    ]);
  }

  String _shiftTime(String hm, int minutes) {
    final p = hm.split(':');
    var m = (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p.length > 1 ? p[1] : '0') ?? 0) + minutes;
    m = ((m % 1440) + 1440) % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  }

  // ---- Equaliser (PipeWire filter-chain): values post on release (PipeWire restarts, ~1 s gap)
  Future<void> _loadEq() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/audio/eq')).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && mounted) setState(() => _eq = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
    } catch (_) {}
  }

  Future<void> _postEq(Map<String, dynamic> body) async {
    if (_eqBusy) return;
    setState(() => _eqBusy = true);
    try {
      final r = await http.post(Uri.parse('http://127.0.0.1:8000/api/audio/eq'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 25));
      if (r.statusCode == 200 && mounted) {
        final d = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
        setState(() => _eq = {..._eq, ...d});
      }
    } catch (_) {}
    if (mounted) setState(() => _eqBusy = false);
    widget.actions.loadAudioSettings();
  }

  void _eqLocal(String key, dynamic value) => setState(() => _eq = {..._eq, key: value});

  Widget _eqPage() {
    final enabled = _eq['enabled'] == true;
    final bands = ((_eq['bands'] as List?) ?? [0, 0, 0, 0, 0]).map((e) => (e as num).toDouble()).toList();
    final hz = ((_eq['bands_hz'] as List?) ?? [60, 250, 1000, 4000, 12000]).map((e) => (e as num).toInt()).toList();
    String db(double x) => '${x >= 0 ? '+' : ''}${x.toStringAsFixed(1)} dB';
    String hzLabel(int h) => h >= 1000 ? '${(h / 1000).toStringAsFixed(h % 1000 == 0 ? 0 : 1)} kHz' : '$h Hz';
    final presets = ((_eq['presets'] as List?) ?? ['flat', 'warm', 'bright', 'bass', 'vocal', 'night']).cast<String>();
    Map<String, dynamic> current() => {'enabled': true, 'bass': _eq['bass'] ?? 0.0, 'treble': _eq['treble'] ?? 0.0, 'bands': bands, 'loudness': _eq['loudness'] == true};
    return _rows(_Page.eq, [
      BigRow(
        title: enabled ? 'Equaliser on' : 'Equaliser off',
        subtitle: _eqBusy ? 'Applying… (PipeWire restarts, ~1 s)' : (enabled ? 'Audio passes through the EQ stage before the DAC' : 'Bit-perfect: nothing between the file and the DAC'),
        leading: _lead(enabled ? Icons.equalizer_rounded : Icons.verified_rounded, color: enabled ? T.good : T.fg),
        active: enabled, accent: T.good, actionIcon: Icons.power_settings_new_rounded,
        onTap: () => _postEq({'enabled': !enabled}), onAction: () => _postEq({'enabled': !enabled}),
      ),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final p in presets)
          TabPill(label: p[0].toUpperCase() + p.substring(1), on: enabled && _eq['preset'] == p, onTap: () { widget.actions.touch(); _postEq({'preset': p}); }),
      ]),
      SliderRow(label: 'Bass', value: (_eq['bass'] as num?)?.toDouble() ?? 0, min: -12, max: 12, center: 0, display: db((_eq['bass'] as num?)?.toDouble() ?? 0), accent: T.good,
          onChanged: (x) => _eqLocal('bass', (x * 2).round() / 2), onChangeEnd: (x) => _postEq({...current(), 'bass': (x * 2).round() / 2})),
      for (int i = 0; i < bands.length; i++)
        SliderRow(label: hzLabel(hz[i]), value: bands[i], min: -12, max: 12, center: 0, display: db(bands[i]), accent: T.good,
            onChanged: (x) { final b = List<double>.from(bands); b[i] = (x * 2).round() / 2; _eqLocal('bands', b); },
            onChangeEnd: (x) { final b = List<double>.from(bands); b[i] = (x * 2).round() / 2; _postEq({...current(), 'bands': b}); }),
      SliderRow(label: 'Treble', value: (_eq['treble'] as num?)?.toDouble() ?? 0, min: -12, max: 12, center: 0, display: db((_eq['treble'] as num?)?.toDouble() ?? 0), accent: T.good,
          onChanged: (x) => _eqLocal('treble', (x * 2).round() / 2), onChangeEnd: (x) => _postEq({...current(), 'treble': (x * 2).round() / 2})),
      BigRow(title: 'Night loudness', subtitle: 'Lifts lows and highs at low volume, trims 2 dB', leading: _lead(Icons.nightlight_round, color: _eq['loudness'] == true ? T.good : T.fg), active: _eq['loudness'] == true, accent: T.good, actionIcon: Icons.swap_horiz_rounded,
          onTap: () => _postEq({...current(), 'loudness': _eq['loudness'] != true}), onAction: () => _postEq({...current(), 'loudness': _eq['loudness'] != true})),
      () {
        const levels = ['off', 'light', 'medium', 'strong'];
        final xf = (_eq['crossfeed'] ?? 'off').toString();
        final next = levels[(levels.indexOf(xf) + 1) % levels.length];
        return BigRow(title: 'Headphone crossfeed', subtitle: xf == 'off' ? 'Off · tap to cycle light / medium / strong' : '${xf[0].toUpperCase()}${xf.substring(1)} · blends a little of each side into the other', leading: _lead(Icons.headphones_rounded, color: xf != 'off' ? T.good : T.fg), active: xf != 'off', accent: T.good, actionIcon: Icons.swap_horiz_rounded,
            onTap: () => _postEq({'crossfeed': next}), onAction: () => _postEq({'crossfeed': next}));
      }(),
    ]);
  }

  // ---- Alarm (wake to music, fades in over a minute)
  Future<void> _saveAlarm(Map<String, dynamic> patch) async {
    final a = {'enabled': false, 'time': '07:30', 'days': [0, 1, 2, 3, 4], 'source': 'last', 'volume_pct': 45, 'fade_s': 60, ...widget.view.alarm, ...patch};
    await widget.actions.saveSettings({'alarm': a});
  }

  Widget _alarmPage() {
    final a = widget.view.alarm;
    final on = a['enabled'] == true;
    final t = (a['time'] ?? '07:30').toString();
    final vol = _alarmVolLocal ?? (a['volume_pct'] as num?)?.toDouble() ?? 45;
    return _rows(_Page.alarm, [
      BigRow(title: 'Alarm', subtitle: on ? 'On' : 'Off', leading: _lead(Icons.alarm_rounded, color: on ? T.gold : T.fg), active: on, accent: T.gold, actionIcon: Icons.swap_horiz_rounded,
          onTap: () => _saveAlarm({'enabled': !on}), onAction: () => _saveAlarm({'enabled': !on})),
      BigRow(title: 'Time', subtitle: '$t  ·  tap −15 min, + for +15 min', leading: _lead(Icons.schedule_rounded), actionIcon: Icons.add_rounded,
          onTap: () => _saveAlarm({'time': _shiftTime(t, -15)}), onAction: () => _saveAlarm({'time': _shiftTime(t, 15)})),
      _choiceRow(_alarmDays, icon: Icons.calendar_today_rounded),
      _choiceRow(_alarmSource, icon: Icons.music_note_rounded),
      SliderRow(label: 'Volume', value: vol, min: 5, max: 100, display: '${vol.round()}%', accent: T.gold, onChanged: (x) => setState(() => _alarmVolLocal = x), onChangeEnd: (x) { _alarmVolLocal = null; _saveAlarm({'volume_pct': x.round()}); }),
      BigRow(title: 'How it wakes you', subtitle: 'Starts at a tenth of that volume and fades up over a minute', leading: _lead(Icons.wb_twilight_rounded)),
    ]);
  }

  // ---- Software update
  Map<String, dynamic> _upd = {};
  Timer? _updPoll;
  Future<void> _loadUpdate() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/update/status')).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && mounted) setState(() => _upd = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
    } catch (_) {}
    _updPoll?.cancel();
    if ((_upd['state'] ?? '') == 'running' && mounted && _page == _Page.update) _updPoll = Timer(const Duration(seconds: 3), _loadUpdate);
  }

  Widget _updatePage() {
    final u = _upd;
    final running = (u['state'] ?? '') == 'running';
    final url = (u['url'] ?? '').toString();
    return _rows(_Page.update, [
      BigRow(title: 'Installed', subtitle: 'v${u['current_version'] ?? '?'}', leading: _lead(Icons.verified_rounded, color: T.good)),
      BigRow(title: 'Source', subtitle: url.isEmpty ? 'Not set · set the update URL from the phone remote (Settings → Software update)' : url, leading: _lead(Icons.link_rounded)),
      if (u['state'] != null && u['state'] != 'idle')
        BigRow(title: running ? 'Updating…' : (u['state'] == 'done' ? 'Done' : 'Update failed'), subtitle: [u['step'], u['error']].where((x) => x != null && x.toString().isNotEmpty).join(' · '),
            leading: _lead(running ? Icons.hourglass_top_rounded : (u['state'] == 'done' ? Icons.check_circle_rounded : Icons.error_outline_rounded), color: running ? T.gold : (u['state'] == 'done' ? T.good : T.bad))),
      if (!running && url.isNotEmpty)
        BigRow(title: 'Update now', subtitle: 'Downloads, builds alongside the live copy (~10 min), then swaps; rolls back on its own if it fails', leading: _lead(Icons.system_update_rounded, color: T.gold), accent: T.gold,
            onTap: () async { widget.actions.touch(); try { await http.post(Uri.parse('http://127.0.0.1:8000/api/update/start')).timeout(const Duration(seconds: 15)); } catch (_) {} _loadUpdate(); }),
      if (!running && u['can_rollback'] == true)
        BigRow(title: 'Roll back', subtitle: 'Return to the previous version', leading: _lead(Icons.history_rounded, color: T.bad),
            onTap: () async { widget.actions.touch(); try { await http.post(Uri.parse('http://127.0.0.1:8000/api/update/rollback')).timeout(const Duration(seconds: 15)); } catch (_) {} _loadUpdate(); }),
    ]);
  }

  // ---- Diagnostics
  Map<String, dynamic> _health = {};
  List<String> _log = [];
  Future<void> _loadHealth() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/health')).timeout(const Duration(seconds: 6));
      if (r.statusCode == 200 && mounted) setState(() => _health = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
      final l = await http.get(Uri.parse('http://127.0.0.1:8000/api/health/log?n=40')).timeout(const Duration(seconds: 6));
      if (l.statusCode == 200 && mounted) setState(() => _log = ((jsonDecode(l.body) as Map)['lines'] as List? ?? []).map((e) => e.toString()).toList());
    } catch (_) {}
  }

  Widget _diagnosticsPage() {
    final h = _health;
    if (h.isEmpty) return _rows(_Page.diagnostics, [BigRow(title: 'Reading…', leading: _lead(Icons.hourglass_top_rounded))]);
    String up(num? s) { if (s == null) return '—'; final d = Duration(seconds: s.toInt()); return d.inDays > 0 ? '${d.inDays} d ${d.inHours % 24} h' : '${d.inHours} h ${d.inMinutes % 60} min'; }
    final temp = (h['cpu_temp_c'] as num?)?.toDouble();
    final wifi = h['wifi'] as Map? ?? {};
    final rssi = (wifi['rssi_dbm'] as num?)?.toInt();
    final thr = (h['throttled'] ?? '').toString();
    final throttledBad = thr.isNotEmpty && thr != '0x0';
    final mem = h['mem_mb'] as Map? ?? {};
    return _rows(_Page.diagnostics, [
      BigRow(title: 'Temperature', subtitle: temp == null ? '—' : '${temp.toStringAsFixed(1)} °C${throttledBad ? ' · throttled ($thr)' : ''}', leading: _lead(Icons.thermostat_rounded, color: temp != null && temp > 75 ? T.bad : (temp != null && temp > 65 ? T.gold : T.good)), active: throttledBad, accent: T.bad),
      BigRow(title: 'Wi-Fi', subtitle: wifi['ssid'] == null ? 'Not connected' : '${wifi['ssid']} · ${rssi ?? '?'} dBm${(wifi['freq_mhz'] ?? 0) > 5000 ? ' · 5 GHz' : ' · 2.4 GHz'}${wifi['tx_rate'] != null ? ' · ${wifi['tx_rate']}' : ''}', leading: _lead(Icons.wifi_rounded, color: rssi == null ? T.mute : (rssi > -60 ? T.good : (rssi > -72 ? T.gold : T.bad)))),
      BigRow(title: 'Storage', subtitle: '${h['disk_free_gb']} GB free of ${h['disk_total_gb']} GB', leading: _lead(Icons.sd_storage_rounded, color: ((h['disk_free_gb'] as num?) ?? 10) < 2 ? T.bad : T.fg)),
      BigRow(title: 'Memory · load', subtitle: '${mem['available']} MB free of ${mem['total']} MB · load ${(h['load'] as List?)?.join(' / ') ?? '—'}', leading: _lead(Icons.memory_rounded)),
      BigRow(title: 'Player', subtitle: 'daemon up ${up(h['uptime_s'] as num?)} · system up ${up(h['system_uptime_s'] as num?)} · v${h['version']}', leading: _lead(Icons.timer_outlined)),
      BigRow(title: 'Panel sync', subtitle: h['hud_synced'] == true ? 'Panel and daemon agree' : (h['hud_fresh'] == true ? 'Panel reporting, state differs' : 'Panel not reporting'), leading: _lead(Icons.sync_rounded, color: h['hud_synced'] == true ? T.good : T.bad), active: h['hud_synced'] != true, accent: T.bad),
      BigRow(title: 'DAC check', subtitle: (h['audio_check'] as Map?)?['ok'] == true ? 'Verified at boot' : (((h['audio_check'] as Map?)?['issues'] as List?)?.join(' · ') ?? 'Not checked yet'), leading: _lead(Icons.speaker_rounded, color: (h['audio_check'] as Map?)?['ok'] == true ? T.good : T.gold)),
      BigRow(title: 'Library index', subtitle: '${h['library_tracks'] ?? '—'} tracks indexed', leading: _lead(Icons.library_music_rounded)),
      BigRow(title: 'Refresh', leading: _lead(Icons.refresh_rounded), onTap: () { widget.actions.touch(); _loadHealth(); }),
      for (final line in _log.reversed.take(25))
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), child: Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.mono.copyWith(fontSize: 18, color: line.contains('rror') || line.contains('Traceback') ? T.bad : T.mute))),
    ]);
  }

  // ---- System
  Widget _system() {
    final v = widget.view;
    return _rows(_Page.system, [
      BigRow(title: 'Clock & weather location', subtitle: v.weatherCity.isEmpty ? 'Not set' : '${v.weatherCity} · ${v.weatherTemp.round()}° ${v.weatherCondition}', leading: _lead(Icons.place_rounded), actionIcon: Icons.chevron_right_rounded,
          onTap: () { setState(() { _city = ''; _cityResults = false; }); _push(_Page.location); }, onAction: () { setState(() { _city = ''; _cityResults = false; }); _push(_Page.location); }),
      BigRow(title: 'Clock', subtitle: v.clock24h ? '24-hour' : '12-hour', leading: _lead(Icons.schedule_rounded), active: v.clock24h, actionIcon: Icons.swap_horiz_rounded,
          onTap: () { widget.actions.touch(); widget.actions.saveSettings({'clock_24h': !v.clock24h}); }, onAction: () { widget.actions.touch(); widget.actions.saveSettings({'clock_24h': !v.clock24h}); }),
      _choiceRow(_sleep, icon: Icons.timer_rounded),
      BigRow(title: 'Alarm', subtitle: v.alarm['enabled'] == true ? '${v.alarm['time'] ?? '07:30'} · ${_current(_alarmDays)} · ${_current(_alarmSource)}' : 'Off', leading: _lead(Icons.alarm_rounded, color: v.alarm['enabled'] == true ? T.gold : T.fg), active: v.alarm['enabled'] == true, accent: T.gold, actionIcon: Icons.chevron_right_rounded,
          onTap: () => _push(_Page.alarm), onAction: () => _push(_Page.alarm)),
      _choiceRow(_ceiling, icon: Icons.volume_up_rounded),
      _choiceRow(_idle, icon: Icons.bedtime_rounded),
      BigRow(
        title: 'After the album',
        subtitle: v.repeat == 'all' ? 'Repeat the album' : (v.repeat == 'one' ? 'Repeat this track' : (v.autoplaySimilar ? 'Keep playing similar music' : 'Stop')),
        leading: _lead(Icons.all_inclusive_rounded, color: v.autoplaySimilar && v.repeat == 'off' ? T.cyan : T.fg),
        actionIcon: Icons.chevron_right_rounded,
        onTap: () { setState(() => _picker = _after); _push(_Page.picker); },
        onAction: () { setState(() => _picker = _after); _push(_Page.picker); },
      ),
      BigRow(title: 'Shuffle', subtitle: v.shuffle ? 'On' : 'Off', leading: _lead(Icons.shuffle_rounded, color: v.shuffle ? T.cyan : T.fg), active: v.shuffle, actionIcon: Icons.swap_horiz_rounded, onTap: () { widget.actions.touch(); widget.actions.toggleShuffle(); }, onAction: () { widget.actions.touch(); widget.actions.toggleShuffle(); }),
      BigRow(title: 'Repeat', subtitle: v.repeat == 'one' ? 'This track' : (v.repeat == 'all' ? 'Album / queue' : 'Off'), leading: _lead(v.repeat == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded, color: v.repeat != 'off' ? T.cyan : T.fg), active: v.repeat != 'off', actionIcon: Icons.swap_horiz_rounded, onTap: () { widget.actions.touch(); widget.actions.toggleRepeat(); }, onAction: () { widget.actions.touch(); widget.actions.toggleRepeat(); }),
      BigRow(title: 'Sleep now', subtitle: 'Stops playback and shows the clock; tap the screen to wake', leading: _lead(Icons.bedtime_rounded), onTap: () { widget.actions.touch(); widget.onClose(); widget.actions.standby(); }),
      BigRow(title: 'Phone remote', subtitle: 'http://${v.netStatus['ip'] ?? 'raspberrypi.local'}/  ·  cast to "Living Room Player"', leading: _lead(Icons.phone_iphone_rounded)),
      BigRow(title: 'Back up settings', subtitle: _backupMsg ?? 'Audio, EQ, display, playlists, favourites → SD card boot partition (auto every 5 min)', leading: _lead(Icons.save_rounded),
          onTap: () async {
            widget.actions.touch();
            setState(() => _backupMsg = 'Backing up…');
            try {
              final r = await http.post(Uri.parse('http://127.0.0.1:8000/api/backup/save')).timeout(const Duration(seconds: 20));
              final d = jsonDecode(r.body) as Map;
              if (mounted) setState(() => _backupMsg = d['sdcard'] != null ? 'Saved to the SD card (${d['sdcard']})' : 'Saved locally · SD card: ${d['sdcard_error'] ?? 'unavailable'}');
            } catch (e) { if (mounted) setState(() => _backupMsg = 'Backup failed: $e'); }
          }),
      BigRow(title: 'Diagnostics', subtitle: 'Temperature, Wi-Fi signal, storage, sync, recent log', leading: _lead(Icons.monitor_heart_rounded), actionIcon: Icons.chevron_right_rounded,
          onTap: () { _loadHealth(); _push(_Page.diagnostics); }, onAction: () { _loadHealth(); _push(_Page.diagnostics); }),
      BigRow(title: 'Software update', subtitle: _upd.isEmpty ? 'Check, install, roll back' : 'v${_upd['current_version'] ?? '?'}${(_upd['state'] ?? 'idle') == 'running' ? ' · ${_upd['step']}' : ''}', leading: _lead(Icons.system_update_rounded), actionIcon: Icons.chevron_right_rounded,
          onTap: () { _loadUpdate(); _push(_Page.update); }, onAction: () { _loadUpdate(); _push(_Page.update); }),
      BigRow(title: 'Restart player services', subtitle: 'Daemon, remote and cast receiver (a few seconds)', leading: _lead(Icons.restart_alt_rounded, color: T.bad), onTap: () { widget.actions.touch(); widget.actions.restartServices(); }),
    ]);
  }
}
