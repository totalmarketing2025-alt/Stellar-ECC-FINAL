import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/guard/guard_case_service.dart';
import '../../../core/guard/guard_protocol.dart';
import '../../../core/network/directory_client.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

/// Model A: reports stay pending until independently reviewed by a moderator.
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
              child: const Text('Back')),
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
      'Submit Guard report?',
      'This creates a request for moderator review. It does NOT remove '
          'or disable any user account.',
      'Submit for review',
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
        const SnackBar(content: Text('Guard report saved for moderator review.')),
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
        'Cancel report',
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
          const Text('My 9-digit Guard code',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Your Guard code identifies your account. It is NOT '
              'your app PIN.',
              style: TextStyle(color: StellarColors.textSecondary)),
          const SizedBox(height: 12),
          if (_myCode != null) ...[
            SelectableText(_myCode!, key: const Key('guard_my_code'),
                style: const TextStyle(fontSize: 24, letterSpacing: 3)),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _myCode!)),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copy code'),
            ),
          ] else OutlinedButton(
            onPressed: ready && !_loadingCode ? _revealCode : null,
            child: _loadingCode
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Reveal my code'),
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
            const Text('Report another user',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('guard_target_code'),
              controller: _target,
              keyboardType: TextInputType.number,
              maxLength: 9,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Target user code', hintText: '9 digits',
                counterText: '', border: OutlineInputBorder(),
              ),
              validator: (value) => GuardProtocol.validCode(value ?? '')
                  ? null : 'Enter exactly nine digits',
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // FormField stores its initial value internally. Remount when
              // an interrupted submission restores a different reason.
              key: ValueKey('guard_reason_$_reason'),
              value: _reason,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Reason', border: OutlineInputBorder(),
              ),
              items: GuardProtocol.reasons.entries.map((entry) =>
                  DropdownMenuItem(value: entry.key,
                      child: Text(entry.value))).toList(),
              onChanged: _submitting ? null : (value) {
                if (value != null) setState(() => _reason = value);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('guard_details'),
              controller: _details,
              maxLength: 2000,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Describe the issue',
                hintText: 'What happened?', border: OutlineInputBorder(),
              ),
              validator: (value) => GuardProtocol.validDetails((value ?? '').trim())
                  ? null : 'Write 10–2000 characters',
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
                child: const Text('Restore previous report'),
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
                    : const Text('Submit for moderator review'),
              ),
            ),
            const SizedBox(height: 8),
            const Text('A report never automatically removes an account.',
                style: TextStyle(color: StellarColors.textSecondary)),
          ],
        ),
      ),
    ),
  );

  Widget _historyCard() => Card(
    color: StellarColors.bgElevated,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('My Guard reports',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (_loading) const LinearProgressIndicator()
          else if (_cases.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No reports saved on this device.',
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
                  child: const Text('Refresh status'),
                ),
                if (item.status == 'pending_review')
                  TextButton(
                    onPressed: _busyCase != null || _submitting
                        ? null : () => _caseAction(item, cancel: true),
                    child: const Text('Cancel report'),
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
      appBar: AppBar(title: const Text('Stellar GUARD')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(Icons.shield_moon_outlined,
              color: StellarColors.accentBlue, size: 56),
          const SizedBox(height: 12),
          const Text('Stellar GUARD', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Submit a secure report about a Stellar account. '
              'A moderator must review it separately.',
              textAlign: TextAlign.center,
              style: TextStyle(color: StellarColors.textSecondary)),
          if (!ready)
            const Card(child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Complete account setup before using Guard.'),
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
          _historyCard(),
          const SizedBox(height: 16),
          const Text('Case IDs are stored securely on this device. If app '
              'data is wiped, these local references can be lost. Guard does '
              'not remotely delete anyone\'s messages.',
              style: TextStyle(color: StellarColors.textSecondary)),
        ],
      ),
    );
  }
}
