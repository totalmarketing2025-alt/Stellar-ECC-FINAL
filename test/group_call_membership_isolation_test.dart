import 'package:flutter_test/flutter_test.dart';
import '../lib/core/calls/group_call_protocol.dart';

void main() {
  test('membership is normalized, unique and sorted', () {
    expect(GroupCallProtocol.members([' @Bob ', 'ALICE', 'bob', '']),
        ['alice', 'bob']);
  });

  test('membership digest is independent of ordering and case', () {
    expect(GroupCallProtocol.membershipDigest(['Alice', 'Bob']),
        GroupCallProtocol.membershipDigest(['@bob', 'alice']));
    expect(GroupCallProtocol.membershipDigest(['alice', 'bob']),
        isNot(GroupCallProtocol.membershipDigest(['alice', 'charlie'])));
  });

  test('room membership requires local participant and two to four members', () {
    expect(GroupCallProtocol.validMembers(['alice'], 'alice'), isFalse);
    expect(GroupCallProtocol.validMembers(['alice', 'bob'], 'alice'), isTrue);
    expect(GroupCallProtocol.validMembers(['alice', 'bob', 'c', 'd'], 'alice'), isTrue);
    expect(GroupCallProtocol.validMembers(['alice', 'bob', 'c', 'd', 'e'], 'alice'), isFalse);
    expect(GroupCallProtocol.validMembers(['bob', 'charlie'], 'alice'), isFalse);
  });

  test('only one peer initiates negotiation for each mesh edge', () {
    final names = ['alice', 'bob', 'charlie', 'david'];
    for (var i = 0; i < names.length; i++) {
      for (var j = i + 1; j < names.length; j++) {
        expect(GroupCallProtocol.shouldOffer(names[i], names[j]), isTrue);
        expect(GroupCallProtocol.shouldOffer(names[j], names[i]), isFalse);
      }
    }
    expect(GroupCallProtocol.shouldOffer('Alice', '@alice'), isFalse);
  });
}
