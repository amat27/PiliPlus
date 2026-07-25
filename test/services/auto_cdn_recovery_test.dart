// ignore_for_file: cascade_invocations

import 'dart:async';

import 'package:PiliPlus/services/auto_cdn_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('requires continuous buffering for the stall threshold', (
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

    recovery.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 2499));
    expect(recoveries, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(recoveries, 1);
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
}
