import 'dart:async';

final class AutoCdnRecovery {
  AutoCdnRecovery({
    required this.canRecover,
    required this.recoverNext,
    this.onRoundEnd,
    this.stallDelay = const Duration(milliseconds: 2500),
    this.retryDelay = const Duration(seconds: 5),
  });

  final bool Function() canRecover;
  final Future<bool> Function() recoverNext;
  final void Function()? onRoundEnd;
  final Duration stallDelay;
  final Duration retryDelay;

  Timer? _timer;
  Timer? _finishTimer;
  Duration _position = Duration.zero;
  bool _buffering = false;
  bool _recovering = false;
  bool _hasRecovered = false;
  int _generation = 0;

  void onBufferingChanged(bool buffering) {
    _buffering = buffering;
    if (!buffering) {
      _timer?.cancel();
      if (!_recovering) {
        if (_hasRecovered) {
          _finishTimer?.cancel();
          _finishTimer = Timer(retryDelay, _finishRound);
        } else {
          _finishRound();
        }
      }
      return;
    }
    _finishTimer?.cancel();
    _schedule();
  }

  void onPositionChanged(Duration position) {
    if (position == _position) return;
    _position = position;
    if (_buffering && !_recovering) _schedule();
  }

  void onEligibilityChanged() {
    if (!_buffering || !canRecover()) {
      _timer?.cancel();
      return;
    }
    _schedule();
  }

  void reset() {
    _generation++;
    _timer?.cancel();
    _finishTimer?.cancel();
    _timer = null;
    _finishTimer = null;
    _buffering = false;
    _recovering = false;
    _finishRound();
  }

  void dispose() => reset();

  void _schedule() {
    _timer?.cancel();
    if (_recovering || !_buffering || !canRecover()) return;
    final generation = _generation;
    final position = _position;
    _timer = Timer(_hasRecovered ? retryDelay : stallDelay, () async {
      if (generation != _generation || !_buffering || !canRecover()) {
        return;
      }
      if (position != _position) {
        _schedule();
        return;
      }

      _recovering = true;
      var recovered = false;
      try {
        recovered = await recoverNext();
      } catch (_) {}
      if (generation != _generation) return;
      _recovering = false;
      if (!recovered) {
        _timer = null;
        return;
      }
      _hasRecovered = true;
      if (_buffering && canRecover()) {
        _schedule();
      } else {
        _finishTimer?.cancel();
        _finishTimer = Timer(retryDelay, _finishRound);
      }
    });
  }

  void _finishRound() {
    _finishTimer?.cancel();
    _finishTimer = null;
    onRoundEnd?.call();
    _hasRecovered = false;
  }
}
