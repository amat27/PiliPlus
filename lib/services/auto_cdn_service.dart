import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

typedef AutoCdnProbe = Future<int?> Function(Uri uri);
typedef AutoCdnCacheReader = Map? Function();
typedef AutoCdnCacheWriter = FutureOr<void> Function(Map<String, Object> value);
typedef AutoCdnCacheClearer = FutureOr<void> Function();
typedef AutoCdnNetworkScope = Future<String> Function();

final class AutoCdnSelection {
  const AutoCdnSelection({
    required this.ranking,
    required this.timings,
    required this.measuredAt,
  });

  final List<String> ranking;
  final Map<String, int> timings;
  final DateTime measuredAt;

  String get selectedHost => ranking.first;
}

final class AutoCdnService {
  factory AutoCdnService({
    AutoCdnProbe? probe,
    AutoCdnCacheReader? readCache,
    AutoCdnCacheWriter? writeCache,
    AutoCdnCacheClearer? clearCache,
    DateTime Function()? now,
    String Function()? cacheScope,
    AutoCdnNetworkScope? networkScope,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration cacheDuration = const Duration(hours: 6),
    bool watchConnectivity = false,
  }) {
    return AutoCdnService._(
      probe: probe,
      readCache: readCache,
      writeCache: writeCache,
      clearCache: clearCache,
      now: now ?? DateTime.now,
      cacheScope: cacheScope ?? _defaultCacheScope,
      networkScope: networkScope ?? _emptyNetworkScope,
      probeTimeout: probeTimeout,
      cacheDuration: cacheDuration,
      watchConnectivity: watchConnectivity,
    );
  }

