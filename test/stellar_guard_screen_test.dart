import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/guard/guard_case_service.dart';
import 'package:stellar_ecc/core/guard/guard_protocol.dart';
import 'package:stellar_ecc/core/network/directory_client.dart';
import 'package:stellar_ecc/core/security/platform_key_store.dart';
import 'package:stellar_ecc/presentation/screens/settings/stellar_guard_screen.dart';
import 'package:stellar_ecc/presentation/state/app_providers.dart';

const _caseId = 'c8c642a8-8324-41f5-a5cb-cef69f2f7100';

class _FakeGuardService extends GuardCaseService {
  _FakeGuardService()
      : super(
          directoryClient: DirectoryClient(baseUrl: 'https://directory.test'),
          keyStore: PlatformKeyStore(),
          identityResolver: () async => GuardSigningIdentity(
            registrationId: 101,
            sign: (message) async => 'test-signature',
          ),
        );

  int submissions = 0;
  int refreshes = 0;
  int cancellations = 0;
  String? latestAccount;
  String? latestTargetCode;
  String? latestReason;
  GuardPendingSubmission? pending;
  final cases = <GuardCaseReceipt>[];

  @override
  Future<String> getMyCode(String account) async => '000000017';

  @override
  Future<GuardPendingSubmission?> loadPending(String account) async => pending;

  @override
  Future<List<GuardCaseReceipt>> loadLocalCases(String account) async =>
      List.unmodifiable(cases);

  @override
  Future<GuardCaseReceipt> submit({
    required String account,
    required String targetCode,
    required String reason,
    required String details,
  }) async {
    submissions++;
    latestAccount = account;
    latestTargetCode = targetCode;
    latestReason = reason;
    final caseReceipt = GuardCaseReceipt(
      caseId: _caseId,
      status: reason == 'theft' ? 'approved' : 'pending_review',
      createdAt: 100,
      updatedAt: 100,
      targetCode: targetCode,
    );
    cases.insert(0, caseReceipt);
    return caseReceipt;
  }

  @override
  Future<GuardCaseReceipt> refresh({
    required String account,
    required String caseId,
  }) async {
    refreshes++;
    return cases.single;
  }

  @override
  Future<GuardCaseReceipt> cancel({
    required String account,
    required String caseId,
  }) async {
    cancellations++;
    cases[0] = GuardCaseReceipt(
      caseId: caseId,
      status: 'cancelled',
      createdAt: 100,
      updatedAt: 101,
      targetCode: cases[0].targetCode,
    );
    return cases.single;
  }
}

Future<void> _mount(
  WidgetTester tester,
  _FakeGuardService fake, {
  String? nickname = 'alice',
}) async {
  tester.view.physicalSize = const Size(900, 1700);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    fake.directoryClient.dispose();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: [
      guardCaseServiceProvider.overrideWithValue(fake),
      guardNicknameProvider.overrideWithValue(nickname),
    ],
    child: const MaterialApp(home: StellarGuardScreen()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Guard requires a registered account', (tester) async {
    final fake = _FakeGuardService();
    await _mount(tester, fake, nickname: null);

    expect(find.text('Complete account setup before using Guard.'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('guard_submit')))
        .onPressed, isNull);
    expect(fake.submissions, 0);
  });

  testWidgets('owner sees a nine-digit Guard code separate from the PIN',
      (tester) async {
    final fake = _FakeGuardService();
    await _mount(tester, fake);

    expect(find.textContaining('It is NOT your app PIN.'), findsOneWidget);
    await tester.tap(find.text('Reveal my code'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('guard_my_code')), findsOneWidget);
    expect(find.text('000000017'), findsOneWidget);
  });

  testWidgets('restores the precise pending payload and selected reason',
      (tester) async {
    final fake = _FakeGuardService();
    fake.pending = const GuardPendingSubmission(
      targetCode: '000000018',
      reason: 'scam',
      details: 'A previous report whose response was interrupted.',
      idempotencyKey: _caseId,
    );
    await _mount(tester, fake);

    expect(find.text('Restore previous report'), findsOneWidget);
    expect(tester.widget<TextFormField>(
        find.byKey(const Key('guard_target_code'))).controller!.text,
        '000000018');
    expect(tester.widget<TextFormField>(
        find.byKey(const Key('guard_details'))).controller!.text,
        'A previous report whose response was interrupted.');
    expect(find.text('Scam / fraud'), findsOneWidget);
  });

  testWidgets('theft reason warns about immediate account revocation', (tester) async {
    final fake = _FakeGuardService();
    await _mount(tester, fake);
    final dropdown = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Theft / Кражба').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('guard_target_code')), '000000018');
    await tester.enterText(find.byKey(const Key('guard_details')),
        'A documented allegation of theft.');
    await tester.pumpAndSettle();
    expect(tester.state<FormFieldState<String>>(dropdown).value, 'theft');
    final submit = find.byKey(const Key('guard_submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('permanently revokes'), findsOneWidget);
    expect(fake.submissions, 0);
    await tester.tap(find.text('Submit theft report'));
    await tester.pumpAndSettle();
    expect(fake.latestReason, 'theft');
    expect(fake.submissions, 1);
    expect(find.text('Status: approved'), findsOneWidget);
  });

  testWidgets('valid report requires confirmation and stays pending review',
      (tester) async {
    final fake = _FakeGuardService();
    await _mount(tester, fake);
    final submit = find.byKey(const Key('guard_submit'));

    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('guard_target_code')),
        '000000017');
    await tester.enterText(find.byKey(const Key('guard_details')),
        'Repeated unwanted contact.');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('does NOT remove'), findsOneWidget);
    expect(fake.submissions, 0);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(fake.submissions, 0);

    await tester.tap(submit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit for review'));
    await tester.pumpAndSettle();

    expect(fake.submissions, 1);
    expect(fake.latestAccount, 'alice');
    expect(fake.latestTargetCode, '000000017');
    expect(find.byKey(const Key('guard_status_$_caseId')), findsOneWidget);
    expect(find.text('Status: pending review'), findsOneWidget);
  });

  testWidgets('case refresh is explicit and cancellation needs confirmation',
      (tester) async {
    final fake = _FakeGuardService();
    fake.cases.add(const GuardCaseReceipt(
      caseId: _caseId,
      status: 'pending_review',
      createdAt: 100,
      updatedAt: 100,
      targetCode: '000000017',
    ));
    await _mount(tester, fake);

    await tester.ensureVisible(find.text('Refresh status'));
    await tester.tap(find.text('Refresh status'));
    await tester.pumpAndSettle();
    expect(fake.refreshes, 1);

    await tester.tap(find.text('Cancel report'));
    await tester.pumpAndSettle();
    expect(fake.cancellations, 0);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(fake.cancellations, 0);

    await tester.tap(find.text('Cancel report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel report').last);
    await tester.pumpAndSettle();
    expect(fake.cancellations, 1);
    expect(find.text('Status: cancelled'), findsOneWidget);
    expect(find.text('Cancel report'), findsNothing);
  });
}
