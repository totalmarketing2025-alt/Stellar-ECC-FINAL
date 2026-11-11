import 'dart:async';

/// Bounded, session-scoped ICE signaling queue with deduplication and TTL.
class OutboundIceQueue<T> {
  OutboundIceQueue({
    required this.send,
    required this.keyOf,
    this.capacity = 128,
    this.maxAttempts = 3,
    this.ttl = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 3),
    this.retryDelay = const Duration(milliseconds: 500),
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  })  : _clock = clock ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  final Future<void> Function(T) send;
  final String Function(T) keyOf;
  final int capacity;
  final int maxAttempts;
  final Duration ttl;
  final Duration sendTimeout;
  final Duration retryDelay;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  final List<_IceEntry<T>> _items = [];
  final Set<String> _keys = {};
  bool _draining = false;
  int _generation = 0;

  int get length => _items.length;

  bool enqueue(T value) {
    final key = keyOf(value);
    if (_keys.contains(key) || _items.length >= capacity) return false;
    _items.add(_IceEntry(value, key, _clock()));
    _keys.add(key);
    unawaited(_drain(_generation));
    return true;
  }

  void clear() {
    _generation++;
    _items.clear();
    _keys.clear();
    _draining = false;
  }

  Future<void> _drain(int generation) async {
    if (_draining || generation != _generation) return;
    _draining = true;
    try {
      while (generation == _generation && _items.isNotEmpty) {
        final item = _items.first;
        for (var attempt = 0; attempt < maxAttempts; attempt++) {
          if (generation != _generation ||
              _clock().difference(item.createdAt) >= ttl) break;
          try {
            await send(item.value).timeout(sendTimeout);
            break;
          } catch (_) {
            if (attempt + 1 < maxAttempts &&
                generation == _generation &&
                _clock().difference(item.createdAt) < ttl) {
              await _sleep(retryDelay * (1 << attempt));
            }
          }
        }
        if (generation != _generation) break;
        _items.removeAt(0);
        _keys.remove(item.key);
      }
    } finally {
      if (generation == _generation) _draining = false;
    }
  }
}

class _IceEntry<T> {
  _IceEntry(this.value, this.key, this.createdAt);
  final T value;
  final String key;
  final DateTime createdAt;
}
