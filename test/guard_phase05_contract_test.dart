import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/guard/guard_protocol.dart';

void main() {
  test('revocation proof is bound to Signal identity and a single challenge', () {
    final result = jsonDecode(GuardProtocol.accountMessage(
      nickname: ' BoB ', deviceId: 1, registrationId: 347,
      challenge: 'random-one-time-challenge',
    ));
    expect(result, [
      'stellar-guard-account-v1', 'bob', 1, 347,
      'random-one-time-challenge',
    ]);
  });

  test('startup never recreates an account after a missing Directory record', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('.isAccountRevoked(nickname)'));
    expect(source, contains('wantedModeControllerProvider).wipeAndLock()'));
    expect(source, isNot(contains('await directoryClient.register(')));
  });

  test('app retries authenticated revocation checks after offline periods', () {
    final source = File('lib/app/app.dart').readAsStringSync();
    expect(source, contains('Timer.periodic(const Duration(minutes: 2)'));
    expect(source, contains('AppLifecycleState.resumed'));
    expect(source, contains("go('/onboarding/welcome')"));
  });
}
