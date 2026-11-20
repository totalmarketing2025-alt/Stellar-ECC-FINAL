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

**Current status: Phase 01 (Guard identity foundation); account removal is disabled.**

The current Settings screen accepts a nine-digit target code but still has a disabled Continue action. It cannot submit a case or remove an account.

- The directory generates a unique, cryptographically random nine-digit code when a new account is registered. Codes are stored as strings so leading zeroes are preserved and are not included in public directory responses.
- An account owner can request their **own** code using `/v1/guard/code/challenge` and `/v1/guard/code` with a one-time Signal-identity signature. Challenge issuance is rate-limited to six per account per five minutes.
- Existing accounts can be assigned codes via a **manual**, paginated, idempotent migration at `POST /v1/internal/guard-codes/migrate` (maximum 50 accounts per request). The endpoint is disabled unless operators configure a separate `GUARD_MIGRATION_SECRET`. Migration is **not** run automatically on user listing or production startup.
- The code-to-account index is internal. There is no public reverse-lookup endpoint and no account-deletion endpoint.
- Subsequent phases will implement authenticated case submission, moderator approval, reliable background processing, deletion controls, abuse protection, and audit records. Knowledge of a nine-digit code alone will never authorize removal.

**Migration preparation (operator only, not yet run):** After a staging backup and verification, configure `GUARD_MIGRATION_SECRET` in the directory Worker, then invoke the authenticated migration endpoint repeatedly using its `nextCursor` until `done: true`. Verify index invariants before a production migration. Do not use the relay shared secret as the migration secret.

## Security Best Practices

- Never share your app PIN or verification codes.
- Use a strong device lock.
- Keep your operating system and Stellar updated.
- Protect your device and backups.
- Remember that local deletion cannot revoke information already delivered to another participant.

No security feature can guarantee protection against every compromised device, operating-system vulnerability or physical attack.
