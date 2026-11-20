# Stellar ECC

Secure messaging application developed by I-WORKS, North Macedonia.

## Security Overview

### Message Encryption
- One-to-one conversations use the Signal Protocol with Double Ratchet.
- Group conversations use Sender Keys.
- Message encryption protects message content.

### Local Device Protection
- Sensitive key material is stored through the platform secure-storage layer where supported.
- App access can be protected with the configured app PIN and device authentication.
- Keep the application and operating system updated.

### Wanted Mode
Wanted Mode monitors selected local device and environment events, including USB, Bluetooth, network and power-related changes.

- Detected events create a local security challenge or audit event.
- An event does not automatically wipe data or lock the app.
- The user can separately select Lock now or Wipe local data and lock.
- Local wiping cannot erase copies of messages or files already held by recipients or other devices.
- Monitoring cannot guarantee detection of every security incident.

### Stellar GUARD — Server-Side Account Removal

Stellar GUARD is designed as a moderator-reviewed workflow for requesting removal of another Stellar user account, identified by a **nine-digit user code**. The code is an identifier, **not** the app unlock PIN and **not** authorization to delete an account.

**Current status: Phase 04 (Flutter Guard request and status UI); account removal is disabled.**

The Settings → Stellar GUARD screen now lets an authenticated account owner reveal their own nine-digit code, submit a report with a nine-digit target code, view saved case statuses, refresh a case and cancel a pending report. Submitting and cancelling require explicit confirmation. The backend must be deployed with Phases 01–03 before these actions can succeed.

- The directory generates a unique, cryptographically random nine-digit code when a new account is registered. Codes are stored as strings so leading zeroes are preserved and are not included in public directory responses.
- An account owner can request their **own** code using `/v1/guard/code/challenge` and `/v1/guard/code` with a one-time Signal-identity signature. Challenge issuance is rate-limited to six per account per five minutes.
- Existing accounts can be assigned codes via a **manual**, paginated, idempotent migration at `POST /v1/internal/guard-codes/migrate` (maximum 50 accounts per request). The endpoint is disabled unless operators configure a separate `GUARD_MIGRATION_SECRET`. Migration is **not** run automatically on user listing or production startup.
- The code-to-account index is internal. There is no public reverse-lookup endpoint and no account-deletion endpoint.
- `POST /v1/guard/cases/challenge` issues a 2-minute, action-specific challenge (`purpose`: `submit`, `status`, or `cancel`) for a registered Signal device. The limit is 20 challenges per account per five minutes.
- `POST /v1/guard/cases` accepts a signed case with a nine-digit `targetCode`, UUID `idempotencyKey`, `reason` (`harassment`, `threats`, `scam`, `impersonation`, or `other`) and 10–2,000 characters of `details`. Cases are saved as `pending_review`; **no deletion or approval runs**.
- `POST /v1/guard/cases/{caseId}/status` and `/cancel` require a new signed challenge from the original requester. Cancellation is permitted only while the case is `pending_review`.
- Every action proof signs the array `["stellar-guard-case-v1", action, nickname, deviceId, registrationId, challenge, caseId, targetCode, reason, details, idempotencyKey]`. Unused action fields are empty strings. The code is returned only to its authenticated owner through the Phase 01 API, and case responses never reveal whether a target code exists.
- A reporter may create at most three new cases in 24 hours, with one active case per target; retries are idempotent. No public case listing, case approval, background deletion or moderator API is exposed.
- Each case now has a stable evidence digest and an append-only, SHA-256-linked history of submission and cancellation. The server verifies record/evidence consistency on review and before further case changes; modified or missing events cause a `409` integrity error.
- An internal, **read-only** review API lists cases and retrieves details with audit events. It is disabled until a separate strong `GUARD_REVIEW_SECRET` is configured. This secret must differ from relay and migration secrets.
- Operators can explicitly backfill pre-audit cases in bounded, idempotent batches. Backfills are marked `legacy_imported`, not misrepresented as original historical events. No automatic backfill runs on startup.
- Phase 04 signs each Flutter Guard request with the registered Signal identity key. The private key stays on-device. A report is persisted to protected local storage with a random, reusable idempotency UUID **before** its first network attempt, so an uncertain network result can be retried without duplicating the case. The same account's local case references survive restarts, but do not constitute a server-wide case listing or backup. Switching accounts never shows another account's local cases.
- The interface deliberately refreshes status only on user action, to avoid challenge rate limits. It does not auto-approve cases or execute removal; all reports remain `pending_review` until a future moderator workflow exists.
- These application-level append-only records are **tamper-evident**, not a guarantee of immutable external storage. A privileged actor with direct write access could rewrite the record and its hashes; off-site/WORM audit anchoring is still needed before high-assurance production.
- Subsequent phases will implement moderator approval, reliable background processing, deletion controls and further abuse protection. Knowledge of a nine-digit code alone will never authorize removal.

See [Guard Phase 03 operations](backend/cloudflare-directory/GUARD_PHASE03.md) for private endpoints, migration safety and the audit threat model.
See [Guard Phase 04 Flutter integration](backend/cloudflare-directory/GUARD_PHASE04.md) for the mobile rollout and test plan.
Before merging or deploying Phases 01–04, follow the [Guard staging and deployment verification gate](backend/cloudflare-directory/GUARD_DEPLOYMENT_VERIFICATION.md). Pull-request CI alone does not deploy the Cloudflare Directory Worker.

**Migration preparation (operator only, not yet run):** After a staging backup and verification, configure `GUARD_MIGRATION_SECRET` in the directory Worker, then invoke the authenticated migration endpoint repeatedly using its `nextCursor` until `done: true`. Verify index invariants before a production migration. Do not use the relay shared secret as the migration secret.

## Security Best Practices

- Never share your app PIN or verification codes.
- Use a strong device lock.
- Keep your operating system and Stellar updated.
- Protect your device and backups.
- Remember that local deletion cannot revoke information already delivered to another participant.

No security feature can guarantee protection against every compromised device, operating-system vulnerability or physical attack.
