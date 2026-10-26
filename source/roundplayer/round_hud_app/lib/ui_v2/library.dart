// Library / Queue / YouTube / Search: flat 112 px rows, one level at a time, bottom pill tabs.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'keyboard.dart';
import 'model.dart';
import 'tokens.dart';

enum LibTab { search, library, queue, youtube, settings }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.view, required this.actions, required this.onClose, required this.onOpenSettings, required this.tab, required this.onTab, required this.onPlayed, this.locateActive = false, this.initialSheetTrack});
  final HudView view;
  final HudActions actions;
  final VoidCallback onClose;
  final VoidCallback onOpenSettings;
  final LibTab tab;
  final void Function(LibTab) onTab;
  final VoidCallback onPlayed;   // the user started something: the shell switches to Now Playing
  final bool locateActive;       // opened from Now Playing: land on the playing track (artist > album > track)
  final Map<String, dynamic>? initialSheetTrack; // opened from the "…" on Now Playing: start with the track sheet up

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  // Library drill-down
  int _level = 0; // 0 artists, 1 albums, 2 tracks
  Map<String, dynamic>? _artist;
  Map<String, dynamic>? _album;
  final _scroll = <int, ScrollController>{};

  // Queue
  List<Map<String, dynamic>> _queue = [];
  String _queueBody = '';
  Timer? _queueTimer;

  // Search
  String _query = '';
  bool _searchHiFi = true;
  Timer? _debounce;

  ScrollController _ctl(int key) => _scroll.putIfAbsent(key, ScrollController.new);

  @override
  void initState() {
    super.initState();
    widget.actions.loadHiFiTree();
    widget.actions.loadCachedTracks();
    _refreshQueue();
    if ((Platform.environment['HUD_DEBUG_SCREEN'] ?? '') == 'search') { _query = 'daft'; _searchHiFi = true; }
    _queueTimer = Timer.periodic(const Duration(seconds: 4), (_) { if (widget.tab == LibTab.queue) _refreshQueue(); });
    _pendingLocate = widget.locateActive;
    if (widget.initialSheetTrack != null) _sheetTrack = Map<String, dynamic>.from(widget.initialSheetTrack!);
    _locateActive();
    widget.actions.loadPlaylists();
    _loadHome();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen old) {
    super.didUpdateWidget(old);
    if (_pendingLocate && (old.view.hifiTree == null || old.view.cachedTracks.isEmpty)) _locateActive();
  }

  bool _pendingLocate = false;

  /// Drill to the playing Hi-Fi track (or the playing video in the YouTube tab) and scroll it into view.
  void _locateActive() {
    if (!_pendingLocate) return;
    final v = widget.view;
    final id = v.activeId;
    if (id == 'standby') { _pendingLocate = false; return; }
    if (id.startsWith('hifi_')) {
      final tree = v.hifiTree;
      if (tree == null) return; // retry when the tree arrives
      _pendingLocate = false;
      final clean = id.substring(5);
      for (final a in (tree['artists'] as List? ?? []).cast<Map>()) {
        for (final al in (a['albums'] as List? ?? []).cast<Map>()) {
          final tracks = (al['tracks'] as List? ?? []);
          final idx = tracks.indexWhere((t) => (t as Map)['track_id'].toString() == clean);
          if (idx < 0) continue;
          setState(() { _artist = Map<String, dynamic>.from(a); _album = Map<String, dynamic>.from(al); _level = 2; _extraLevel = 3; });
          _scrollTo(2, idx + 1, tracks.length + 1);
          return;
        }
      }
      return;
    }
    // YouTube video
    if (v.cachedTracks.isEmpty) return;
    _pendingLocate = false;
    final idx = v.cachedTracks.indexWhere((t) => t['video_id'].toString() == id);
    if (idx < 0) return;
    if (widget.tab != LibTab.youtube) widget.onTab(LibTab.youtube);
    _scrollTo(4, idx, v.cachedTracks.length);
  }

  /// Centre row [index] of list [key] in the body once it has laid out.
  void _scrollTo(int key, int index, int count, {double extent = 124}) {
    void go(int tries) {
      if (!mounted) return;
      final c = _ctl(key);
      if (!c.hasClients) { if (tries > 0) WidgetsBinding.instance.addPostFrameCallback((_) => go(tries - 1)); return; }
      final viewport = c.position.viewportDimension;
      final target = (index * extent - (viewport - extent) / 2).clamp(0.0, c.position.maxScrollExtent);
      c.jumpTo(target);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => go(5));
  }

  void _played() => widget.onPlayed();

  @override
  void dispose() {
    _queueTimer?.cancel();
    _debounce?.cancel();
    for (final c in _scroll.values) c.dispose();
    super.dispose();
  }

  Future<void> _refreshQueue() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/queue')).timeout(const Duration(seconds: 3));
      // Polled every 4 s while the tab is open: rebuild only when the queue actually changed
      if (r.statusCode == 200 && mounted && r.body != _queueBody) {
        _queueBody = r.body;
        final d = jsonDecode(r.body) as Map;
        setState(() => _queue = (d['queue'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (_) {}
  }

  Future<void> _removeFromQueue(int i) async {
    try { await http.post(Uri.parse('http://127.0.0.1:8000/api/queue/remove/$i')).timeout(const Duration(seconds: 3)); } catch (_) {}
    _refreshQueue();
  }

  Future<void> _clearQueue() async {
    try { await http.post(Uri.parse('http://127.0.0.1:8000/api/queue/clear')).timeout(const Duration(seconds: 3)); } catch (_) {}
    _refreshQueue();
  }

  void _back() {
    widget.actions.touch();
    if (_naming) { setState(() { _naming = false; _newName = ''; }); return; }
    if (_sheetTrack != null) { setState(() => _sheetTrack = null); return; }
    if (widget.tab == LibTab.library && _playlist != null) { setState(() { _playlist = null; _plTracks = []; }); return; }
    if (widget.tab == LibTab.library && _level == 0 && _extraLevel != 0) {
      setState(() => _extraLevel = 0);
    } else if (widget.tab == LibTab.library && _level > 0) {
      if (_extraLevel == 5 && _level == 2) { setState(() { _level = 0; _artist = null; _album = null; }); return; }
      setState(() { _level -= 1; if (_level == 0) _artist = null; if (_level <= 1) _album = null; });
    } else {
      widget.onClose();
    }
  }

  void _onKey(String ch) {
    setState(() => _query += ch);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  void _runSearch() {
    if (_query.trim().isEmpty) return;
    if (_searchHiFi) {
      widget.actions.searchHiFi(_query);
    } else {
      widget.actions.searchYouTube(_query);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    String eyebrow;
    String heading;
    if (_naming) { eyebrow = 'NEW PLAYLIST'; heading = _newName.isEmpty ? 'Name' : _newName; }
    else if (_sheetTrack != null) { eyebrow = 'TRACK'; heading = (_sheetTrack!['title'] ?? '').toString(); }
    else switch (widget.tab) {
      case LibTab.library:
        if (_level == 0 && _extraLevel == 1 && _playlist != null) { eyebrow = 'PLAYLIST'; heading = (_playlist?['name'] ?? '').toString(); }
        else if (_level == 0 && _extraLevel == 1) { eyebrow = 'HI-FI LIBRARY'; heading = 'Playlists'; }
        else if (_level == 0 && _extraLevel == 2) { eyebrow = 'HI-FI LIBRARY'; heading = 'Smart mixes'; }
        else if (_level == 0 && _extraLevel == 3) { eyebrow = 'HI-FI LIBRARY'; heading = '${(v.hifiTree?['artists'] as List?)?.length ?? 0} artists'; }
        else if (_level == 0 && _extraLevel == 4) { eyebrow = 'HI-FI LIBRARY'; heading = 'Recently played'; }
        else if (_level == 0 && _extraLevel == 5) { eyebrow = 'HI-FI LIBRARY'; heading = '${_albums.length} albums'; }
        else if (_level == 0) { eyebrow = 'ROUND PLAYER'; heading = 'Library'; }
        else if (_level == 1) { eyebrow = (_artist?['name'] ?? '').toString().toUpperCase(); heading = '${(_artist?['albums'] as List?)?.length ?? 0} albums'; }
        else { eyebrow = '${_artist?['name']} · ${_album?['name']}'.toUpperCase(); heading = '${(_album?['tracks'] as List?)?.length ?? 0} tracks'; }
        break;
      case LibTab.queue: eyebrow = 'UP NEXT'; heading = _queue.isEmpty ? 'Queue is empty' : '${_queue.length} queued'; break;
      case LibTab.youtube: eyebrow = 'YOUTUBE'; heading = '${v.cachedTracks.length} cached videos'; break;
      case LibTab.search: eyebrow = _searchHiFi ? 'SEARCH HI-FI' : 'SEARCH YOUTUBE'; heading = ''; break;
      case LibTab.settings: eyebrow = ''; heading = ''; break;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 700) _back(); },
      child: Container(
        color: T.bg,
        child: Stack(
          children: [
            // Header
            Positioned(
              left: T.headerInset, right: T.headerInset, top: T.headerTop,
              child: Column(
                children: [
                  Text(eyebrow, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: T.eyebrow),
                  if (heading.isNotEmpty) ...[const SizedBox(height: 4), Text(heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h)],
                ],
              ),
            ),
            // Back / close on the diameter
            Positioned(left: 96, top: T.diameterY, child: RoundButton(onTap: _back, child: Icon(widget.tab == LibTab.library && (_level > 0 || _extraLevel != 0 || _playlist != null) ? Icons.arrow_back_rounded : Icons.close_rounded, size: 52, color: T.fg))),
            if (widget.tab == LibTab.queue && _queue.isNotEmpty)
              Positioned(right: 96, top: T.diameterY, child: RoundButton(onTap: () { widget.actions.touch(); _clearQueue(); }, child: const Icon(Icons.delete_sweep_rounded, size: 48, color: T.fg))),
            if (widget.tab == LibTab.library)
              Positioned(right: 96, top: T.diameterY, child: _syncButton()),

            // Sync status banner / toast
            if (widget.tab == LibTab.library && widget.view.hifiSyncStatus != 'idle' && widget.view.hifiSyncMessage.isNotEmpty)
              Positioned(
                left: 120, right: 120, top: 168,
                child: Center(child: _syncBanner()),
              ),

            // Body (shorter while the mini player is shown underneath it)
            Positioned(left: T.bodyInset, right: T.bodyInset, top: T.bodyTop, bottom: T.bodyBottom + (_showMiniBar ? 104 : 0), child: _body()),
            // Mini player: what is on, play/pause, tap -> Now Playing (the way every phone player keeps the music in reach)
            if (_showMiniBar) Positioned(left: T.bodyInset, right: T.bodyInset, bottom: T.bodyBottom, height: 84, child: _miniBar()),

            // Search keyboard: 546..912, below the diameter buttons, where the chord is still 810+ wide
            if (_keyboardUp) Positioned(left: 0, right: 0, bottom: 168, child: Center(child: _searchKeyboard())),
            // New playlist name
            if (_naming) ...[
              Positioned(left: 230, right: 230, top: 236, child: BigField(text: _newName, placeholder: 'Playlist name', accent: T.gold)),
              Positioned(
                left: 0, right: 0, bottom: 168,
                child: Center(
                  child: BigKeyboard(
                    submitLabel: 'Create', submitColor: T.gold,
                    onKey: (c) => setState(() => _newName += c),
                    onBackspace: () { if (_newName.isNotEmpty) setState(() => _newName = _newName.substring(0, _newName.length - 1)); },
                    onSubmit: () async {
                      widget.actions.touch();
                      final name = _newName.trim();
                      if (name.isEmpty) return;
                      final t = _sheetTrack;
                      await _createPlaylist(name, withTrack: t);
                      if (mounted) setState(() { _naming = false; _newName = ''; _sheetTrack = null; if (t == null) _extraLevel = 1; });
                    },
                  ),
                ),
              ),
            ],

            // Tabs (hidden while the keyboard is up - they would sit under it)
            if (!_keyboardUp && !_naming) Positioned(
              left: 0, right: 0, bottom: T.tabsBottom,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TabPill(label: '', icon: Icons.search_rounded, on: widget.tab == LibTab.search, onTap: () => widget.onTab(LibTab.search)),
                  const SizedBox(width: 12),
                  TabPill(label: 'Library', on: widget.tab == LibTab.library, onTap: () => widget.onTab(LibTab.library)),
                  const SizedBox(width: 12),
                  TabPill(label: 'Queue', on: widget.tab == LibTab.queue, onTap: () { widget.onTab(LibTab.queue); _refreshQueue(); }),
                  const SizedBox(width: 12),
                  TabPill(label: 'YouTube', on: widget.tab == LibTab.youtube, onTap: () => widget.onTab(LibTab.youtube)),
                  const SizedBox(width: 12),
                  TabPill(label: '', icon: Icons.settings_rounded, on: false, onTap: widget.onOpenSettings),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncButton() {
    final syncing = widget.view.hifiSyncStatus == 'syncing';
    return RoundButton(
      onTap: syncing
          ? null
          : () {
              widget.actions.touch();
              widget.actions.syncHiFiLibrary();
            },
      child: syncing
          ? const _RotatingIcon(icon: Icons.refresh_rounded, color: T.cyan, size: 48)
          : const Icon(Icons.refresh_rounded, size: 48, color: T.fg),
    );
  }

  Widget _syncBanner() {
    final status = widget.view.hifiSyncStatus;
    final msg = widget.view.hifiSyncMessage;
    final isSyncing = status == 'syncing';
    final isComplete = status == 'complete';

    final Color accentColor = isSyncing
        ? T.cyan
        : (isComplete ? T.good : T.bad);

    final IconData icon = isSyncing
        ? Icons.sync_rounded
        : (isComplete ? Icons.check_circle_rounded : Icons.error_outline_rounded);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xF00F1522),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: accentColor.withValues(alpha: 0.6), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.25),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSyncing)
            _RotatingIcon(icon: icon, color: accentColor, size: 22)
          else
            Icon(icon, size: 22, color: accentColor),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              msg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isComplete ? T.fg : accentColor,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_sheetTrack != null && !_naming) return _trackSheet(_sheetTrack!);
    if (_naming) return const SizedBox.shrink(); // keyboard is positioned by build()
    switch (widget.tab) {
      case LibTab.library: return _library();
      case LibTab.queue: return _queueList();
      case LibTab.youtube: return _youtube();
      case LibTab.search: return _search();
      case LibTab.settings: return const SizedBox.shrink();
    }
  }

  Widget _list({required int count, required Widget Function(int) item, required int key, double extent = 124}) {
    if (count == 0) return const SizedBox.shrink();
    return ListView.builder(
      controller: _ctl(key),
      physics: const BouncingScrollPhysics(),
      itemExtent: extent,
      itemCount: count,
      itemBuilder: (_, i) => Padding(padding: const EdgeInsets.only(bottom: 12), child: item(i)),
    );
  }

  Widget _empty(String text, {IconData icon = Icons.music_off_rounded}) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 72, color: T.mute), const SizedBox(height: 16), Text(text, style: T.body.copyWith(color: T.mute))]),
      );

  // ---- Library (artists -> albums -> tracks)
  // Level 0 has two extra rows on top: Playlists and Smart mixes (ported from v1).
  static const _extraRows = 0;
  int _extraLevel = 0; // 0 home, 1 playlists, 2 smart mixes, 3 artists, 4 recently played

  Widget _library() {
    final tree = widget.view.hifiTree;
    if (tree == null) return _empty('Loading library…', icon: Icons.hourglass_top_rounded);
    final artists = (tree['artists'] as List? ?? []).cast<Map>();
    if (artists.isEmpty) return _empty('No Hi-Fi library yet');
    if (_level == 0 && _extraLevel == 1 && _playlist != null) return _playlistTracks();
    if (_level == 0 && _extraLevel == 1) return _playlists();
    if (_level == 0 && _extraLevel == 2) return _smartMixes();
    if (_level == 0 && _extraLevel == 4) return _recentlyPlayed();
    if (_level == 0 && _extraLevel == 5) return _albumsView();
    if (_level == 0 && _extraLevel == 0) return _home(artists.length);
    if (_level == 0) {
      // Alphabet rail: first index per initial letter -> jumpTo(index * extent)
      final letters = <String, int>{};
      for (int i = 0; i < artists.length; i++) {
        final n = (artists[i]['name']?.toString() ?? '').trim();
        final l = n.isEmpty ? '#' : (RegExp(r'[A-Za-z]').hasMatch(n[0]) ? n[0].toUpperCase() : '#');
        letters.putIfAbsent(l, () => i + _extraRows);
      }
      return Row(
        children: [
          Expanded(
            child: _list(key: 0, count: artists.length + _extraRows, item: (i) {
              final a = Map<String, dynamic>.from(artists[i - _extraRows]);
              final albums = (a['albums'] as List? ?? []);
              final cover = albums.isNotEmpty ? (albums.first as Map)['cover_rel']?.toString() : null;
              return BigRow(
                title: a['name']?.toString() ?? '',
                subtitle: '${albums.length} album${albums.length == 1 ? '' : 's'}',
                leading: Cover(cover != null ? 'http://127.0.0.1:8000/api/hifi/cover?rel_path=${Uri.encodeComponent(cover)}' : null, fallbackIcon: Icons.person_rounded),
                actionIcon: Icons.chevron_right_rounded,
                onTap: () { widget.actions.touch(); setState(() { _artist = a; _level = 1; }); },
                onAction: () { widget.actions.touch(); setState(() { _artist = a; _level = 1; }); },
                accent: T.gold,
              );
            }),
          ),
          if (letters.length > 3) _AlphabetRail(letters: letters, onJump: (idx) { widget.actions.touch(); _ctl(0).jumpTo((idx * 124.0).clamp(0.0, _ctl(0).position.maxScrollExtent)); }),
        ],
      );
    }
    if (_level == 1) {
      final albums = (_artist?['albums'] as List? ?? []).cast<Map>();
      return _list(key: 1, count: albums.length, item: (i) {
        final al = Map<String, dynamic>.from(albums[i]);
        final tracks = (al['tracks'] as List? ?? []);
        final cover = al['cover_rel']?.toString();
        return BigRow(
          title: al['name']?.toString() ?? '',
          subtitle: '${tracks.length} track${tracks.length == 1 ? '' : 's'}',
          leading: Cover(cover != null ? 'http://127.0.0.1:8000/api/hifi/cover?rel_path=${Uri.encodeComponent(cover)}' : null),
          actionIcon: Icons.play_arrow_rounded,
          onTap: () { widget.actions.touch(); setState(() { _album = al; _level = 2; }); },
          onAction: () {
            widget.actions.touch();
            final list = tracks.map((t) => Map<String, dynamic>.from(t as Map)).toList();
            if (list.isNotEmpty) { widget.actions.playHiFi(list.first['track_id'].toString(), playlist: list, index: 0); _played(); }
          },
          accent: T.gold,
        );
      });
    }
    // Level 2: album header (cover + Play all / Shuffle) then the tracks
    final tracks = (_album?['tracks'] as List? ?? []).map((t) => Map<String, dynamic>.from(t as Map)).toList();
    final cover = _album?['cover_rel']?.toString();
    final coverUrl = cover != null ? 'http://127.0.0.1:8000/api/hifi/cover?rel_path=${Uri.encodeComponent(cover)}' : null;
    return _list(key: 2, count: tracks.length + 1, extent: 124, item: (i) {
      if (i == 0) {
        return _AlbumHeader(
          coverUrl: coverUrl,
          onPlayAll: () { widget.actions.touch(); if (tracks.isNotEmpty) { widget.actions.playHiFi(tracks.first['track_id'].toString(), playlist: tracks, index: 0); _played(); } },
          onShuffle: () {
            widget.actions.touch();
            if (tracks.isEmpty) return;
            if (!widget.view.shuffle) widget.actions.toggleShuffle();
            final idx = DateTime.now().millisecondsSinceEpoch % tracks.length;
            widget.actions.playHiFi(tracks[idx]['track_id'].toString(), playlist: tracks, index: idx);
            _played();
          },
        );
      }
      final t = tracks[i - 1];
      final id = t['track_id'].toString();
      final now = widget.view.activeId == 'hifi_$id';
      final prep = widget.view.preparingId == 'hifi_$id';
      final fmt = [t['format'], if (t['bit_depth'] != null && t['sample_rate_hz'] != null) '${t['bit_depth']}/${((t['sample_rate_hz'] as num) / 1000).toStringAsFixed(0)}'].whereType<Object>().join(' ');
      final cached = t['is_cached'] == true;
      return BigRow(
        title: t['title']?.toString() ?? '',
        subtitle: [if (t['track_num'] != null) '#${t['track_num']}', fmt, if (prep) '↓ ${widget.view.preparingPercent}%'].where((s) => s.toString().isNotEmpty).join(' · '),
        leading: Cover(coverUrl),
        active: now || prep,
        trailingIcon: !cached && !now ? Icons.cloud_outlined : null,
        actionIcon: now ? Icons.graphic_eq_rounded : Icons.playlist_add_rounded,
        onTap: () { widget.actions.touch(); widget.actions.playHiFi(id, playlist: tracks, index: i - 1); _played(); },
        onLongPress: () { widget.actions.touch(); if (!now) widget.actions.addToQueue({'video_id': 'hifi_$id', 'title': t['title'], 'artist': t['artist'], 'source': 'hifi', 'position': 'next'}); },
        onAction: () { widget.actions.touch(); setState(() => _sheetTrack = {...t, 'track_id': id}); },
        accent: T.gold,
      );
    });
  }

  // ---- Home: the things you actually come back to first (Spotify/Apple Music "Library" shape)
  Map<String, dynamic>? _resume;        // /api/resume/info
  List<Map<String, dynamic>> _history = [];
  bool _historyLoading = false;

  Future<void> _loadHome() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/resume/info')).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200 && mounted) setState(() => _resume = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
    } catch (_) {}
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyLoading) return;
    _historyLoading = true;
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/history?limit=40')).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && mounted) {
        final d = jsonDecode(r.body) as Map;
        setState(() => _history = (d['items'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (_) {}
    _historyLoading = false;
  }

  Widget _home(int artistCount) {
    final v = widget.view;
    final fav = v.playlists.where((p) => p['is_favorites'] == true || (p['id'] ?? '') == 'favorites').toList();
    final favCount = fav.isNotEmpty ? (fav.first['track_count'] ?? 0) : 0;
    final canResume = v.isStandby && _resume != null && _resume!['available'] == true;
    final recentSub = _history.isEmpty ? 'Nothing yet' : _history.take(2).map((h) => (h['title'] ?? '').toString()).where((t) => t.isNotEmpty).join(' · ');
    final rows = <Widget>[
      if (canResume)
        BigRow(
          title: (_resume!['title'] ?? 'Continue listening').toString(),
          subtitle: 'Continue · ${_resume!['artist'] ?? ''} · ${_fmtPos((_resume!['position_s'] as num?)?.toDouble() ?? 0)}',
          leading: Cover((_resume!['track_id'] ?? '').toString().startsWith('hifi_') ? 'http://127.0.0.1:8000/api/hifi/cover?track_id=${_resume!['track_id']}' : 'http://127.0.0.1:8000/media/${_resume!['track_id']}/cover.jpg'),
          active: true, accent: T.gold, actionIcon: Icons.play_arrow_rounded,
          onTap: () { widget.actions.touch(); widget.actions.wake(); Future.delayed(const Duration(milliseconds: 400), () => widget.actions.togglePlay()); _played(); },
          onAction: () { widget.actions.touch(); widget.actions.wake(); Future.delayed(const Duration(milliseconds: 400), () => widget.actions.togglePlay()); _played(); },
        ),
      BigRow(title: 'Recently played', subtitle: recentSub, leading: Container(color: T.cardRaised, child: const Icon(Icons.history_rounded, size: 44, color: T.gold)), actionIcon: Icons.chevron_right_rounded, accent: T.gold,
          onTap: () { widget.actions.touch(); _loadHistory(); setState(() => _extraLevel = 4); }, onAction: () { widget.actions.touch(); _loadHistory(); setState(() => _extraLevel = 4); }),
      BigRow(title: 'Favourites', subtitle: favCount == 0 ? 'Tap ♥ on a playing track' : '$favCount track${favCount == 1 ? '' : 's'}', leading: Container(color: T.cardRaised, child: const Icon(Icons.favorite_rounded, size: 44, color: T.gold)), actionIcon: Icons.chevron_right_rounded, accent: T.gold,
          onTap: () { widget.actions.touch(); setState(() => _extraLevel = 1); _openPlaylist({'id': 'favorites', 'name': 'Favourites', 'is_favorites': true, 'track_count': favCount}); },
          onAction: () { widget.actions.touch(); setState(() => _extraLevel = 1); _openPlaylist({'id': 'favorites', 'name': 'Favourites', 'is_favorites': true, 'track_count': favCount}); }),
      BigRow(title: 'Playlists', subtitle: '${v.playlists.where((p) => p['is_favorites'] != true && (p['id'] ?? '') != 'favorites').length} saved', leading: Container(color: T.cardRaised, child: const Icon(Icons.queue_music_rounded, size: 44, color: T.gold)), actionIcon: Icons.chevron_right_rounded, accent: T.gold,
          onTap: () { widget.actions.touch(); widget.actions.loadPlaylists(); setState(() => _extraLevel = 1); }, onAction: () { widget.actions.touch(); widget.actions.loadPlaylists(); setState(() => _extraLevel = 1); }),
      BigRow(title: 'Smart mixes', subtitle: 'Like this, artist radio, shuffle, hi-res, new', leading: Container(color: T.cardRaised, child: const Icon(Icons.auto_awesome_rounded, size: 44, color: T.gold)), actionIcon: Icons.chevron_right_rounded, accent: T.gold,
          onTap: () { widget.actions.touch(); _loadDecades(); setState(() => _extraLevel = 2); }, onAction: () { widget.actions.touch(); _loadDecades(); setState(() => _extraLevel = 2); }),
      BigRow(title: 'Artists', subtitle: '$artistCount artists · browse by album', leading: Container(color: T.cardRaised, child: const Icon(Icons.person_rounded, size: 44, color: T.gold)), actionIcon: Icons.chevron_right_rounded, accent: T.gold,
          onTap: () { widget.actions.touch(); setState(() => _extraLevel = 3); }, onAction: () { widget.actions.touch(); setState(() => _extraLevel = 3); }),
      BigRow(title: 'Albums', subtitle: 'Every album, A to Z', leading: Container(color: T.cardRaised, child: const Icon(Icons.album_rounded, size: 44, color: T.gold)), actionIcon: Icons.chevron_right_rounded, accent: T.gold,
          onTap: () { widget.actions.touch(); _loadAlbums(); setState(() => _extraLevel = 5); }, onAction: () { widget.actions.touch(); _loadAlbums(); setState(() => _extraLevel = 5); }),
    ];
    return _rows2(rows);
  }

  String _fmtPos(double s) {
    final m = (s ~/ 60).toString();
    final sec = (s.toInt() % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  // ---- Albums (SQLite index): A→Z with the alphabet rail, tap opens the album in the usual track view
  List<Map<String, dynamic>> _albums = [];
  Future<void> _loadAlbums() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/albums?sort=name')).timeout(const Duration(seconds: 6));
      if (r.statusCode == 200 && mounted) {
        final d = jsonDecode(r.body) as Map;
        setState(() => _albums = (d['albums'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (_) {}
  }

  void _openAlbumByNames(String artist, String album) {
    final tree = widget.view.hifiTree;
    for (final a in (tree?['artists'] as List? ?? []).cast<Map>()) {
      if (a['name']?.toString() != artist) continue;
      for (final al in (a['albums'] as List? ?? []).cast<Map>()) {
        if (al['name']?.toString() == album) {
          setState(() { _artist = Map<String, dynamic>.from(a); _album = Map<String, dynamic>.from(al); _level = 2; });
          return;
        }
      }
    }
  }

  Widget _albumsView() {
    if (_albums.isEmpty) return _empty('Loading albums…', icon: Icons.hourglass_top_rounded);
    final letters = <String, int>{};
    for (int i = 0; i < _albums.length; i++) {
      final n = (_albums[i]['album']?.toString() ?? '').trim();
      final l = n.isEmpty ? '#' : (RegExp(r'[A-Za-z]').hasMatch(n[0]) ? n[0].toUpperCase() : '#');
      letters.putIfAbsent(l, () => i);
    }
    return Row(
      children: [
        Expanded(
          child: _list(key: 10, count: _albums.length, item: (i) {
            final al = _albums[i];
            final cover = al['cover_rel']?.toString();
            final n = (al['track_count'] as num?)?.toInt() ?? 0;
            return BigRow(
              title: al['album']?.toString() ?? '',
              subtitle: [al['artist'], if (al['year'] != null) al['year'].toString(), '$n track${n == 1 ? '' : 's'}'].whereType<Object>().map((e) => e.toString()).join(' · '),
              leading: Cover(cover != null ? 'http://127.0.0.1:8000/api/hifi/cover?rel_path=${Uri.encodeComponent(cover)}' : null),
              actionIcon: Icons.play_arrow_rounded,
              onTap: () { widget.actions.touch(); _openAlbumByNames(al['artist'].toString(), al['album'].toString()); },
              onAction: () async {
                widget.actions.touch();
                try {
                  final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/albums/${Uri.encodeComponent(al['album_key'].toString())}')).timeout(const Duration(seconds: 6));
                  final tracks = ((jsonDecode(r.body) as Map)['tracks'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
                  if (tracks.isNotEmpty) { widget.actions.playHiFi(tracks.first['track_id'].toString(), playlist: tracks, index: 0); _played(); }
                } catch (_) {}
              },
              accent: T.gold,
            );
          }),
        ),
        if (letters.length > 3) _AlphabetRail(letters: letters, onJump: (idx) { widget.actions.touch(); _ctl(10).jumpTo((idx * 124.0).clamp(0.0, _ctl(10).position.maxScrollExtent)); }),
      ],
    );
  }

  List<Map<String, dynamic>> _decades = [];
  Future<void> _loadDecades() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/decades')).timeout(const Duration(seconds: 6));
      if (r.statusCode == 200 && mounted) {
        final d = jsonDecode(r.body) as Map;
        setState(() => _decades = (d['decades'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (_) {}
  }

  Widget _recentlyPlayed() {
    if (_history.isEmpty) return _empty(_historyLoading ? 'Loading…' : 'Nothing played yet', icon: Icons.history_rounded);
    final hifiTracks = _history.where((h) => h['track'] is Map).map((h) => Map<String, dynamic>.from(h['track'] as Map)).toList();
    return _list(key: 9, count: _history.length, item: (i) {
      final h = _history[i];
      final id = (h['track_id'] ?? '').toString();
      final hifi = id.startsWith('hifi_');
      final now = widget.view.activeId == id;
      final ago = _ago((h['ts'] as num?)?.toDouble());
      return BigRow(
        title: (h['title'] ?? id).toString(),
        subtitle: [h['artist'], h['album'], ago].whereType<Object>().map((e) => e.toString()).where((x) => x.isNotEmpty).join(' · '),
        leading: Cover(hifi ? 'http://127.0.0.1:8000/api/hifi/cover?track_id=$id' : 'http://127.0.0.1:8000/media/$id/cover.jpg', fallbackIcon: hifi ? Icons.album_rounded : Icons.ondemand_video_rounded),
        active: now,
        actionIcon: now ? Icons.graphic_eq_rounded : Icons.playlist_add_rounded,
        onTap: () {
          widget.actions.touch();
          if (hifi) {
            final idx = hifiTracks.indexWhere((t) => 'hifi_${t['track_id']}' == id);
            widget.actions.playHiFi(id.substring(5), playlist: hifiTracks.isEmpty ? null : hifiTracks, index: idx < 0 ? null : idx);
          } else {
            widget.actions.playYouTube(id);
          }
          _played();
        },
        onAction: () { widget.actions.touch(); if (hifi && h['track'] is Map) setState(() => _sheetTrack = {...Map<String, dynamic>.from(h['track'] as Map), 'track_id': id.substring(5)}); },
        accent: hifi ? T.gold : T.cyan,
      );
    });
  }

  String _ago(double? ts) {
    if (ts == null) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((ts * 1000).round()));
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return '${d.inDays ~/ 7} w ago';
  }

  // ---- Mini player under the lists
  bool get _showMiniBar => !widget.view.isStandby && !_keyboardUp && !_naming && _sheetTrack == null;

  Widget _miniBar() {
    final v = widget.view;
    final cover = v.isExternal ? 'http://127.0.0.1:8000/api/external/cover?t=${Uri.encodeComponent(v.title)}' : (v.isHiFi ? 'http://127.0.0.1:8000/api/hifi/cover?track_id=${v.activeId}' : 'http://127.0.0.1:8000/media/${v.activeId}/cover.jpg');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () { widget.actions.touch(); widget.onClose(); },
      child: Container(
        decoration: BoxDecoration(color: T.cardRaised, borderRadius: BorderRadius.circular(22), border: Border.all(color: const Color(0x22FFFFFF), width: 1.5)),
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        child: Row(
          children: [
            SizedBox(width: 68, height: 68, child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Cover(cover))),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: T.text, fontSize: 26, fontWeight: FontWeight.w600, color: T.fg, height: 1.1)),
                  const SizedBox(height: 2),
                  Text(v.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: T.text, fontSize: 20, fontWeight: FontWeight.w300, color: T.mute, height: 1.1)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<bool>(
              valueListenable: v.isPlaying,
              builder: (_, playing, __) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () { widget.actions.touch(); widget.actions.togglePlay(); },
                child: SizedBox(width: 68, height: 68, child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 52, color: T.fg)),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () { widget.actions.touch(); widget.actions.next(); },
              child: const SizedBox(width: 56, height: 68, child: Icon(Icons.skip_next_rounded, size: 44, color: T.fg)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playlists() {
    final pls = widget.view.playlists;
    return _list(key: 6, count: pls.length + 1, item: (i) {
      if (i == 0) {
        return BigRow(title: 'New playlist', subtitle: 'Name it on the keyboard, then add tracks with the + on any row',
            leading: Container(color: T.cardRaised, child: const Icon(Icons.add_rounded, size: 48, color: T.gold)), accent: T.gold,
            onTap: () { widget.actions.touch(); setState(() { _naming = true; _newName = ''; }); });
      }
      final p = pls[i - 1];
      final id = (p['id'] ?? p['playlist_id'] ?? '').toString();
      final n = (p['track_count'] ?? (p['tracks'] as List?)?.length ?? 0);
      final fav = p['is_favorites'] == true || id == 'favorites';
      return BigRow(
        title: p['name']?.toString() ?? 'Playlist',
        subtitle: n == 0 ? (fav ? 'Empty — tap ♥ on a playing track' : 'Empty — use + on any track') : '$n track${n == 1 ? '' : 's'} · tap to open${fav ? '' : ' · hold to delete'}',
        leading: Container(color: T.cardRaised, child: Icon(fav ? Icons.favorite_rounded : Icons.queue_music_rounded, size: 44, color: T.gold)),
        actionIcon: n > 0 ? Icons.play_arrow_rounded : Icons.chevron_right_rounded,
        onTap: () { widget.actions.touch(); _openPlaylist(p); },
        onAction: () { widget.actions.touch(); if (n > 0) { widget.actions.playPlaylist(id); _played(); } else { _openPlaylist(p); } },
        onLongPress: fav ? null : () { widget.actions.touch(); _deletePlaylist(id); },
        accent: T.gold,
      );
    });
  }

  // ---- One playlist: header (Play all / Shuffle) then its tracks; the row action removes a track.
  Map<String, dynamic>? _playlist;
  List<Map<String, dynamic>> _plTracks = [];
  bool _plLoading = false;

  Future<void> _openPlaylist(Map<String, dynamic> p) async {
    final id = (p['id'] ?? p['playlist_id'] ?? '').toString();
    setState(() { _playlist = {...p, 'id': id}; _plTracks = []; _plLoading = true; });
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists/$id')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200 && mounted && _playlist?['id'] == id) {
        final d = jsonDecode(r.body) as Map;
        setState(() { _plTracks = (d['tracks'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(); _plLoading = false; });
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _plLoading = false);
  }

  Future<void> _removeFromPlaylist(String playlistId, String trackId) async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists/$playlistId/remove'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'track_id': trackId})).timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _plTracks.removeWhere((t) => (t['track_id'] ?? t['id']).toString() == trackId));
    widget.actions.loadPlaylists();
    if (_playlist != null) _playlist = {..._playlist!, 'track_count': _plTracks.length};
  }

  Widget _playlistTracks() {
    final pl = _playlist!;
    final id = pl['id'].toString();
    final fav = pl['is_favorites'] == true || id == 'favorites';
    if (_plLoading && _plTracks.isEmpty) return _empty('Loading…', icon: Icons.hourglass_top_rounded);
    if (_plTracks.isEmpty) return _empty(fav ? 'No favourites yet — tap ♥ on a playing track' : 'Empty — use + on any track to add', icon: fav ? Icons.favorite_border_rounded : Icons.queue_music_rounded);
    final tracks = _plTracks;
    final firstId = (tracks.first['track_id'] ?? tracks.first['id']).toString();
    return _list(key: 8, count: tracks.length + 1, item: (i) {
      if (i == 0) {
        return _AlbumHeader(
          coverUrl: 'http://127.0.0.1:8000/api/hifi/cover?track_id=$firstId',
          onPlayAll: () { widget.actions.touch(); widget.actions.playPlaylist(id); _played(); },
          onShuffle: () { widget.actions.touch(); widget.actions.playPlaylist(id, shuffle: true); _played(); },
        );
      }
      final t = tracks[i - 1];
      final tid = (t['track_id'] ?? t['id']).toString();
      final now = widget.view.activeId == 'hifi_$tid';
      final prep = widget.view.preparingId == 'hifi_$tid';
      return BigRow(
        title: t['title']?.toString() ?? '',
        subtitle: [t['artist'], t['album'], if (prep) '↓ ${widget.view.preparingPercent}%'].whereType<Object>().map((e) => e.toString()).where((s) => s.isNotEmpty).join(' · '),
        leading: Cover('http://127.0.0.1:8000/api/hifi/cover?track_id=$tid'),
        active: now || prep,
        actionIcon: now ? Icons.graphic_eq_rounded : Icons.remove_circle_outline_rounded,
        onTap: () { widget.actions.touch(); widget.actions.playHiFi(tid, playlist: tracks, index: i - 1); _played(); },
        onLongPress: () { widget.actions.touch(); setState(() => _sheetTrack = {...t, 'track_id': tid}); },
        onAction: () { widget.actions.touch(); if (!now) _removeFromPlaylist(id, tid); },
        accent: T.gold,
      );
    });
  }

  bool _naming = false;
  String _newName = '';
  Map<String, dynamic>? _sheetTrack; // track awaiting "add to playlist" choice

  Future<void> _createPlaylist(String name, {Map<String, dynamic>? withTrack}) async {
    try {
      final r = await http.post(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name, if (withTrack != null) 'tracks': [withTrack]})).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) await widget.actions.loadPlaylists();
    } catch (_) {}
  }

  Future<void> _addToPlaylist(String playlistId, Map<String, dynamic> track) async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists/$playlistId/add'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'track': track})).timeout(const Duration(seconds: 5));
      await widget.actions.loadPlaylists();
    } catch (_) {}
  }

  Future<void> _deletePlaylist(String id) async {
    try {
      await http.delete(Uri.parse('http://127.0.0.1:8000/api/hifi/playlists/$id')).timeout(const Duration(seconds: 5));
      await widget.actions.loadPlaylists();
    } catch (_) {}
  }

  Future<void> _toggleFavorite(Map<String, dynamic> track) async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/hifi/favorites/toggle'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'track': track})).timeout(const Duration(seconds: 5));
      await widget.actions.loadPlaylists();
    } catch (_) {}
  }

  /// The one track sheet (same everywhere - lists, search, history, Now Playing's "…"): play next / add to queue,
  /// favourite, playlists, go to artist / album, like this, artist radio.
  void _goToArtist(String artist) {
    final tree = widget.view.hifiTree;
    for (final a in (tree?['artists'] as List? ?? []).cast<Map>()) {
      if (a['name']?.toString() == artist) {
        setState(() { _sheetTrack = null; _extraLevel = 3; _artist = Map<String, dynamic>.from(a); _album = null; _level = 1; });
        if (widget.tab != LibTab.library) widget.onTab(LibTab.library);
        return;
      }
    }
    setState(() => _sheetTrack = null);
  }

  void _goToAlbum(String artist, String album, {String? highlight}) {
    setState(() { _sheetTrack = null; _extraLevel = 3; });
    if (widget.tab != LibTab.library) widget.onTab(LibTab.library);
    _openAlbumByNames(artist, album);
    if (highlight != null && _album != null) {
      final tracks = (_album!['tracks'] as List? ?? []);
      final idx = tracks.indexWhere((x) => (x as Map)['track_id'].toString() == highlight);
      if (idx >= 0) _scrollTo(2, idx + 1, tracks.length + 1);
    }
  }

  Widget _trackSheet(Map<String, dynamic> t) {
    final pls = widget.view.playlists;
    final id = (t['track_id'] ?? '').toString();
    final artist = (t['artist'] ?? '').toString();
    final album = (t['album'] ?? '').toString();
    final isNow = widget.view.activeId == 'hifi_$id';
    return _rows2([
      BigRow(title: t['title']?.toString() ?? '', subtitle: [artist, album].where((x) => x.isNotEmpty).join(' · '), leading: Cover('http://127.0.0.1:8000/api/hifi/cover?track_id=$id'), accent: T.gold),
      if (!isNow) BigRow(title: 'Play next', leading: Container(color: T.cardRaised, child: const Icon(Icons.skip_next_rounded, size: 44, color: T.fg)),
          onTap: () { widget.actions.addToQueue({'video_id': 'hifi_$id', 'title': t['title'], 'artist': artist, 'album': album, 'source': 'hifi', 'position': 'next'}); setState(() => _sheetTrack = null); }),
      if (!isNow) BigRow(title: 'Add to queue', subtitle: 'At the end', leading: Container(color: T.cardRaised, child: const Icon(Icons.playlist_play_rounded, size: 44, color: T.fg)),
          onTap: () { widget.actions.addToQueue({'video_id': 'hifi_$id', 'title': t['title'], 'artist': artist, 'album': album, 'source': 'hifi'}); setState(() => _sheetTrack = null); }),
      BigRow(title: 'Favourites', subtitle: 'Add or remove', leading: Container(color: T.cardRaised, child: const Icon(Icons.favorite_rounded, size: 44, color: T.gold)),
          onTap: () { _toggleFavorite(t); setState(() => _sheetTrack = null); }),
      if (artist.isNotEmpty) BigRow(title: 'Go to artist', subtitle: artist, leading: Container(color: T.cardRaised, child: const Icon(Icons.person_rounded, size: 44, color: T.fg)), onTap: () { widget.actions.touch(); _goToArtist(artist); }),
      if (album.isNotEmpty) BigRow(title: 'Go to album', subtitle: album, leading: Container(color: T.cardRaised, child: const Icon(Icons.album_rounded, size: 44, color: T.fg)), onTap: () { widget.actions.touch(); _goToAlbum(artist, album, highlight: id); }),
      BigRow(title: 'Like this', subtitle: 'Mix of music that goes with it', leading: Container(color: T.cardRaised, child: const Icon(Icons.auto_awesome_rounded, size: 44, color: T.gold)),
          onTap: () { widget.actions.touch(); widget.actions.playSimilar(trackId: 'hifi_$id'); setState(() => _sheetTrack = null); _played(); }),
      if (artist.isNotEmpty) BigRow(title: '$artist radio', leading: Container(color: T.cardRaised, child: const Icon(Icons.radio_rounded, size: 44, color: T.gold)),
          onTap: () { widget.actions.touch(); widget.actions.playSimilar(artist: artist); setState(() => _sheetTrack = null); _played(); }),
      for (final p in pls.where((p) => p['is_favorites'] != true && (p['id'] ?? '') != 'favorites'))
        BigRow(title: 'Add to ${p['name'] ?? 'playlist'}', leading: Container(color: T.cardRaised, child: const Icon(Icons.queue_music_rounded, size: 44, color: T.fg)),
            onTap: () { _addToPlaylist((p['id'] ?? '').toString(), t); setState(() => _sheetTrack = null); }),
      BigRow(title: 'New playlist…', leading: Container(color: T.cardRaised, child: const Icon(Icons.add_rounded, size: 48, color: T.fg)),
          onTap: () { setState(() { _naming = true; _newName = ''; }); }),
      BigRow(title: 'Cancel', leading: Container(color: T.cardRaised, child: const Icon(Icons.close_rounded, size: 44, color: T.mute)), onTap: () => setState(() => _sheetTrack = null)),
    ]);
  }

  Widget _rows2(List<Widget> rows) => ListView.separated(
        physics: const BouncingScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => rows[i],
      );

  Widget _smartMixes() {
    final v = widget.view;
    final hasSeed = v.isHiFi && !v.isStandby;
    final mixes = [
      ('similar', hasSeed ? 'Like "${v.title}"' : 'Similar to what\'s playing', hasSeed ? 'Related artists, same era, from your library' : 'Play a Hi-Fi track first', Icons.auto_awesome_rounded),
      ('artist_radio', hasSeed ? '${v.artist} radio' : 'Artist radio', hasSeed ? 'This artist and the ones that go with them' : 'Play a Hi-Fi track first', Icons.radio_rounded),
      ('heavy_rotation', 'Heavy rotation', 'What you have played most this month', Icons.local_fire_department_rounded),
      ('rediscover', 'Rediscover', 'Tracks you loved and have not heard in a while', Icons.replay_circle_filled_rounded),
      ('never_played', 'Never played', 'Corners of the library you have not been to', Icons.explore_rounded),
      ('random', 'Library shuffle', '50 random tracks from everything', Icons.casino_rounded),
      ('audiophile', 'Audiophile', 'Hi-res masters: 24-bit / 96 kHz+ and DSD', Icons.high_quality_rounded),
      ('recently_added', 'Recently added', 'Newest additions to the library', Icons.new_releases_rounded),
      for (final d in _decades)
        ('decade&decade=${d['decade']}', '${d['decade']}s', '${d['album_count']} albums · ${d['track_count']} tracks', Icons.history_toggle_off_rounded),
    ];
    return _list(key: 7, count: mixes.length, item: (i) {
      final (type, title, sub, icon) = mixes[i];
      return BigRow(
        title: title,
        subtitle: sub,
        leading: Container(color: T.cardRaised, child: Icon(icon, size: 44, color: T.gold)),
        actionIcon: Icons.play_arrow_rounded,
        onTap: () { widget.actions.touch(); _playMix(type); },
        onAction: () { widget.actions.touch(); _playMix(type); },
        accent: T.gold,
      );
    });
  }

  void _playMix(String type) {
    final v = widget.view;
    if (type == 'similar') { if (v.isHiFi && !v.isStandby) { widget.actions.playSimilar(trackId: v.activeId); _played(); } return; }
    if (type == 'artist_radio') { if (v.isHiFi && !v.isStandby) { widget.actions.playSimilar(artist: v.artist); _played(); } return; }
    widget.actions.playSmartMix(type);
    _played();
  }

  // ---- Queue
  Widget _queueList() {
    if (_queue.isEmpty) return _empty('Nothing queued — use + on any track', icon: Icons.queue_music_rounded);
    return _list(key: 3, count: _queue.length, item: (i) {
      final q = _queue[i];
      final id = (q['video_id'] ?? q['track_id'] ?? '').toString();
      final hifi = id.startsWith('hifi_') || q['source'] == 'hifi';
      return BigRow(
        title: q['title']?.toString() ?? id,
        subtitle: [q['artist']?.toString() ?? '', hifi ? 'Hi-Fi' : 'YouTube'].where((s) => s.isNotEmpty).join(' · '),
        leading: Cover(hifi ? 'http://127.0.0.1:8000/api/hifi/cover?track_id=$id' : 'http://127.0.0.1:8000/media/$id/cover.jpg'),
        actionIcon: Icons.close_rounded,
        onTap: () { widget.actions.touch(); hifi ? widget.actions.playHiFi(id) : widget.actions.playYouTube(id); _played(); },
        onAction: () { widget.actions.touch(); _removeFromQueue(i); },
        accent: hifi ? T.gold : T.cyan,
      );
    });
  }

  // ---- YouTube (cached)
  Widget _youtube() {
    final items = widget.view.cachedTracks;
    if (items.isEmpty) return _empty('No cached videos — cast from the YouTube app or search', icon: Icons.ondemand_video_rounded);
    return _list(key: 4, count: items.length, item: (i) {
      final t = items[i];
      final id = t['video_id'].toString();
      final now = widget.view.activeId == id;
      return BigRow(
        title: t['title']?.toString() ?? id,
        subtitle: t['artist']?.toString() ?? '',
        leading: Cover('http://127.0.0.1:8000/media/$id/cover.jpg', fallbackIcon: Icons.ondemand_video_rounded),
        active: now,
        actionIcon: now ? Icons.graphic_eq_rounded : Icons.playlist_add_rounded,
        onTap: () { widget.actions.touch(); widget.actions.playYouTube(id); _played(); },
        onAction: () { widget.actions.touch(); if (!now) widget.actions.addToQueue({'video_id': id, 'title': t['title'], 'artist': t['artist'], 'source': 'youtube'}); },
      );
    });
  }

  // ---- Search (keyboard + results). The keyboard stays until "Search"; tapping the field brings it back.
  bool _showResults = false;

  Widget _search() {
    final results = _searchHiFi ? widget.view.hifiSearchResults : widget.view.searchResults;
    final hasQuery = _query.trim().isNotEmpty;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () { widget.actions.touch(); setState(() => _showResults = false); },
                child: BigField(text: _query, placeholder: _searchHiFi ? 'Artist, album or track' : 'YouTube search', accent: _searchHiFi ? T.gold : T.cyan,
                    trailing: hasQuery ? Text('${results.length}', style: T.mono.copyWith(color: T.mute)) : null),
              ),
            ),
            const SizedBox(width: 12),
            TabPill(label: _searchHiFi ? 'Hi-Fi' : 'YT', on: true, onTap: () { widget.actions.touch(); setState(() => _searchHiFi = !_searchHiFi); _runSearch(); }),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _showResults && hasQuery
              ? (results.isEmpty
                  ? _empty(widget.view.isSearching ? 'Searching…' : 'No results', icon: widget.view.isSearching ? Icons.hourglass_top_rounded : Icons.search_off_rounded)
                  : _list(key: 5, extent: 104, count: results.length, item: (i) {
                      final t = results[i];
                      if (_searchHiFi) {
                        final id = (t['track_id'] ?? t['id']).toString();
                        return BigRow(
                          height: 92,
                          title: t['title']?.toString() ?? '',
                          subtitle: [t['artist'], t['album']].whereType<Object>().join(' · '),
                          actionIcon: Icons.playlist_add_rounded,
                          onTap: () { widget.actions.touch(); widget.actions.playHiFi(id); _played(); },
                          onAction: () { widget.actions.touch(); setState(() => _sheetTrack = {...t, 'track_id': id}); },
                          accent: T.gold,
                        );
                      }
                      return BigRow(
                        height: 92,
                        title: t['title']?.toString() ?? '',
                        subtitle: [t['artist'] ?? t['channel'], t['duration']].whereType<Object>().join(' · '),
                        actionIcon: Icons.play_arrow_rounded,
                        onTap: () { widget.actions.touch(); widget.actions.playSearchResult(t); _played(); },
                        onAction: () { widget.actions.touch(); widget.actions.playSearchResult(t); _played(); },
                      );
                    }))
              : const SizedBox.shrink(), // the keyboard is positioned by build() below the diameter buttons
        ),
      ],
    );
  }

  bool get _keyboardUp => widget.tab == LibTab.search && !_showResults && !_naming;

  Widget _searchKeyboard() => BigKeyboard(
        submitLabel: 'Search',
        submitColor: _searchHiFi ? T.gold : T.cyan,
        onKey: _onKey,
        onBackspace: () { if (_query.isNotEmpty) setState(() => _query = _query.substring(0, _query.length - 1)); _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 350), _runSearch); },
        onSubmit: () { widget.actions.touch(); _runSearch(); setState(() => _showResults = true); },
      );
}

