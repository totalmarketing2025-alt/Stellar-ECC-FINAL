import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/presentation/state/relay_listener.dart').readAsStringSync();

  test('verified signatures are restored before group signals are dispatched', () {
    final verification = source.indexOf('verifyAndPreserveSignature');
    final restore = source.indexOf('..addAll(authenticatedPayload)');
    final dispatch = source.indexOf('.dispatch(', restore);

    expect(verification, greaterThanOrEqualTo(0));
    expect(restore, greaterThan(verification));
    expect(dispatch, greaterThan(restore));
  });
}
