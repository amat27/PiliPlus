enum VideoResumeSource { start, explicit, server, local }

extension VideoResumeSourceExt on VideoResumeSource {
  String get label => switch (this) {
    VideoResumeSource.start => '从头播放',
    VideoResumeSource.explicit => '指定进度续播',
    VideoResumeSource.server => '服务器进度续播',
    VideoResumeSource.local => '本地进度续播',
  };
}

abstract final class VideoResumeService {
  static ({Duration position, VideoResumeSource source}) resolve({
    required int serverProgress,
    int? explicitProgress,
    int? localProgress,
    int? duration,
  }) {
    bool inRange(int progress, {bool allowZero = false}) =>
        (allowZero ? progress >= 0 : progress > 0) &&
        (duration == null || progress < duration);

    if (explicitProgress != null &&
        inRange(explicitProgress, allowZero: true)) {
      return (
        position: Duration(milliseconds: explicitProgress),
        source: VideoResumeSource.explicit,
      );
    }
    if (serverProgress > 0) {
      return (
        position: Duration(
          milliseconds: inRange(serverProgress) ? serverProgress : 0,
        ),
        source: inRange(serverProgress)
            ? VideoResumeSource.server
            : VideoResumeSource.start,
      );
    }
    if (serverProgress == 0 &&
        localProgress != null &&
        inRange(localProgress) &&
        (duration == null || localProgress < duration - 1000)) {
      return (
        position: Duration(milliseconds: localProgress),
        source: VideoResumeSource.local,
      );
    }
    return (position: Duration.zero, source: VideoResumeSource.start);
  }

  static bool reachedTarget(
    Duration position,
    Duration target, {
    Duration tolerance = const Duration(seconds: 3),
  }) => (position - target).abs() <= tolerance;
}

final class VideoResumeTarget {
  Duration? _target;
  bool _hasTarget = false;
  bool _acceptPosition = true;

  Duration? get target => _hasTarget ? _target : null;

  void update(Duration target) {
    _target = target < Duration.zero ? Duration.zero : target;
    _hasTarget = true;
    _acceptPosition = true;
  }

  void beginMediaOpen() {
    if (_hasTarget) _acceptPosition = false;
  }

  void mediaOpened() {
    _acceptPosition = true;
  }

  bool acceptPosition(Duration position) {
    if (!_hasTarget) return true;
    final target = _target!;
    if (!_acceptPosition || !VideoResumeService.reachedTarget(position, target)) {
      return false;
    }
    clear();
    return true;
  }

  void clear() {
    _target = null;
    _hasTarget = false;
    _acceptPosition = true;
  }
}