  AutoCdnService._({
    required this._probe,
    required this._readCache,
    required this._writeCache,
    required this._clearCache,
    required this._now,
    required this._cacheScope,
    required this._networkScope,
    required this.probeTimeout,
    required this.cacheDuration,
    required bool watchConnectivity,
  }) {
    if (watchConnectivity) {
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
        _onConnectivityChanged,
      );
    }
  }

  static final instance = AutoCdnService(
    readCache: () =>
        GStorage.setting.get(SettingBoxKey.autoCDNSelection) as Map?,
    writeCache: (value) =>
        GStorage.setting.put(SettingBoxKey.autoCDNSelection, value),
    clearCache: () => GStorage.setting.delete(SettingBoxKey.autoCDNSelection),
    networkScope: _defaultNetworkScope,
    watchConnectivity: true,
  );

  static const candidateHosts = <String>[
    'upos-sz-mirrorcos.bilivideo.com',
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-tf-all-hw.bilivideo.com',
    'upos-tf-all-tx.bilivideo.com',
  ];

  static const probeHeaders = {
    'User-Agent': BrowserUa.pc,
    'Referer': HttpString.baseUrl,
  };

  final AutoCdnProbe? _probe;
  final AutoCdnCacheReader? _readCache;
  final AutoCdnCacheWriter? _writeCache;
  final AutoCdnCacheClearer? _clearCache;
  final DateTime Function() _now;
  final String Function() _cacheScope;
  final AutoCdnNetworkScope _networkScope;
  final Duration probeTimeout;
  final Duration cacheDuration;

  AutoCdnSelection? _selection;
  Future<AutoCdnSelection?>? _pending;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  final Map<String, DateTime> _avoidUntil = {};
  String? _network;
  bool _hasConnectivityEvent = false;
  int _generation = 0;

  AutoCdnSelection? get selection {
    final current = _selection;
    if (current != null) {
      if (_now().difference(current.measuredAt) < cacheDuration) return current;
      _selection = null;
    }
    return _network == null ? null : _readValidCache();
  }

  String? get selectedHost {
    final current = selection;
    if (current == null) return null;
    final now = _now();
    return current.ranking.firstWhere(
      (host) => !(_avoidUntil[host]?.isAfter(now) ?? false),
      orElse: () => current.selectedHost,
    );
  }

  Map<String, int> get timings => selection?.timings ?? const {};

  String get label {
    final selection = this.selection;
    if (selection == null) return '自动';
    final host = selectedHost ?? selection.selectedHost;
    return '自动（当前：${hostLabel(host)}，${selection.timings[host]} ms）';
  }

  static String hostLabel(String? host) {
    if (host == null || host.isEmpty) return '未知';
    for (final service in CDNService.values) {
      if (service.host == host) return service.name;
    }
    return host;
  }

  Future<AutoCdnSelection?> ensureSelected(Iterable<String> urls) {
    if (_pending case final pending?) return pending;

    final sample = _findSample(urls);
    if (sample == null) return Future.value(null);

    final pending = _ensureSelected(sample, _generation);
    _pending = pending;
    return pending.whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
    });
  }

  Future<AutoCdnSelection?> _ensureSelected(Uri sample, int generation) async {
    final network = await _networkScope();
    if (generation != _generation) return null;
    var measureGeneration = generation;
    if (_network != null && _network != network) {
      invalidate();
      measureGeneration = _generation;
    }
    _network = network;
    final current = selection;
    if (current != null) return current;
    return _measure(sample, measureGeneration);
  }

  List<String> get recoveryHosts {
    return selection?.ranking ?? const <String>[];
  }

  String? nextRecoveryHost(String? currentHost, Set<String> triedHosts) {
    final now = _now();
    for (final host in recoveryHosts) {
      if (host != currentHost &&
          !triedHosts.contains(host) &&
          !(_avoidUntil[host]?.isAfter(now) ?? false)) {
        return host;
      }
    }
    return null;
  }

  void avoidHost(
    String host, [
    Duration duration = const Duration(seconds: 15),
  ]) {
    _avoidUntil[host] = _now().add(duration);
  }

  void invalidate() {
    _generation++;
    _selection = null;
    _pending = null;
    _avoidUntil.clear();
    unawaited(_clearPersistedCache());
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final network = _connectivityScope(results);
    if (_hasConnectivityEvent) {
      invalidate();
    }
    _hasConnectivityEvent = true;
    _network = network;
  }

  Future<void> _clearPersistedCache() async {
    try {
      await _clearCache?.call();
    } catch (_) {}
  }

  void dispose() {
    _connectivitySubscription?.cancel();
  }

  Future<AutoCdnSelection?> _measure(Uri sample, int generation) async {
    final samples = await Future.wait(
      candidateHosts.map((host) async {
        final uri = sample.replace(scheme: 'https', host: host, port: 443);
        try {
          final timing = await (_probe?.call(uri) ?? _probeHost(uri)).timeout(
            probeTimeout,
          );
          return timing == null ? null : (host: host, timing: timing);
        } catch (_) {
          return null;
        }
      }),
    );
    if (generation != _generation) return null;

    final successful = samples.nonNulls.toList()
      ..sort((a, b) => a.timing.compareTo(b.timing));
    if (successful.isEmpty) return null;

    final selection = AutoCdnSelection(
      ranking: successful.map((item) => item.host).toList(growable: false),
      timings: {for (final item in successful) item.host: item.timing},
      measuredAt: _now(),
    );
    _selection = selection;
    try {
      await _writeCache?.call({
        'scope': _cacheScope(),
        'network': _network ?? '',
        'measuredAt': selection.measuredAt.millisecondsSinceEpoch,
        'ranking': selection.ranking,
        'timings': selection.timings,
      });
    } catch (_) {}
    return selection;
  }

  Future<int?> _probeHost(Uri uri) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: probeTimeout,
        receiveTimeout: probeTimeout,
        headers: probeHeaders,
        responseType: ResponseType.stream,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final token = CancelToken();
    final stopwatch = Stopwatch()..start();
    try {
      final response = await dio.getUri<ResponseBody>(uri, cancelToken: token);
      final elapsed = stopwatch.elapsedMilliseconds;
      await response.data?.stream.listen(null).cancel();
      return elapsed;
    } finally {
      token.cancel();
      dio.close(force: true);
    }
  }

  AutoCdnSelection? _readValidCache() {
    Map? raw;
    try {
      raw = _readCache?.call();
    } catch (_) {
      return null;
    }
    if (raw == null ||
        raw['scope'] != _cacheScope() ||
        raw['network'] != _network) {
      return null;
    }
    final measuredAtValue = raw['measuredAt'];
    final rankingValue = raw['ranking'];
    final timingsValue = raw['timings'];
    if (measuredAtValue is! int ||
        rankingValue is! List ||
        timingsValue is! Map) {
      return null;
    }
    final measuredAt = DateTime.fromMillisecondsSinceEpoch(measuredAtValue);
    if (_now().difference(measuredAt) >= cacheDuration) return null;

    final ranking = rankingValue.whereType<String>().toList(growable: false);
    final timings = <String, int>{
      for (final entry in timingsValue.entries)
        if (entry.key is String && entry.value is int)
          entry.key as String: entry.value as int,
    };
    if (ranking.isEmpty || !ranking.every(timings.containsKey)) return null;
    return _selection = AutoCdnSelection(
      ranking: ranking,
      timings: timings,
      measuredAt: measuredAt,
    );
  }

  static Uri? _findSample(Iterable<String> urls) {
    Uri? fallback;
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        if (uri.path.contains('/upgcxcode/')) return uri;
        fallback ??= uri;
      }
    }
    return fallback;
  }

  static String _defaultCacheScope() {
    final now = DateTime.now();
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    return '${now.timeZoneName}|${now.timeZoneOffset.inMinutes}|$locale';
  }

  static Future<String> _defaultNetworkScope() async {
    return _connectivityScope(await Connectivity().checkConnectivity());
  }

  static Future<String> _emptyNetworkScope() async => '';

  static String _connectivityScope(List<ConnectivityResult> results) {
    final names = results.map((item) => item.name).toList()..sort();
    return names.join(',');
  }
}
