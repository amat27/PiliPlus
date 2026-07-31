// ignore_for_file: cascade_invocations

import 'dart:async';

import 'package:PiliPlus/services/auto_cdn_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('player error classification', () {
    const mediaHosts = {'video.example.com', 'audio.example.com'};

    test('accepts media network failures', () {
      expect(
        AutoCdnRecovery.isRecoverablePlayerError(
          'tcp: ffurl_read returned 0xffffffc7',
          mediaHosts: mediaHosts,
          hasPendingSeek: false,
        ),
        isTrue,
      );
      expect(
        AutoCdnRecovery.isRecoverablePlayerError(
          'tcp: Connection to tcp://audio.example.com:443 failed: timeout',
          mediaHosts: mediaHosts,
          hasPendingSeek: false,
        ),
        isTrue,
      );
    });

    test('retries current source for the first transition error', () {
      expect(
        AutoCdnRecovery.classifyPlayerError(
          'tcp: ffurl_read returned 0xffffffc7',
          mediaHosts: mediaHosts,
          hasPendingSeek: false,
          inSourceTransition: true,
          transitionRetryUsed: false,
        ),
        AutoCdnPlayerErrorAction.retryCurrent,
      );
      expect(
        AutoCdnRecovery.classifyPlayerError(
          'tcp: ffurl_read returned 0xffffffc7',
          mediaHosts: mediaHosts,
          hasPendingSeek: false,
          inSourceTransition: true,
          transitionRetryUsed: true,
        ),
        AutoCdnPlayerErrorAction.recoverNext,
      );
    });

    test('rejects external file failures from unrelated hosts', () {
      expect(
        AutoCdnRecovery.isRecoverablePlayerError(
          'Can not open external file https://subtitle.example.com/a.vtt',
          mediaHosts: mediaHosts,
          hasPendingSeek: false,
        ),
        isFalse,
      );
    });

    test('accepts seek failures only while a seek target is pending', () {
      expect(
        AutoCdnRecovery.isRecoverablePlayerError(
          'Seek failed (to 123, size 456)',
          mediaHosts: mediaHosts,
          hasPendingSeek: true,
        ),
        isTrue,
      );
      expect(
        AutoCdnRecovery.isRecoverablePlayerError(
          'Seek failed (to 123, size 456)',
          mediaHosts: mediaHosts,
          hasPendingSeek: false,
        ),
        isFalse,
      );
    });
  });

  testWidgets('requires continuous buffering for the stall threshold', (
    tester,
  ) async {
    var recoveries = 0;
    var stalls = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      onStall: () => stalls++,
      recoverNext: () async {
        recoveries++;
        return false;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2499));
    expect(recoveries, 0);
    expect(stalls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(recoveries, 1);
    expect(stalls, 1);
    recovery.dispose();
  });

  testWidgets('position progress restarts the stall threshold', (tester) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return false;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 2));
    recovery.onPositionChanged(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    expect(recoveries, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(recoveries, 1);
    recovery.dispose();
  });

  testWidgets('pause or background eligibility prevents recovery', (
    tester,
  ) async {
    var eligible = true;
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => eligible,
      recoverNext: () async {
        recoveries++;
        return false;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 2));
    eligible = false;
    recovery.onEligibilityChanged();
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 0);

    eligible = true;
    recovery.onEligibilityChanged();
    await tester.pump(const Duration(milliseconds: 2500));
    expect(recoveries, 1);
    recovery.dispose();
  });

  testWidgets('persistent buffering retries after five seconds', (
    tester,
  ) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return true;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(recoveries, 1);
    await tester.pump(const Duration(milliseconds: 4999));
    expect(recoveries, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(recoveries, 2);
    recovery.dispose();
  });

  testWidgets('buffer recovery and reset cancel pending retries', (
    tester,
  ) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return true;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2500));
    recovery.onBufferingChanged(false);
    await tester.pump(const Duration(seconds: 5));
    expect(recoveries, 1);

    recovery
      ..onBufferingChanged(true)
      ..reset();
    await tester.pump(const Duration(milliseconds: 2500));
    expect(recoveries, 1);
  });

  testWidgets('reset invalidates an in-flight recovery', (tester) async {
    final pending = Completer<bool>();
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () {
        recoveries++;
        return pending.future;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(recoveries, 1);
    recovery.reset();
    pending.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(recoveries, 1);
  });

  testWidgets('player network error recovers without buffering', (
    tester,
  ) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return true;
      },
    );

    recovery.onPlayerError();
    await tester.pump(const Duration(milliseconds: 999));
    expect(recoveries, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(recoveries, 1);
    recovery.dispose();
  });

  testWidgets('repeated player errors are coalesced without delaying recovery', (
    tester,
  ) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return false;
      },
    );

    recovery.onPlayerError();
    await tester.pump(const Duration(milliseconds: 500));
    recovery.onPlayerError();
    await tester.pump(const Duration(milliseconds: 499));
    expect(recoveries, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(recoveries, 1);
    recovery.dispose();
  });

  testWidgets('player error waits until recovery becomes eligible', (
    tester,
  ) async {
    var eligible = false;
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => eligible,
      recoverNext: () async {
        recoveries++;
        return false;
      },
    );

    recovery.onPlayerError();
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 0);

    eligible = true;
    recovery.onEligibilityChanged();
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 1);
    recovery.dispose();
  });

  testWidgets('player error during recovery schedules another attempt', (
    tester,
  ) async {
    final firstAttempt = Completer<bool>();
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () {
        recoveries++;
        return recoveries == 1 ? firstAttempt.future : Future.value(false);
      },
    );

    recovery.onPlayerError();
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 1);
    recovery.onPlayerError();
    firstAttempt.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 2);
    recovery.dispose();
  });

  testWidgets('buffering and player errors never recover concurrently', (
    tester,
  ) async {
    final attempt = Completer<bool>();
    var activeRecoveries = 0;
    var maxActiveRecoveries = 0;
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        activeRecoveries++;
        maxActiveRecoveries = activeRecoveries > maxActiveRecoveries
            ? activeRecoveries
            : maxActiveRecoveries;
        final result = await attempt.future;
        activeRecoveries--;
        return result;
      },
    );

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2500));
    recovery.onPlayerError();
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 1);
    expect(maxActiveRecoveries, 1);

    attempt.complete(false);
    await tester.pump();
    recovery.dispose();
  });

  testWidgets('a queued player error can be cancelled by token', (
    tester,
  ) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return false;
      },
    );

    final token = recovery.onPlayerError();
    recovery.cancelPlayerError(token);
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 0);
    recovery.dispose();
  });

  testWidgets('starting buffering recovery consumes an older queued error', (
    tester,
  ) async {
    var recoveries = 0;
    final recovery = AutoCdnRecovery(
      canRecover: () => true,
      recoverNext: () async {
        recoveries++;
        return true;
      },
    );

    recovery.onPlayerError();
    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(recoveries, 1);
    recovery.onBufferingChanged(false);
    await tester.pump(const Duration(seconds: 1));
    expect(recoveries, 1);
    recovery.dispose();
  });
}
