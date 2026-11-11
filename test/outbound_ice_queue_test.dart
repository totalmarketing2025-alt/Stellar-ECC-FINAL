import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/calls/outbound_ice_queue.dart';

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('deduplicates queued candidates and sends in order', () async {
    final gate = Completer<void>();
    final sent = <String>[];
    final queue = OutboundIceQueue<String>(
      keyOf: (x) => x,
      send: (x) async {
        sent.add(x);
        if (x == 'a') await gate.future;
      },
    );
    expect(queue.enqueue('a'), isTrue);
    expect(queue.enqueue('a'), isFalse);
    expect(queue.enqueue('b'), isTrue);
    gate.complete();
    await tick();
    expect(sent, ['a', 'b']);
    expect(queue.length, 0);
  });

  test('retries transient failure and caps attempts', () async {
    var attempts = 0;
    final queue = OutboundIceQueue<String>(
      keyOf: (x) => x,
      retryDelay: Duration.zero,
      send: (_) async {
        attempts++;
        if (attempts < 3) throw StateError('offline');
      },
    );
    queue.enqueue('a');
    await tick();
    expect(attempts, 3);
    expect(queue.length, 0);
  });

  test('stops after three failed attempts', () async {
    var attempts = 0;
    final queue = OutboundIceQueue<String>(
      keyOf: (x) => x,
      retryDelay: Duration.zero,
      send: (_) async {
        attempts++;
        throw StateError('offline');
      },
    );
    queue.enqueue('a');
    await tick();
    expect(attempts, 3);
    expect(queue.length, 0);
  });

  test('clear prevents stale completion from modifying new queue', () async {
    final oldGate = Completer<void>();
    final sent = <String>[];
    final queue = OutboundIceQueue<String>(
      keyOf: (x) => x,
      send: (x) async {
        sent.add(x);
        if (x == 'old') await oldGate.future;
      },
    );
    queue.enqueue('old');
    await tick();
    queue.clear();
    queue.enqueue('new');
    await tick();
    oldGate.complete();
    await tick();
    expect(sent, ['old', 'new']);
    expect(queue.length, 0);
  });

  test('drops candidate older than 15 seconds before retry', () async {
    var now = DateTime(2026);
    var attempts = 0;
    final queue = OutboundIceQueue<String>(
      keyOf: (x) => x,
      clock: () => now,
      sleep: (_) async { now = now.add(const Duration(seconds: 16)); },
      send: (_) async {
        attempts++;
        throw StateError('offline');
      },
    );
    queue.enqueue('a');
    await tick();
    expect(attempts, 1);
    expect(queue.length, 0);
  });

  test('caps queue at 128 candidates', () async {
    final gate = Completer<void>();
    final queue = OutboundIceQueue<String>(
      keyOf: (x) => x,
      send: (_) => gate.future,
    );
    for (var i = 0; i < 128; i++) {
      expect(queue.enqueue('candidate-$i'), isTrue);
    }
    expect(queue.enqueue('overflow'), isFalse);
    expect(queue.length, 128);
    queue.clear();
    gate.complete();
  });
}
