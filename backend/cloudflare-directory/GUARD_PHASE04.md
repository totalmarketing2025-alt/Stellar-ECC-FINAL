# STELLAR Guard — Phase 04 Flutter requester integration

## Scope and safety boundary

The Settings → Stellar GUARD screen integrates the Phase 01 and Phase 02
directory endpoints. It can show **the owner's own nine-digit Guard user
code**, submit reports for manual moderator review, refresh the current case
status, and cancel a report while it is pending. A code is an account
identifier, not a PIN or deletion credential.

**Phase 04 implements no account approval, revocation, deletion or moderator
decision.** The directory still stores each new case as `pending_review`.
The Phase 03 read-only reviewer API remains independent and protected by
`GUARD_REVIEW_SECRET`.

## Trust and recovery boundaries

- Each code retrieval uses a one-time `/v1/guard/code/challenge` followed by
  the canonical Signal-identity-signed `/v1/guard/code` proof.
- Each case action (`submit`, `status`, `cancel`) obtains a new purpose-bound
  challenge and signs the exact ordered `stellar-guard-case-v1` JSON array.
  The registered private key stays on the device. The server verifies both
  identity and the submitted action.
- Nine-digit codes are handled as strings, preserving leading zeros. The UI
  allows only nine numeric characters and requires 10–2000 characters of
  trimmed report details with a defined reason.
- Prior to sending a report, the client writes its exact payload and a UUID
  idempotency key to the platform secret store under the account nickname.
  An interrupted request retains the draft and key; the UI allows restoration
  and retry of **the same payload**. Changed payloads fail closed until the
  pending report is retried.
- On success, the client stores only a small case receipt (case ID, status,
  timestamps, target code for the owner's reference) in the protected local
  store, then clears the pending draft. At most 50 recent case references are
  kept per account. No raw evidence or moderator secrets are cached in the
  receipt list.
- The server does not expose a public case-list endpoint. Reinstalling the
  app, wiping its local secure storage or switching phones can lose these
  locally known case IDs, even when the server still holds the reports.
- Status is refreshed manually, not in a loop: challenge issuance is limited
  by the directory. Cancellation is confirmed and available only for a
  locally known `pending_review` case; the server independently enforces its
  current status and original requester identity.
- Any failed submission must be treated as an **unconfirmed** outcome. Do
  not delete the local retry key on a timeout. A definitive HTTP 400
  rejection clears the draft so it can be corrected; 401/404/409/429 and
  uncertain transport failures preserve it. Backend 404s or a missing
  deployment do not imply another user's account was removed.

## Checks before enabling on a release build

1. Keep the Guard directory backend, migrations and reviewer endpoints in
   staged/draft review until Phases 01–03 are verified together. Do not
   enable any removal automation in this phase.
2. Run `flutter analyze` and `flutter test` (including
   `stellar_guard_protocol_test.dart`, `stellar_guard_service_test.dart`, and
   `stellar_guard_screen_test.dart`). Run the directory's existing Node tests.
3. On a **staging Android device**, register two accounts with distinct
   Signal identity keys. Reveal each owner's nine-digit Guard code, including
   handling of leading zeros; ensure the code differs from the app PIN.
4. Report one account from the other. Confirm the submission dialog clearly
   says the target account is unchanged. Refresh the status and verify
   `pending_review` on both device and staging server.
5. Interrupt the connection after the server accepts a report but before
   the app receives its response. Restart and retry the exact report; verify
   that the case ID, UUID idempotency index, and audit history are not
   duplicated. Changing the payload must be rejected until retried.
6. Cancel a pending report and confirm a single `cancelled` audit event.
   Check that a second status refresh does not offer cancellation.
7. Switch between the two accounts on one device; verify no local report
   references or revealed codes leak across the account switch. Repeat after
   app restart and with a fresh device to validate storage limitations.
8. Confirm error handling on network disconnect, 401/404/409/429 responses,
   unexpected server responses, and unavailable secure storage. Ensure
   all failures remain non-destructive.

Phase 05 must independently implement moderator authentication,
authorization, evidence review, decisions and audit extension. Those
features are **not** implied by a report's existence.
