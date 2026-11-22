# STELLAR Guard — Phase 05 deployment and deletion checks

## What an approval does

1. Moderator signs in with the existing admin session and opens **Guard approvals**.
2. Moderator reads the original report, writes a justification, selects Approve,
   and types the exact target nickname in the confirmation field.
3. Relay validates the admin session, then forwards a narrowly scoped decision
   to Directory. No deletion secret is included in the Moderator executable.
4. Directory verifies the immutable case and audit chain, then atomically
   commits the approval, revocation tombstone, removal of the registered user
   (including push registrations), and profile-photo removal.
5. Relay removes the target's queued messages and send receipts, closes its
   active socket, and denies further sends from that revoked connection.
6. The device signs a one-time status challenge with its *old* Signal identity;
   if Directory confirms revocation, the client wipes local messages, keys and
   identity and returns to the welcome screen. Offline devices retry on resume
   and every two minutes while the application is running.

## Required configuration — never put secrets in an APK

- Set `GUARD_REVIEW_SECRET` in **both** Directory and Relay Workers for case
  listing/details. This is already used by the Phase 04 Directory API.
- Set **the same** fresh random `GUARD_MODERATOR_ACTION_SECRET` (at least 32
  characters) in both Directory and Relay Workers. It must differ from
  `GUARD_REVIEW_SECRET`, `RELAY_SHARED_SECRET`, and `GUARD_MIGRATION_SECRET`.
- Keep `DIRECTORY_URL` configured in the Relay Worker.
- Put secrets in Cloudflare Worker secret storage, not in `wrangler.jsonc`, git
  or Flutter environment variables. Until configured, approval fails closed.

## Test and launch order

1. Merge only after the Directory and Relay unit tests and both Flutter test
   suites pass in PR CI. **Do not test approval against a real account.**
2. Configure both Worker secrets (and check `/health`) before enabling Moderator.
3. On disposable test identities: submit a case, verify audit, reject one case
   (nothing deleted), approve one matching case, confirm target profile/photo
   disappear, Relay connection closes, and client returns to onboarding.
4. Turn network off before approval, then on. Verify the client reconciles on
   resume; network errors must **never** trigger a local wipe.
5. Try an unknown code, cancelled case, changed target identity, repeated
   decision, and corrupted audit. All must fail closed without extra deletion.
6. If Relay cleanup is interrupted after Directory commits, the same admin
   decision and **exact same justification** can be retried; Directory does
   not repeat deletion or append another audit event.

## Scope and retention

Deletion removes the active Directory profile, profile photo, push tokens,
relay queues and connection. Guard case and immutable audit history are retained
for accountable moderation; already-delivered messages on *other* devices
cannot be remotely erased. Moderator's existing TTL-based report/message
history remains subject to its existing retention policy.

Revoked nicknames and nine-digit Guard codes stay reserved so an old identity
cannot be silently recreated or accidentally reassigned to a different user.
This is intentional. A return to the welcome screen starts a **new identity**;
the prior nickname cannot be reclaimed by an automatic registration retry.
