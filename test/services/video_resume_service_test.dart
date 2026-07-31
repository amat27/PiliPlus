import 'package:PiliPlus/services/video_resume_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolve', () {
    test('explicit progress has priority', () {
      final result = VideoResumeService.resolve(
        explicitProgress: 3000,
        serverProgress: 2000,
        localProgress: 1000,
        duration: 10000,
      );

      expect(result.position, const Duration(seconds: 3));
      expect(result.source, VideoResumeSource.explicit);
    });

    test('invalid explicit progress falls back to server', () {
      final result = VideoResumeService.resolve(
        explicitProgress: 11000,
        serverProgress: 2000,
        localProgress: 1000,
        duration: 10000,
      );

      expect(result.position, const Duration(seconds: 2));
      expect(result.source, VideoResumeSource.server);
    });

    test('local progress is used only when server returns zero', () {
      final local = VideoResumeService.resolve(
        serverProgress: 0,
        localProgress: 4000,
        duration: 10000,
      );
      final server = VideoResumeService.resolve(
        serverProgress: 2000,
        localProgress: 4000,
        duration: 10000,
      );

      expect(local.position, const Duration(seconds: 4));
      expect(local.source, VideoResumeSource.local);
      expect(server.position, const Duration(seconds: 2));
      expect(server.source, VideoResumeSource.server);
    });

    test('out of range server progress starts from zero', () {
      final result = VideoResumeService.resolve(
        serverProgress: 10000,
        localProgress: 4000,
        duration: 10000,
      );

      expect(result.position, Duration.zero);
      expect(result.source, VideoResumeSource.start);
    });

    test('nearly completed local progress starts from zero', () {
      final result = VideoResumeService.resolve(
        serverProgress: 0,
        localProgress: 9500,
        duration: 10000,
      );

      expect(result.position, Duration.zero);
      expect(result.source, VideoResumeSource.start);
    });
  });

  group('reachedTarget', () {
    test('accepts only positions close to the target', () {
      const target = Duration(seconds: 30);

      expect(
        VideoResumeService.reachedTarget(const Duration(seconds: 27), target),
        isTrue,
      );
      expect(
        VideoResumeService.reachedTarget(const Duration(seconds: 33), target),
        isTrue,
      );
      expect(
        VideoResumeService.reachedTarget(const Duration(seconds: 10), target),
        isFalse,
      );
      expect(
        VideoResumeService.reachedTarget(const Duration(seconds: 50), target),
        isFalse,
      );
    });
  });

  group('VideoResumeTarget', () {
    test('rejects stale positions while media is opening', () {
      final target = VideoResumeTarget()
        ..update(const Duration(seconds: 30))
        ..beginMediaOpen();

      expect(target.acceptPosition(const Duration(seconds: 30)), isFalse);
      expect(target.target, const Duration(seconds: 30));

      target.mediaOpened();
      expect(target.acceptPosition(const Duration(seconds: 30)), isTrue);
      expect(target.target, isNull);
    });

    test('does not clear target on low or stale high positions', () {
      final target = VideoResumeTarget()..update(const Duration(seconds: 30));

      expect(target.acceptPosition(const Duration(seconds: 1)), isFalse);
      expect(target.acceptPosition(const Duration(seconds: 50)), isFalse);
      expect(target.target, const Duration(seconds: 30));
    });

    test('a backward seek replaces the previous target', () {
      final target = VideoResumeTarget()
        ..update(const Duration(seconds: 50))
        ..update(const Duration(seconds: 10));

      expect(target.acceptPosition(const Duration(seconds: 50)), isFalse);
      expect(target.acceptPosition(const Duration(seconds: 10)), isTrue);
    });

    test('zero is a protected seek target', () {
      final target = VideoResumeTarget()
        ..update(Duration.zero)
        ..beginMediaOpen();

      expect(target.target, Duration.zero);
      expect(target.acceptPosition(Duration.zero), isFalse);
      target.mediaOpened();
      expect(target.acceptPosition(const Duration(seconds: 20)), isFalse);
      expect(target.acceptPosition(Duration.zero), isTrue);
      expect(target.target, isNull);
    });

    test('zero target remains available for media reopening', () {
      final target = VideoResumeTarget()..update(Duration.zero);

      expect(target.target, isNotNull);
      expect(target.target, Duration.zero);
      target
        ..beginMediaOpen()
        ..mediaOpened();
      expect(target.acceptPosition(Duration.zero), isTrue);
    });
  });
}
