import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/calls/call_platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ecc.stellar.app/calls');
  final invocations = <MethodCall>[];

  setUp(() {
    invocations.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invocations.add(call);
      if (call.method == 'startOutgoingCallForeground') return true;
      if (call.method == 'stopOutgoingCallForeground') return true;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('starts outgoing foreground service with call media kind', () async {
    final bridge = CallPlatformBridge();

    final started = await bridge.startOutgoingCallForeground(
      callId: 'call-123',
      remoteNickname: 'alice',
      kind: 'video',
    );

    expect(started, isTrue);
    final request = invocations.singleWhere(
      (call) => call.method == 'startOutgoingCallForeground',
    );
    expect(request.arguments, {
      'callId': 'call-123',
      'remoteNickname': 'alice',
      'kind': 'video',
    });

    await bridge.dispose();
  });

  test('stops only the requested call foreground service', () async {
    final bridge = CallPlatformBridge();

    final stopped = await bridge.stopOutgoingCallForeground('call-123');

    expect(stopped, isTrue);
    final request = invocations.singleWhere(
      (call) => call.method == 'stopOutgoingCallForeground',
    );
    expect(request.arguments, {'callId': 'call-123'});

    await bridge.dispose();
  });

  test('does not dispatch foreground actions with an empty call ID', () async {
    final bridge = CallPlatformBridge();

    expect(
      await bridge.startOutgoingCallForeground(
        callId: '',
        remoteNickname: 'alice',
        kind: 'voice',
      ),
      isFalse,
    );
    expect(await bridge.stopOutgoingCallForeground(''), isFalse);
    expect(
      invocations.where(
        (call) => call.method == 'startOutgoingCallForeground' ||
            call.method == 'stopOutgoingCallForeground',
      ),
      isEmpty,
    );

    await bridge.dispose();
  });
}
