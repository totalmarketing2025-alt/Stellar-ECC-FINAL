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

Wanted Mode is an optional local device-monitoring feature. On supported Android devices it watches supported USB-host connections, Bluetooth changes, network/Wi-Fi changes, power connection and battery level.

- An accepted event opens a 10-second challenge that asks for the app PIN.
- If the challenge expires while Wanted Mode is enabled and Android event-alert notifications are allowed, Stellar requests a local wipe and locks the app. Challenges recovered after a reboot are not treated as newly missed checks.
- If Android blocks the event alerts, the expired challenge remains available for PIN review instead of triggering the automatic wipe.
- The battery challenge starts below 20% and rearms after charging to 25%.
- **Lock now** only locks the app. **Wipe local data and lock** erases data on this phone. Neither operation can erase copies already delivered to another device.
- Android restrictions and device state can prevent monitoring; Wanted Mode cannot guarantee detection of every security incident.

### Stellar GUARD

GUARD uses a nine-digit code to identify a Stellar account. The code is not the app PIN and is not proof that an account was stolen.

All reports, including theft reports, are stored for moderator review. A submitted report does not immediately revoke or disable an account. A moderator must review the report and explicitly approve an action; a matching nine-digit code identifies an account but does not prove that theft occurred.

A moderator-approved revocation can remove the account's active directory/relay records, but it cannot erase messages or media already delivered to other devices. A revoked device clears its local data when it later verifies revocation. Test GUARD with disposable identities in a staging environment.

## Security Best Practices

- Never share your app PIN or verification codes.
- Use a strong device lock.
- Keep your operating system and Stellar updated.
- Protect your device and backups.
- Remember that local deletion cannot revoke information already delivered to another participant.

No security feature can guarantee protection against every compromised device, operating-system vulnerability or physical attack.
