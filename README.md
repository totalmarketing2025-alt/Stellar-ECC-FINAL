# Stellar ECC

Secure messaging application developed by I-WORKS, North Macedonia.

## Security Overview

### Message Encryption
- One-to-one conversations use the Signal Protocol with Double Ratchet.
- Group conversations use Sender Keys.
- Message encryption protects message content, but does not mean all metadata or every category of application data is hidden.

### Local Device Protection
- Sensitive key material is stored through the platform secure-storage layer where supported.
- App access can be protected with the configured app PIN and device authentication.
- Keep the application and operating system updated.

### Wanted Mode
Wanted Mode monitors selected local device and environment events, including USB, Bluetooth, network and power-related changes.

- Detected events can create a local security challenge or audit event.
- An event does not automatically wipe data or lock the app.
- The user can separately select Lock now or Wipe local data and lock.
- Local wiping cannot erase copies of messages or files already held by recipients or other devices.
- Monitoring cannot guarantee detection of every security incident.

### Stellar GUARD — Planned Server-Side Account Removal

Stellar GUARD is designed as a protected workflow for requesting removal of a Stellar user account using a six-digit verification code.

**Current status: UI preview only.**

The current Settings screen contains a six-digit code entry interface and a disabled Continue — coming soon action.

The following functionality has NOT yet been implemented:
- Server-side code generation and verification.
- Identity verification and authorization.
- Rate limiting and abuse prevention.
- Server-side account-removal execution.
- Auditing and confirmation of completed removal.

Entering a code in the current screen does not verify an identity and cannot remove an account.

Before activation, the server-side implementation must enforce authenticated authorization, short-lived and single-use codes, rate limits, abuse protection, auditability and a clearly defined deletion scope.

Account removal must never be presented as complete until the server confirms it.

## Security Best Practices

- Never share your app PIN or verification codes.
- Use a strong device lock.
- Keep your operating system and Stellar updated.
- Protect your device and backups.
- Remember that local deletion cannot revoke information already delivered to another participant.

No security feature can guarantee protection against every compromised device, operating-system vulnerability or physical attack.
