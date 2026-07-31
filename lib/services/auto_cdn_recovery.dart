import 'dart:async';

enum AutoCdnPlayerErrorAction { none, retryCurrent, recoverNext }

final class AutoCdnRecovery {
  AutoCdnRecovery({
    required this.canRecover,
    required this.recoverNext,
    this.onStall,
    this.onRoundEnd,
    this.stallDelay = const Duration(milliseconds: 2500),
    this.retryDelay = const Duration(seconds: 5),
    this.errorDelay = const Duration(seconds: 1),
  });

  final bool Function() canRecover;
  final Future<bool> Function() recoverNext;
  final void Function()? onStall;
  final void Function()? onRoundEnd;
  final Duration stallDelay;
  final Duration retryDelay;
  final Duration errorDelay;

  static AutoCdnPlayerErrorAction classifyPlayerError(
    String error, {
    required Set<String> mediaHosts,
    required bool hasPendingSeek,
    required bool inSourceTransition,
    required bool transitionRetryUsed,
  }) {
    if (isHostlessPlayerError(error) && inSourceTransition) {
      return transitionRetryUsed
          ? AutoCdnPlayerErrorAction.recoverNext
          : AutoCdnPlayerErrorAction.retryCurrent;
    }
    return isRecoverablePlayerError(
          error,
          mediaHosts: mediaHosts,
          hasPendingSeek: hasPendingSeek,
        )
        ? AutoCdnPlayerErrorAction.recoverNext
        : AutoCdnPlayerErrorAction.none;
  }

  static bool isHostlessPlayerError(String error) =>
      error.startsWith('tcp: ffurl_read returned ') ||
      error.startsWith('https: Stream ends prematurely') ||
      error.startsWith('tls: mbedtls_ssl_read returned ');

  static bool isRecoverablePlayerError(
    String error, {
    required Set<String> mediaHosts,
    required bool hasPendingSeek,
  }) {
    if (isHostlessPlayerError(error)) return true;
    if (error.startsWith('Seek failed (')) return hasPendingSeek;
    if (!error.startsWith('Failed to open https://') &&
        !error.startsWith('Can not open external file https://') &&
        !error.startsWith('tcp: Connection to tcp://')) {
      return false;
    }
    final match = RegExp(r'(?:https|tcp)://([^/:\s]+)').firstMatch(error);
    return match != null && mediaHosts.contains(match.group(1));
  }

  Timer? _timer;
  Timer? _finishTimer;
  Timer? _errorTimer;
  Duration _position = Duration.zero;
  bool _buffering = false;
  bool _recovering = false;
  bool _hasRecovered = false;
  bool _playerErrorPending = false;
  int _playerErrorToken = 0;
  int? _pendingPlayerErrorToken;
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
    if (_playerErrorPending) _schedulePlayerError();
    if (!_buffering || !canRecover()) {
      _timer?.cancel();
      return;
    }
    _schedule();
  }

  int onPlayerError() {
    final token = ++_playerErrorToken;
    _playerErrorPending = true;
    _pendingPlayerErrorToken = token;
    if (_recovering) return token;
    _schedulePlayerError();
    return token;
  }

  void cancelPlayerError(int token) {
    if (_pendingPlayerErrorToken != token) return;
    _errorTimer?.cancel();
    _errorTimer = null;
    _playerErrorPending = false;
    _pendingPlayerErrorToken = null;
  }

  void _schedulePlayerError() {
    if (_errorTimer != null || !_playerErrorPending) return;
    final generation = _generation;
    _errorTimer = Timer(errorDelay, () {
      _errorTimer = null;
      if (generation != _generation || _recovering || !canRecover()) return;
      _playerErrorPending = false;
      _pendingPlayerErrorToken = null;
      _timer?.cancel();
      unawaited(_attemptRecovery(generation));
    });
  }

  void reset() {
    _generation++;
    _timer?.cancel();
    _finishTimer?.cancel();
    _errorTimer?.cancel();
    _timer = null;
    _finishTimer = null;
    _errorTimer = null;
    _buffering = false;
    _recovering = false;
    _playerErrorPending = false;
    _pendingPlayerErrorToken = null;
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

      onStall?.call();
      await _attemptRecovery(generation);
    });
  }

  Future<void> _attemptRecovery(int generation) async {
    _errorTimer?.cancel();
    _errorTimer = null;
    _playerErrorPending = false;
    _pendingPlayerErrorToken = null;
    _recovering = true;
    var recovered = false;
    try {
      recovered = await recoverNext();
    } catch (_) {}
    if (generation != _generation) return;
    _recovering = false;
    if (_playerErrorPending) _schedulePlayerError();
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
  }

  void _finishRound() {
    _finishTimer?.cancel();
    _finishTimer = null;
    onRoundEnd?.call();
    _hasRecovered = false;
  }
}
