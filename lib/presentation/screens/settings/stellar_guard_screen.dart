import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/guard/guard_case_service.dart';
import '../../../core/guard/guard_protocol.dart';
import '../../../core/network/directory_client.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/stellar_translations.dart';
import '../../state/app_providers.dart';

/// Guard case submission. All reports require moderator review.
class StellarGuardScreen extends ConsumerStatefulWidget {
  const StellarGuardScreen({super.key});

  @override
  ConsumerState<StellarGuardScreen> createState() => _StellarGuardScreenState();
}

class _StellarGuardScreenState extends ConsumerState<StellarGuardScreen> {
  final _form = GlobalKey<FormState>();
  final _target = TextEditingController();
  final _details = TextEditingController();
  String _reason = 'harassment';
  String? _myCode;
  String? _loadError;
  GuardPendingSubmission? _pending;
  List<GuardCaseReceipt> _cases = const [];
  bool _loading = true;
  bool _loadingCode = false;
  bool _submitting = false;
  String? _busyCase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _target.dispose();
    _details.dispose();
    super.dispose();
  }

  String? get _account {
    final nickname = ref.read(guardNicknameProvider)?.trim().toLowerCase();
    return nickname == null || nickname.isEmpty ? null : nickname;
  }

  GuardCaseService get _service => ref.read(guardCaseServiceProvider);

  Future<void> _load() async {
    final account = _account;
    if (account == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final cases = await _service.loadLocalCases(account);
      final pending = await _service.loadPending(account);
      if (!mounted || _account != account) return;
      setState(() {
        _cases = cases;
        _pending = pending;
        _loading = false;
        _loadError = null;
        if (pending != null) {
          _target.text = pending.targetCode;
          _reason = pending.reason;
          _details.text = pending.details;
        }
      });
    } catch (_) {
      if (!mounted || _account != account) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load protected Guard records on this device.';
      });
    }
  }

  String _friendlyError(Object error) {
    if (error is GuardPendingSubmissionConflict) {
      return 'A prior report has an uncertain result. Restore and retry '
          'the original details to prevent duplicates.';
    }
    if (error is DirectoryException) {
      if (error.statusCode == 400) {
        return 'This report was rejected. Check the target code and details.';
      }
      if (error.statusCode == 404) {
        return 'Guard service or case is unavailable. No change was confirmed.';
      }
      if (error.statusCode == 429) {
        return 'Too many requests. Wait a few minutes before retrying.';
      }
      if (error.statusCode == 401 || error.statusCode == 409) {
        return 'Guard identity or case verification failed. Retry or refresh.';
      }
      return 'Guard server error (${error.statusCode}). Please retry.';
    }
    return 'Could not confirm the Guard request. Retry the same details.';
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_friendlyError(error))),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async {
    if (!mounted) return false;
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: Text(stellarText(context, "Back"))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(action)),
        ],
      ),
    ) ?? false;
  }

  Future<void> _revealCode() async {
    final account = _account;
    if (account == null || _loadingCode) return;
    setState(() => _loadingCode = true);
    try {
      final code = await _service.getMyCode(account);
      if (mounted && _account == account) setState(() => _myCode = code);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _loadingCode = false);
    }
  }

  Future<void> _submit() async {
    final account = _account;
    if (account == null || _submitting || _busyCase != null ||
        !_form.currentState!.validate()) return;
    final confirmed = await _confirm(
      stellarText(context, 'Submit Guard report?'),
      stellarText(context, 'This creates a request for moderator review. Submitting a report does not remove or disable the target account immediately. A moderator reviews the details before taking action.'),
      stellarText(context, 'Submit for review'),
    );
    if (!confirmed || !mounted || _account != account) return;

    setState(() => _submitting = true);
    try {
      await _service.submit(
        account: account,
        targetCode: _target.text,
        reason: _reason,
        details: _details.text.trim(),
      );
      final cases = await _service.loadLocalCases(account);
      if (!mounted || _account != account) return;
      setState(() {
        _cases = cases;
        _pending = null;
        _target.clear();
        _details.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(stellarText(
          context, 'Guard report saved for moderator review.',
        ))),
      );
    } catch (error) {
      try {
        final pending = await _service.loadPending(account);
        if (mounted && _account == account) {
          setState(() => _pending = pending);
        }
      } catch (_) {
        // Keep the original error and never silently discard the retry key.
      }
      _error(error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _caseAction(GuardCaseReceipt item, {required bool cancel}) async {
    final account = _account;
    if (account == null || _submitting || _busyCase != null) return;
    if (cancel) {
      if (item.status != 'pending_review') return;
      final confirmed = await _confirm(
        'Cancel Guard report?',
        'This cancels the pending report. The target account is unchanged.',
        stellarText(context, "Cancel report"),
      );
      if (!confirmed || !mounted || _account != account) return;
    }
    setState(() => _busyCase = item.caseId);
    try {
      if (cancel) {
        await _service.cancel(account: account, caseId: item.caseId);
      } else {
        await _service.refresh(account: account, caseId: item.caseId);
      }
      final cases = await _service.loadLocalCases(account);
      if (mounted && _account == account) setState(() => _cases = cases);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busyCase = null);
    }
  }

  Widget _myCodeCard(bool ready) => Card(
    color: StellarColors.bgElevated,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stellarText(context, "My 9-digit Guard code"),
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(stellarText(context, 'Your Guard code identifies your account. It is NOT your app PIN.'),
              style: TextStyle(color: StellarColors.textSecondary)),
          const SizedBox(height: 12),
          if (_myCode != null) ...[
            SelectableText(_myCode!, key: const Key('guard_my_code'),
                style: const TextStyle(fontSize: 24, letterSpacing: 3)),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _myCode!)),
              icon: const Icon(Icons.copy_outlined),
              label: Text(stellarText(context, "Copy code")),
            ),
          ] else OutlinedButton(
            onPressed: ready && !_loadingCode ? _revealCode : null,
            child: _loadingCode
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(stellarText(context, "Reveal my code")),
          ),
        ],
      ),
    ),
  );

  Widget _reportCard(bool ready) => Card(
    color: StellarColors.bgElevated,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stellarText(context, "Report another user"),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('guard_target_code'),
              controller: _target,
              keyboardType: TextInputType.number,
              maxLength: 9,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: stellarText(context, "Target user code"), hintText: stellarText(context, "9 digits"),
                counterText: '', border: OutlineInputBorder(),
              ),
              validator: (value) => GuardProtocol.validCode(value ?? '')
                  ? null : stellarText(context, 'Enter exactly nine digits'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // FormField stores its initial value internally. Remount when
              // an interrupted submission restores a different reason.
              key: ValueKey('guard_reason_$_reason'),
              value: _reason,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: stellarText(context, 'Reason'), border: const OutlineInputBorder(),
              ),
              items: GuardProtocol.reasons.entries.map((entry) =>
                  DropdownMenuItem(value: entry.key,
                      child: Text(stellarText(context, entry.value)))).toList(),
              onChanged: _submitting ? null : (value) {
                if (value != null) setState(() => _reason = value);
              },
            ),
            if (_reason == 'theft')
              Card(
                color: StellarColors.danger.withOpacity(0.12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(stellarText(context, 'Theft reports are reviewed by a moderator. A matching code identifies the account but does not verify that theft occurred.'),
                      style: const TextStyle(color: StellarColors.textPrimary, height: 1.4)),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(stellarText(context, 'Reports for this reason go to moderators. Submitting one does not immediately disable the account.'),
                    style: const TextStyle(color: StellarColors.textSecondary, height: 1.4)),
              ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('guard_details'),
              controller: _details,
              maxLength: 2000,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: stellarText(context, 'Describe the issue'),
                hintText: stellarText(context, "What happened?"), border: OutlineInputBorder(),
              ),
              validator: (value) => GuardProtocol.validDetails((value ?? '').trim())
                  ? null : stellarText(context, 'Write 10–2000 characters'),
              onChanged: (_) => setState(() {}),
            ),
            if (_pending != null) ...[
              const Text('An earlier request may have succeeded. Retry the '
                  'same report; its original ID is preserved.',
                  style: TextStyle(color: StellarColors.accentBlue)),
              TextButton(
                onPressed: _submitting ? null : () => setState(() {
                  _target.text = _pending!.targetCode;
                  _reason = _pending!.reason;
                  _details.text = _pending!.details;
                }),
                child: Text(stellarText(context, "Restore previous report")),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('guard_submit'),
                onPressed: ready && !_submitting && _busyCase == null &&
                        GuardProtocol.validCode(_target.text) &&
                        GuardProtocol.validDetails(_details.text.trim())
                    ? _submit : null,
                child: _submitting
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(stellarText(context, _reason == 'theft' ? 'Continue to theft confirmation' : 'Submit for moderator review')),
              ),
            ),
            const SizedBox(height: 8),
            Text(stellarText(context, "For non-theft reports, submission does not disable the account; moderators review it first."),
                style: const TextStyle(color: StellarColors.textSecondary)),
          ],
        ),
      ),
    ),
  );

  Widget _historyCard(BuildContext context) => Card(
    color: StellarColors.bgElevated,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stellarText(context, "My Guard reports"),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (_loading) const LinearProgressIndicator()
          else if (_cases.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(stellarText(context, "No reports saved on this device."),
                  style: TextStyle(color: StellarColors.textSecondary)),
            )
          else for (final item in _cases) ...[
            const Divider(),
            Text('Case ${item.caseId.substring(0, 8)}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Status: ${item.status.replaceAll('_', ' ')}',
                key: Key('guard_status_${item.caseId}')),
            if (item.targetCode != null)
              Text('Target code: ${item.targetCode}',
                  style: const TextStyle(color: StellarColors.textSecondary)),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busyCase != null || _submitting
                      ? null : () => _caseAction(item, cancel: false),
                  child: Text(stellarText(context, "Refresh status")),
                ),
                if (item.status == 'pending_review')
                  TextButton(
                    onPressed: _busyCase != null || _submitting
                        ? null : () => _caseAction(item, cancel: true),
                    child: Text(stellarText(context, "Cancel report")),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(guardNicknameProvider);
    ref.listen<String?>(guardNicknameProvider, (previous, next) {
      if (previous == next) return;
      setState(() {
        _myCode = null;
        _pending = null;
        _cases = const [];
        _target.clear();
        _details.clear();
        _reason = 'harassment';
        _loading = true;
        _loadError = null;
      });
      _load();
    });
    final ready = account != null && account.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(stellarText(context, "Stellar GUARD"))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(Icons.shield_moon_outlined,
              color: StellarColors.accentBlue, size: 56),
          const SizedBox(height: 12),
          Text(stellarText(context, "Stellar GUARD"), textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(stellarText(context, 'GUARD lets you report a Stellar account using its nine-digit Guard code. The code identifies the account; it is not your app PIN. All reports, including theft reports, are reviewed by moderators before any account action. A code match does not prove theft.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: StellarColors.textSecondary, height: 1.4)),
          const SizedBox(height: 6),
          Text(stellarText(context, 'Review the target code carefully before submitting a report. undone in Stellar.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: StellarColors.danger, height: 1.4)),
          if (!ready)
            Card(child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(stellarText(context, "Complete account setup before using Guard.")),
            )),
          if (_loadError != null)
            Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_loadError!,
                  style: const TextStyle(color: StellarColors.danger)),
            )),
          const SizedBox(height: 12),
          _myCodeCard(ready),
          const SizedBox(height: 12),
          _reportCard(ready && !_loading && _loadError == null),
          const SizedBox(height: 12),
          _historyCard(context),
          const SizedBox(height: 16),
          Text(stellarText(context, 'GUARD reports and audit history are retained for review. Local case references may be lost if you wipe app data. GUARD cannot erase messages already delivered to other devices.'),
              style: const TextStyle(color: StellarColors.textSecondary, height: 1.4)),
        ],
      ),
    );
  }
}