/// Letter rail on the right of the artists list: 26 taps, each >= 24 px tall, jumps the list.
class _AlphabetRail extends StatelessWidget {
  const _AlphabetRail({required this.letters, required this.onJump});
  final Map<String, int> letters;
  final void Function(int index) onJump;

  @override
  Widget build(BuildContext context) {
    final keys = letters.keys.toList()..sort();
    return SizedBox(
      width: 56,
      child: LayoutBuilder(
        builder: (_, c) {
          final h = (c.maxHeight / keys.length).clamp(24.0, 48.0);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              final i = (d.localPosition.dy / h).floor().clamp(0, keys.length - 1);
              onJump(letters[keys[i]]!);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final k in keys)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onJump(letters[k]!),
                    child: SizedBox(height: h, width: 56, child: Center(child: Text(k, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: T.mute)))),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({required this.coverUrl, required this.onPlayAll, required this.onShuffle});
  final String? coverUrl;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: T.rowH,
      child: Row(
        children: [
          SizedBox(width: 112, height: 112, child: ClipRRect(borderRadius: BorderRadius.circular(20), child: Cover(coverUrl))),
          const SizedBox(width: 22),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPlayAll,
              child: Container(
                height: T.rowH,
                decoration: BoxDecoration(color: T.gold, borderRadius: BorderRadius.circular(24)),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.play_arrow_rounded, size: 48, color: T.inkOnAccent), SizedBox(width: 8), Text('Play all', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: T.inkOnAccent))]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onShuffle,
            child: Container(
              width: 140,
              height: T.rowH,
              decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0x33FFFFFF), width: 2)),
              child: const Icon(Icons.shuffle_rounded, size: 48, color: T.fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _RotatingIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;
  const _RotatingIcon({required this.icon, required this.color, required this.size});

  @override
  State<_RotatingIcon> createState() => _RotatingIconState();
}

class _RotatingIconState extends State<_RotatingIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: Icon(widget.icon, size: widget.size, color: widget.color),
    );
  }
}
