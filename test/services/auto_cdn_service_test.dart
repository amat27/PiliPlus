import 'dart:async';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/services/auto_cdn_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sample =
      'http://origin.example.com:8080/upgcxcode/test.m4s?deadline=1&token=x';

  test('uses the media request headers required by Bilibili CDNs', () {
    expect(AutoCdnService.probeHeaders['User-Agent'], isNotEmpty);
    expect(
      AutoCdnService.probeHeaders['Referer'],
      'https://www.bilibili.com',
    );
  });

  test('formats known and unknown CDN host labels', () {
    expect(
      AutoCdnService.hostLabel('upos-tf-all-tx.bilivideo.com'),
      'tf_tx',
    );
    expect(AutoCdnService.hostLabel('example.com'), 'example.com');
    expect(AutoCdnService.hostLabel(null), '未知');
  });

  test(
    'sorts successful probes by TTFB and preserves the signed URL',
    () async {
      final timings = <String, int>{
        AutoCdnService.candidateHosts[0]: 80,
        AutoCdnService.candidateHosts[1]: 20,
        AutoCdnService.candidateHosts[2]: 50,
      };
      final probed = <Uri>[];
      final service = AutoCdnService(
        probe: (uri) async {
          probed.add(uri);
          return timings[uri.host];
        },
        cacheScope: () => 'scope',
      );

      final selection = await service.ensureSelected([sample]);

      expect(probed, hasLength(AutoCdnService.candidateHosts.length));
      expect(
        probed,
        everyElement(
          isA<Uri>()
              .having((uri) => uri.scheme, 'scheme', 'https')
              .having((uri) => uri.path, 'path', '/upgcxcode/test.m4s')
              .having((uri) => uri.query, 'query', 'deadline=1&token=x'),
        ),
      );
      expect(selection?.ranking, [
        AutoCdnService.candidateHosts[1],
        AutoCdnService.candidateHosts[2],
        AutoCdnService.candidateHosts[0],
      ]);
    },
  );

  test('deduplicates concurrent probes', () async {
    final completers = <String, Completer<int?>>{};
    var calls = 0;
    final service = AutoCdnService(
      probe: (uri) {
        calls++;
        return (completers[uri.host] ??= Completer<int?>()).future;
      },
      cacheScope: () => 'scope',
    );

    final first = service.ensureSelected([sample]);
    final second = service.ensureSelected([sample]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, AutoCdnService.candidateHosts.length);
    for (final entry in completers.entries) {
      entry.value.complete(
        AutoCdnService.candidateHosts.indexOf(entry.key) + 1,
      );
    }

    expect((await first)?.ranking, (await second)?.ranking);
    expect(calls, AutoCdnService.candidateHosts.length);
  });

  test('uses a valid six-hour cache without probing', () async {
    final now = DateTime(2026, 7, 23, 12);
    var calls = 0;
    final service = AutoCdnService(
      probe: (_) async {
        calls++;
        return 1;
      },
      readCache: () => {
        'scope': 'scope',
        'network': '',
        'measuredAt': now
            .subtract(const Duration(hours: 5))
            .millisecondsSinceEpoch,
        'ranking': [AutoCdnService.candidateHosts.last],
        'timings': {AutoCdnService.candidateHosts.last: 12},
      },
      now: () => now,
      cacheScope: () => 'scope',
    );

    final selection = await service.ensureSelected([sample]);

    expect(selection?.selectedHost, AutoCdnService.candidateHosts.last);
    expect(calls, 0);
  });

  test('reprobes an expired cache and ignores cache write failures', () async {
    final now = DateTime(2026, 7, 23, 12);
    var calls = 0;
    final service = AutoCdnService(
      probe: (uri) async {
        calls++;
        return uri.host == AutoCdnService.candidateHosts.first ? 7 : null;
      },
      readCache: () => {
        'scope': 'scope',
        'network': '',
        'measuredAt': now
            .subtract(const Duration(hours: 6))
            .millisecondsSinceEpoch,
        'ranking': [AutoCdnService.candidateHosts.last],
        'timings': {AutoCdnService.candidateHosts.last: 1},
      },
      writeCache: (_) => throw StateError('storage unavailable'),
      now: () => now,
      cacheScope: () => 'scope',
    );

    final selection = await service.ensureSelected([sample]);

    expect(selection?.selectedHost, AutoCdnService.candidateHosts.first);
    expect(calls, AutoCdnService.candidateHosts.length);
  });

  test('expires an in-memory selection after six hours', () async {
    var now = DateTime(2026, 7, 23, 12);
    var calls = 0;
    final service = AutoCdnService(
      probe: (_) async => ++calls,
      now: () => now,
      cacheScope: () => 'scope',
    );

    await service.ensureSelected([sample]);
    expect(calls, AutoCdnService.candidateHosts.length);

    now = now.add(const Duration(hours: 6));
    await service.ensureSelected([sample]);
    expect(calls, AutoCdnService.candidateHosts.length * 2);
  });

  test('starts a fresh probe after invalidation', () async {
    final probes = <Completer<int?>>[];
    var calls = 0;
    final service = AutoCdnService(
      probe: (_) {
        calls++;
        final completer = Completer<int?>();
        probes.add(completer);
        return completer.future;
      },
      cacheScope: () => 'scope',
    );

    final first = service.ensureSelected([sample]);
    await Future<void>.delayed(Duration.zero);
    service.invalidate();
    final second = service.ensureSelected([sample]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, AutoCdnService.candidateHosts.length * 2);

    for (final completer in probes) {
      completer.complete(1);
    }
    expect(await first, isNull);
    expect(
      (await second)?.ranking,
      hasLength(AutoCdnService.candidateHosts.length),
    );
  });

  test('returns null when every probe fails', () async {
    final service = AutoCdnService(
      probe: (_) async => null,
      cacheScope: () => 'scope',
    );

    expect(await service.ensureSelected([sample]), isNull);
    expect(service.selectedHost, isNull);
  });

  test('times out slow probes and keeps successful hosts', () async {
    final service = AutoCdnService(
      probe: (uri) async {
        if (uri.host == AutoCdnService.candidateHosts.first) return 5;
        await Future<void>.delayed(const Duration(seconds: 1));
        return 10;
      },
      cacheScope: () => 'scope',
      probeTimeout: const Duration(milliseconds: 10),
    );

    final selection = await service.ensureSelected([sample]);

    expect(selection?.ranking, [AutoCdnService.candidateHosts.first]);
  });

  test('rotation does not reuse a host in the same round', () async {
    final service = AutoCdnService(
      probe: (uri) async => AutoCdnService.candidateHosts.indexOf(uri.host) + 1,
      cacheScope: () => 'scope',
    );
    await service.ensureSelected([sample]);
    final first = service.selectedHost;
    final tried = <String>{?first};

    final second = service.nextRecoveryHost(first, tried);
    tried.add(second!);
    final third = service.nextRecoveryHost(second, tried);

    expect(second, isNot(first));
    expect(third, isNot(anyOf(first, second)));
  });

  test('avoids a failed host for fifteen seconds', () async {
    var now = DateTime(2026, 7, 23, 12);
    final service = AutoCdnService(
      probe: (uri) async => AutoCdnService.candidateHosts.indexOf(uri.host) + 1,
      now: () => now,
      cacheScope: () => 'scope',
    );
    await service.ensureSelected([sample]);
    final failed = AutoCdnService.candidateHosts[1];
    service.avoidHost(failed);

    expect(service.nextRecoveryHost(service.selectedHost, {}), isNot(failed));
    now = now.add(const Duration(seconds: 15));
    expect(service.nextRecoveryHost(service.selectedHost, {}), failed);
  });

  test('parses existing settings by enum name and defaults to auto', () {
    expect(parseCDNService('tf_tx'), CDNService.tf_tx);
    expect(parseCDNService('backupUrl'), CDNService.backupUrl);
    expect(parseCDNService(null), CDNService.auto);
    expect(parseCDNService('removed-value'), CDNService.auto);
  });
}
