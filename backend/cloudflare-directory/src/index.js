function normalizeNickname(value) {
  return String(value || "").trim().toLowerCase();
}

function validNickname(nickname) {
  return /^[a-z0-9_]{3,32}$/.test(nickname);
}


const PUSH_CHALLENGE_TTL_MS = 5 * 60 * 1000;

// GUARD codes identify accounts; they are never credentials or permission to
// remove an account. Keep the leading zeroes by storing them as strings.
const GUARD_CODE_SPACE = 1_000_000_000;
const GUARD_CODE_RANDOM_CEILING =
  Math.floor(0x100000000 / GUARD_CODE_SPACE) * GUARD_CODE_SPACE;
const GUARD_CODE_ALLOCATION_ATTEMPTS = 64;
const GUARD_CHALLENGE_TTL_MS = 2 * 60 * 1000;
const GUARD_CHALLENGE_WINDOW_MS = 5 * 60 * 1000;
const GUARD_CHALLENGE_WINDOW_MAX = 6;
const GUARD_MIGRATION_MAX_BATCH = 50;
const GUARD_CASE_CHALLENGE_TTL_MS = 2 * 60 * 1000;
const GUARD_CASE_CHALLENGE_WINDOW_MS = 5 * 60 * 1000;
const GUARD_CASE_CHALLENGE_WINDOW_MAX = 20;
const GUARD_CASE_SUBMIT_WINDOW_MS = 24 * 60 * 60 * 1000;
const GUARD_CASE_SUBMIT_WINDOW_MAX = 3;
const GUARD_CASE_REASONS = new Set([
  "harassment", "threats", "scam", "impersonation", "other",
]);
const GUARD_CASE_ACTIONS = new Set(["submit", "status", "cancel"]);
const GUARD_CASE_ID_PATTERN =
  /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const GUARD_AUDIT_GENESIS_HASH = "0".repeat(64);
const GUARD_AUDIT_MAX_EVENTS = 128;
const GUARD_REVIEW_MAX_PAGE = 50;

function validGuardCode(value) {
  return typeof value === "string" && /^[0-9]{9}$/.test(value);
}

function newGuardCode() {
  const sample = new Uint32Array(1);

  // Rejection sampling avoids modulo bias across the full 000000000–999999999
  // range. Math.random() must not be used for persistent identifiers.
  do {
    crypto.getRandomValues(sample);
  } while (sample[0] >= GUARD_CODE_RANDOM_CEILING);

  return String(sample[0] % GUARD_CODE_SPACE).padStart(9, "0");
}

function guardCodeIndexKey(code) {
  return `guard-code:${code}`;
}

function guardChallengeKey(nickname, deviceId, registrationId) {
  return `guard-challenge:${nickname}:${deviceId}:${registrationId}`;
}

function guardIdentityMessage({ nickname, deviceId, registrationId, challenge }) {
  return JSON.stringify([
    "stellar-guard-identity-v1",
    nickname,
    deviceId,
    registrationId,
    challenge,
  ]);
}

function guardDeviceMatches(user, deviceId, registrationId) {
  return user?.bundle &&
    user.bundle.deviceId === deviceId &&
    user.bundle.registrationId === registrationId;
}

async function ensureGuardCode(txn, nickname, user) {
  const key = `user:${nickname}`;

  if (user.guardCode != null) {
    if (!validGuardCode(user.guardCode)) {
      throw new Error("Stored GUARD code is invalid");
    }

    const owner = await txn.get(guardCodeIndexKey(user.guardCode));
    if (owner && owner !== nickname) {
      // Never silently change an existing identity to resolve corruption.
      throw new Error("Stored GUARD code has a conflicting owner");
    }

    if (!owner) {
      await txn.put(guardCodeIndexKey(user.guardCode), nickname);
    }

    return { code: user.guardCode, created: false };
  }

  for (let attempt = 0; attempt < GUARD_CODE_ALLOCATION_ATTEMPTS; attempt++) {
    const code = newGuardCode();
    const indexKey = guardCodeIndexKey(code);

    if (await txn.get(indexKey)) {
      continue;
    }

    await txn.put(indexKey, nickname);
    await txn.put(key, { ...user, guardCode: code });
    return { code, created: true };
  }

  throw new Error("Unable to reserve a unique GUARD code");
}

function guardCaseChallengeKey(nickname, deviceId, registrationId) {
  return `guard-case-challenge:${nickname}:${deviceId}:${registrationId}`;
}

function guardCaseAuthMessage(body, action, caseId = "") {
  return JSON.stringify([
    "stellar-guard-case-v1",
    action,
    body.nickname,
    body.deviceId,
    body.registrationId,
    body.challenge,
    caseId,
    action === "submit" ? body.targetCode : "",
    action === "submit" ? body.reason : "",
    action === "submit" ? body.details : "",
    action === "submit" ? body.idempotencyKey : "",
  ]);
}

function guardCasePublicRecord(record) {
  // Never reveal whether a target code resolves to a live account.
  return {
    caseId: record.caseId,
    status: record.status,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  };
}

function guardAuditKey(caseId, sequence) {
  return `guard-case-audit:${caseId}:${String(sequence).padStart(6, "0")}`;
}

function guardAuditSignedFields(event) {
  return [
    "stellar-guard-audit-v1",
    event.caseId,
    event.sequence,
    event.type,
    event.actor,
    event.at,
    event.fromStatus,
    event.toStatus,
    event.previousHash,
    event.payloadHash,
  ];
}

async function guardSha256(value) {
  const digest = await crypto.subtle.digest(
    "SHA-256", new TextEncoder().encode(value),
  );
  return bytesToHex(new Uint8Array(digest));
}

function guardCasePayloadFields(record) {
  // This is stable across status changes, and binds evidence to the case ID.
  return [
    "stellar-guard-case-payload-v1",
    record.caseId,
    record.requester,
    record.targetCode,
    record.targetNickname,
    record.reason,
    record.details,
    record.createdAt,
  ];
}

async function appendGuardAudit(txn, record, type, actor, fromStatus, at) {
  const sequence = (record.auditSequence || 0) + 1;
  if (sequence > GUARD_AUDIT_MAX_EVENTS) {
    throw new Error("Guard case audit capacity exceeded");
  }

  const key = guardAuditKey(record.caseId, sequence);
  if (await txn.get(key)) {
    throw new Error("Guard audit event already exists");
  }

  record.payloadHash ||= await guardSha256(JSON.stringify(
    guardCasePayloadFields(record),
  ));
  const event = {
    caseId: record.caseId,
    sequence,
    type,
    actor,
    at,
    fromStatus,
    toStatus: record.status,
    previousHash: record.auditHeadHash || GUARD_AUDIT_GENESIS_HASH,
    payloadHash: record.payloadHash,
  };
  event.hash = await guardSha256(JSON.stringify(guardAuditSignedFields(event)));

  await txn.put(key, event);
  record.auditSequence = sequence;
  record.auditHeadHash = event.hash;
}

async function verifyGuardAudit(storage, record) {
  const prefix = `guard-case-audit:${record.caseId}:`;
  if (record.auditSequence == null && record.auditHeadHash == null &&
      record.payloadHash == null) {
    // Cases created before Phase 03 are explicitly identified as untracked;
    // never pretend their earlier history was observed by the audit system.
    return (await storage.list({ prefix, limit: 1 })).size > 0
      ? { state: "corrupt" }
      : { state: "legacy", events: [] };
  }

  const count = record.auditSequence;
  if (!Number.isInteger(count) || count < 1 ||
      count > GUARD_AUDIT_MAX_EVENTS ||
      typeof record.auditHeadHash !== "string" ||
      typeof record.payloadHash !== "string") {
    return { state: "corrupt" };
  }

  const payloadHash = await guardSha256(JSON.stringify(
    guardCasePayloadFields(record),
  ));
  if (payloadHash !== record.payloadHash) {
    return { state: "corrupt" };
  }

  const entries = await storage.list({
    prefix,
    limit: GUARD_AUDIT_MAX_EVENTS + 1,
  });
  if (entries.size !== count) {
    return { state: "corrupt" };
  }

  let previousHash = GUARD_AUDIT_GENESIS_HASH;
  let previousStatus = null;
  let previousTime = 0;
  const events = [];
  for (let sequence = 1; sequence <= count; sequence++) {
    const event = entries.get(guardAuditKey(record.caseId, sequence));
    if (!event || event.caseId !== record.caseId ||
        event.sequence !== sequence ||
        event.payloadHash !== payloadHash ||
        event.previousHash !== previousHash ||
        event.fromStatus !== previousStatus ||
        (sequence === 1 && !["case_submitted", "legacy_imported"].includes(event.type)) ||
        !Number.isInteger(event.at) || event.at < previousTime ||
        typeof event.hash !== "string" ||
        event.hash !== await guardSha256(JSON.stringify(
          guardAuditSignedFields(event),
        ))) {
      return { state: "corrupt" };
    }
    previousHash = event.hash;
    previousStatus = event.toStatus;
    previousTime = event.at;
    events.push(event);
  }

  if (previousHash !== record.auditHeadHash ||
      events.at(-1)?.toStatus !== record.status) {
    return { state: "corrupt" };
  }

  return { state: "verified", events };
}

async function backfillLegacyGuardAudit(txn, record, now) {
  const verified = await verifyGuardAudit(txn, record);
  if (verified.state === "corrupt") {
    throw new Error("Guard audit integrity violation");
  }
  if (verified.state === "verified") return false;

  await appendGuardAudit(
    txn, record, "legacy_imported", "system", null, now,
  );
  await txn.put(`guard-case:${record.caseId}`, record);
  return true;
}

function guardCaseProofFields(body) {
  const nickname = normalizeNickname(body?.nickname);
  const deviceId = body?.deviceId;
  const registrationId = body?.registrationId;
  const challenge = body?.challenge;
  const signature = body?.signature;

  if (!validNickname(nickname) ||
      !Number.isInteger(deviceId) || deviceId < 1 || deviceId > 0x7fffffff ||
      !Number.isInteger(registrationId) || registrationId < 1 ||
      registrationId > 0x7fffffff ||
      typeof challenge !== "string" || challenge.length < 1 ||
      challenge.length > 128 || !validSignalSignature(signature)) {
    return null;
  }

  return { nickname, deviceId, registrationId, challenge, signature };
}

async function handleGuardCaseAction(storage, fields, action, caseId = "") {
  const userKey = `user:${fields.nickname}`;
  const challengeKey = guardCaseChallengeKey(
    fields.nickname, fields.deviceId, fields.registrationId,
  );
  const user = await storage.get(userKey);
  const challenge = await storage.get(challengeKey);

  if (!guardDeviceMatches(user, fields.deviceId, fields.registrationId) ||
      !challenge || challenge.challenge !== fields.challenge ||
      challenge.purpose !== action || challenge.expiresAt <= Date.now()) {
    return { error: "Invalid or expired Guard proof", httpStatus: 401 };
  }

  const verified = await verifySignalIdentitySignature({
    identityKey: user.bundle.identityKey,
    message: guardCaseAuthMessage(fields, action, caseId),
    signature: fields.signature,
  });

  return storage.transaction(async (txn) => {
    const currentUser = await txn.get(userKey);
    const currentChallenge = await txn.get(challengeKey);

    if (!guardDeviceMatches(currentUser, fields.deviceId, fields.registrationId) ||
        currentUser.bundle.identityKey !== user.bundle.identityKey ||
        !currentChallenge || currentChallenge.challenge !== fields.challenge ||
        currentChallenge.purpose !== action ||
        currentChallenge.expiresAt <= Date.now()) {
      return { error: "Invalid or expired Guard proof", httpStatus: 401 };
    }

    // Consume on both valid and invalid signatures. A proof cannot be replayed
    // or repurposed for a different action or payload.
    await txn.delete(challengeKey);
    if (!verified) {
      return { error: "Invalid or expired Guard proof", httpStatus: 401 };
    }

    const now = Date.now();
    if (action === "submit") {
      const idempotencyIndex =
        `guard-case-idempotency:${fields.nickname}:${fields.idempotencyKey}`;
      const existingId = await txn.get(idempotencyIndex);

      if (existingId) {
        const existing = await txn.get(`guard-case:${existingId}`);
        if (!existing || existing.targetCode !== fields.targetCode ||
            existing.reason !== fields.reason ||
            existing.details !== fields.details) {
          return { error: "Idempotency key reused", httpStatus: 409 };
        }
        if ((await verifyGuardAudit(txn, existing)).state === "corrupt") {
          return { error: "Guard audit integrity violation", httpStatus: 409 };
        }
        return guardCasePublicRecord(existing);
      }

      const activeIndex =
        `guard-case-active:${fields.nickname}:${fields.targetCode}`;
      const activeId = await txn.get(activeIndex);
      if (activeId) {
        const active = await txn.get(`guard-case:${activeId}`);
        if (active?.status === "pending_review") {
          if ((await verifyGuardAudit(txn, active)).state === "corrupt") {
            return { error: "Guard audit integrity violation", httpStatus: 409 };
          }
          await txn.put(idempotencyIndex, activeId);
          return guardCasePublicRecord(active);
        }
      }

      const submitted = await txn.get(`guard-case-submit-limit:${fields.nickname}`);
      const window = submitted?.expiresAt > now
        ? submitted
        : { count: 0, expiresAt: now + GUARD_CASE_SUBMIT_WINDOW_MS };

      if (window.count >= GUARD_CASE_SUBMIT_WINDOW_MAX) {
        return {
          error: "Guard case submission limit reached",
          httpStatus: 429,
          retryAfterSeconds: Math.ceil((window.expiresAt - now) / 1000),
        };
      }

      const owner = await ensureGuardCode(txn, fields.nickname, currentUser);
      if (fields.targetCode === owner.code) {
        return { error: "Cannot submit a case about your own account", httpStatus: 400 };
      }

      const indexedNickname = await txn.get(guardCodeIndexKey(fields.targetCode));
      const indexedUser = indexedNickname
        ? await txn.get(`user:${indexedNickname}`) : null;
      const targetNickname = indexedUser?.guardCode === fields.targetCode
        ? indexedNickname : null;

      const record = {
        caseId: crypto.randomUUID(),
        requester: fields.nickname,
        targetCode: fields.targetCode,
        // Null for unknown codes. Neither possibility is disclosed to the caller.
        targetNickname,
        reason: fields.reason,
        details: fields.details,
        status: "pending_review",
        createdAt: now,
        updatedAt: now,
      };

      await appendGuardAudit(
        txn, record, "case_submitted", fields.nickname, null, now,
      );
      await txn.put(`guard-case:${record.caseId}`, record);
      await txn.put(idempotencyIndex, record.caseId);
      await txn.put(activeIndex, record.caseId);
      await txn.put(`guard-case-submit-limit:${fields.nickname}`, {
        ...window, count: window.count + 1,
      });
      return guardCasePublicRecord(record);
    }

    const key = `guard-case:${caseId}`;
    const record = await txn.get(key);
    if (!record || record.requester !== fields.nickname) {
      return { error: "Guard case not found", httpStatus: 404 };
    }

    if ((await verifyGuardAudit(txn, record)).state === "corrupt") {
      return { error: "Guard audit integrity violation", httpStatus: 409 };
    }

    if (action === "cancel" && record.status === "pending_review") {
      await backfillLegacyGuardAudit(txn, record, now);
      const previousStatus = record.status;
      record.status = "cancelled";
      record.updatedAt = now;
      await appendGuardAudit(
        txn, record, "case_cancelled", fields.nickname, previousStatus, now,
      );
      await txn.put(key, record);
      await txn.delete(`guard-case-active:${fields.nickname}:${record.targetCode}`);
    }

    return guardCasePublicRecord(record);
  });
}

const PROFILE_PHOTO_MAX_BYTES = 512 * 1024;
const PROFILE_PHOTO_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
]);

function profilePhotoChallengeKey(nickname, deviceId, registrationId, operation) {
  return `profile-photo-challenge:${nickname}:${deviceId}:${registrationId}:${operation}`;
}

function profilePhotoStorageKey(nickname) {
  return `profile-photo:${nickname}`;
}

function validProfilePhotoBytes(bytes, mimeType) {
  if (!(bytes instanceof Uint8Array) ||
      bytes.length === 0 ||
      bytes.length > PROFILE_PHOTO_MAX_BYTES) {
    return false;
  }

  if (mimeType === "image/jpeg") {
    return bytes.length >= 3 &&
      bytes[0] === 0xff &&
      bytes[1] === 0xd8 &&
      bytes[2] === 0xff;
  }

  if (mimeType === "image/png") {
    return bytes.length >= 8 &&
      bytes[0] === 0x89 &&
      bytes[1] === 0x50 &&
      bytes[2] === 0x4e &&
      bytes[3] === 0x47 &&
      bytes[4] === 0x0d &&
      bytes[5] === 0x0a &&
      bytes[6] === 0x1a &&
      bytes[7] === 0x0a;
  }

  if (mimeType === "image/webp") {
    return bytes.length >= 12 &&
      bytes[0] === 0x52 &&
      bytes[1] === 0x49 &&
      bytes[2] === 0x46 &&
      bytes[3] === 0x46 &&
      bytes[8] === 0x57 &&
      bytes[9] === 0x45 &&
      bytes[10] === 0x42 &&
      bytes[11] === 0x50;
  }

  return false;
}

function bytesToBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function buildProfilePhotoAuthMessage({
  nickname,
  deviceId,
  registrationId,
  operation,
  challenge,
  mimeType = "",
  sha256 = "",
}) {
  return JSON.stringify([
    "stellar-profile-photo-v1",
    nickname,
    deviceId,
    registrationId,
    operation,
    mimeType,
    sha256,
    challenge,
  ]);
}

const CURVE25519_P = (1n << 255n) - 19n;

function createPushChallenge() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);

  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function buildPushAuthMessage({
  nickname,
  deviceId,
  registrationId,
  platform,
  token,
  challenge,
}) {
  return JSON.stringify([
    "stellar-push-v1",
    nickname,
    deviceId,
    registrationId,
    platform,
    token,
    challenge,
  ]);
}

function decodeBase64(value) {
  if (typeof value !== "string" || value.length === 0) {
    return null;
  }

  try {
    const normalized = value
      .replace(/-/g, "+")
      .replace(/_/g, "/");

    const padded =
      normalized + "=".repeat((4 - (normalized.length % 4)) % 4);

    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);

    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    return bytes;
  } catch (_) {
    return null;
  }
}

function bytesToBigIntLE(bytes) {
  let value = 0n;

  for (let i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8n) | BigInt(bytes[i]);
  }

  return value;
}

function bigIntToBytesLE(value, length) {
  const bytes = new Uint8Array(length);
  let current = value;

  for (let i = 0; i < length; i++) {
    bytes[i] = Number(current & 0xffn);
    current >>= 8n;
  }

  return bytes;
}

function mod(value, modulus) {
  const result = value % modulus;
  return result >= 0n ? result : result + modulus;
}

function modPow(base, exponent, modulus) {
  let result = 1n;
  let current = mod(base, modulus);
  let power = exponent;

  while (power > 0n) {
    if (power & 1n) {
      result = (result * current) % modulus;
    }

    current = (current * current) % modulus;
    power >>= 1n;
  }

  return result;
}

function modInverse(value, modulus) {
  if (value === 0n) {
    throw new Error("inverse of zero");
  }

  return modPow(value, modulus - 2n, modulus);
}

function curve25519PublicToEd25519Public(
  montgomeryPublicKey,
  signBit,
) {
  if (montgomeryPublicKey.length !== 32) {
    return null;
  }

  if (signBit !== 0 && signBit !== 1) {
    return null;
  }

  const u = bytesToBigIntLE(montgomeryPublicKey);

  if (u >= CURVE25519_P) {
    return null;
  }

  const denominator = mod(u + 1n, CURVE25519_P);

  if (denominator === 0n) {
    return null;
  }

  const y = mod(
    (u - 1n) * modInverse(denominator, CURVE25519_P),
    CURVE25519_P,
  );

  const encoded = bigIntToBytesLE(y, 32);

  encoded[31] &= 0x7f;
  encoded[31] |= signBit << 7;

  return encoded;
}

async function verifySignalIdentitySignature({
  identityKey,
  message,
  signature,
}) {
  const publicKey = decodeBase64(identityKey);
  const sig = decodeBase64(signature);

  if (!publicKey || publicKey.length !== 33 || publicKey[0] !== 0x05) {
    return false;
  }

  if (!sig || sig.length !== 64) {
    return false;
  }

  try {
    /*
     * Signal/XEd25519:
     * identityKey = 0x05 || little-endian Curve25519 u-coordinate.
     *
     * XEdDSA convert_mont() maps that Montgomery u-coordinate to
     * an Edwards public key and forces the Edwards sign bit to zero.
     */
    const montgomeryPublicKey = publicKey.slice(1);

    /*
     * XEdDSA first validates the encoded Montgomery u-coordinate.
     * convert_mont() masks the high bit only when converting it.
     */
    const u = bytesToBigIntLE(montgomeryPublicKey);

    if (u >= CURVE25519_P) {
      return false;
    }

    const rBytes = sig.slice(0, 32);
    const sBytes = sig.slice(32);

    // libsignal_protocol_dart stores the Edwards public-key sign bit
    // in signature[63]. It is metadata, not part of scalar s.
    const signBit = (sBytes[31] >>> 7) & 1;
    sBytes[31] &= 0x7f;

    /*
     * R is a compressed Edwards point:
     *   - low 255 bits encode y
     *   - high bit encodes the Edwards sign
     *
     * The sign bit must not be treated as part of y.
     */
    const rYBytes = rBytes.slice();
    rYBytes[31] &= 0x7f;

    const rY = bytesToBigIntLE(rYBytes);
    const s = bytesToBigIntLE(sBytes);

    /*
     * XEdDSA uses a 253-bit scalar range for s.
     */
    const CURVE25519_Q =
      (1n << 252n) +
      27742317777372353535851937790883648493n;

    if (rY >= CURVE25519_P || s >= CURVE25519_Q) {
      return false;
    }

    const montgomeryPublicKeyForConversion =
      montgomeryPublicKey.slice();

    montgomeryPublicKeyForConversion[31] &= 0x7f;

    const edPublicKey = curve25519PublicToEd25519Public(
      montgomeryPublicKeyForConversion,
      signBit,
    );

    if (!edPublicKey) {
      return false;
    }

    /*
     * XEd25519 signatures are Ed25519-compatible after the public-key
     * conversion above. WebCrypto provides the Ed25519 verification
     * primitive; the conversion itself follows Signal XEdDSA.
     */
    const cryptoKey = await crypto.subtle.importKey(
      "raw",
      edPublicKey,
      {
        name: "Ed25519",
      },
      false,
      ["verify"],
    );

    const messageBytes = new TextEncoder().encode(message);

    return await crypto.subtle.verify(
      {
        name: "Ed25519",
      },
      cryptoKey,
      new Uint8Array([...rBytes, ...sBytes]),
      messageBytes,
    );
  } catch (error) {
    console.log("PUSH_SIGNATURE_VERIFY_FAILED", error);
    return false;
  }
}
function validSignalPublicKey(value) {
  const bytes = decodeBase64(value);

  return Boolean(
    bytes &&
    bytes.length === 33 &&
    bytes[0] === 0x05,
  );
}

function validSignalSignature(value) {
  const bytes = decodeBase64(value);

  return Boolean(
    bytes &&
    bytes.length === 64,
  );
}

function validSignalBundle(bundle, requirePreKey = true) {
  if (!bundle || typeof bundle !== "object") {
    return false;
  }

  if (!Number.isInteger(bundle.registrationId) ||
      bundle.registrationId < 1 ||
      bundle.registrationId > 0x7fffffff) {
    return false;
  }

  if (!Number.isInteger(bundle.deviceId) ||
      bundle.deviceId < 1 ||
      bundle.deviceId > 0x7fffffff) {
    return false;
  }

  if (!validSignalPublicKey(bundle.identityKey)) {
    return false;
  }

  const signedPreKey = bundle.signedPreKey;

  if (!signedPreKey ||
      typeof signedPreKey !== "object" ||
      !Number.isInteger(signedPreKey.keyId) ||
      signedPreKey.keyId < 0 ||
      signedPreKey.keyId > 0x7fffffff ||
      !validSignalPublicKey(signedPreKey.publicKey) ||
      !validSignalSignature(signedPreKey.signature)) {
    return false;
  }

  if (bundle.preKey == null) {
    return !requirePreKey;
  }

  if (!bundle.preKey ||
      typeof bundle.preKey !== "object" ||
      !Number.isInteger(bundle.preKey.keyId) ||
      bundle.preKey.keyId < 0 ||
      bundle.preKey.keyId > 0x7fffffff ||
      !validSignalPublicKey(bundle.preKey.publicKey)) {
    return false;
  }

  return true;
}

function publicUserRecord(user) {
  return {
    nickname: user.nickname,
    bundle: user.bundle,
  };
}


function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

export class DirectoryStore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/nickname") {
      const nickname = normalizeNickname(
        url.searchParams.get("nickname"),
      );

      if (!validNickname(nickname)) {
        return json({
          available: false,
          error: "Invalid nickname",
        }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      return json({
        available: !user,
        nickname,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/nickname/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/nickname/".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({
          available: false,
          error: "Invalid nickname",
        }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      return json({
        available: !user,
        nickname,
      });
    }

    // The only public GUARD identity API returns the caller's own code after
    // a signed proof from the registered Signal identity key. There is no
    // public code-to-nickname lookup or account-removal operation.
    if (request.method === "POST" &&
        url.pathname === "/v1/guard/code/challenge") {
      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body?.nickname);
      const deviceId = body?.deviceId;
      const registrationId = body?.registrationId;

      if (!validNickname(nickname) ||
          !Number.isInteger(deviceId) || deviceId < 1 || deviceId > 0x7fffffff ||
          !Number.isInteger(registrationId) || registrationId < 1 ||
          registrationId > 0x7fffffff) {
        return json({ error: "Invalid GUARD identity request" }, 400);
      }

      const now = Date.now();
      const challenge = createPushChallenge();
      const expiresAt = now + GUARD_CHALLENGE_TTL_MS;
      const result = await this.ctx.storage.transaction(async (txn) => {
        const user = await txn.get(`user:${nickname}`);
        if (!guardDeviceMatches(user, deviceId, registrationId)) {
          return { status: 404, error: "Registered device not found" };
        }

        const limitKey = `guard-challenge-limit:${nickname}`;
        const previous = await txn.get(limitKey);
        const window = previous?.expiresAt > now
          ? previous
          : { count: 0, expiresAt: now + GUARD_CHALLENGE_WINDOW_MS };

        if (window.count >= GUARD_CHALLENGE_WINDOW_MAX) {
          return {
            status: 429,
            error: "Too many GUARD identity challenges",
            retryAfterSeconds: Math.ceil((window.expiresAt - now) / 1000),
          };
        }

        await txn.put(limitKey, { ...window, count: window.count + 1 });
        await txn.put(
          guardChallengeKey(nickname, deviceId, registrationId),
          { challenge, expiresAt },
        );
        return { challenge, expiresAt };
      });

      if (result.error) {
        return json({
          error: result.error,
          ...(result.retryAfterSeconds
            ? { retryAfterSeconds: result.retryAfterSeconds }
            : {}),
        }, result.status);
      }

      return json(result);
    }

    if (request.method === "POST" && url.pathname === "/v1/guard/code") {
      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body?.nickname);
      const deviceId = body?.deviceId;
      const registrationId = body?.registrationId;
      const challenge = body?.challenge;
      const signature = body?.signature;

      if (!validNickname(nickname) ||
          !Number.isInteger(deviceId) || deviceId < 1 || deviceId > 0x7fffffff ||
          !Number.isInteger(registrationId) || registrationId < 1 ||
          registrationId > 0x7fffffff ||
          typeof challenge !== "string" || challenge.length > 128 ||
          !challenge || !validSignalSignature(signature)) {
        return json({ error: "Invalid GUARD identity proof" }, 400);
      }

      const key = `user:${nickname}`;
      const challengeKey = guardChallengeKey(nickname, deviceId, registrationId);
      const user = await this.ctx.storage.get(key);
      const stored = await this.ctx.storage.get(challengeKey);

      if (!guardDeviceMatches(user, deviceId, registrationId) ||
          !stored || stored.challenge !== challenge ||
          stored.expiresAt <= Date.now()) {
        return json({ error: "Invalid or expired GUARD identity proof" }, 401);
      }

      const verified = await verifySignalIdentitySignature({
        identityKey: user.bundle.identityKey,
        message: guardIdentityMessage({
          nickname, deviceId, registrationId, challenge,
        }),
        signature,
      });

      // Re-check the challenge and account *after* signature verification.
      // Consuming it in the same transaction makes proofs one-time-use and
      // prevents a newer challenge from being accidentally consumed.
      const result = await this.ctx.storage.transaction(async (txn) => {
        const currentUser = await txn.get(key);
        const currentChallenge = await txn.get(challengeKey);

        if (!guardDeviceMatches(currentUser, deviceId, registrationId) ||
            currentUser.bundle.identityKey !== user.bundle.identityKey ||
            !currentChallenge || currentChallenge.challenge !== challenge ||
            currentChallenge.expiresAt <= Date.now()) {
          return { error: "Invalid or expired GUARD identity proof", status: 401 };
        }

        await txn.delete(challengeKey);
        if (!verified) {
          return { error: "Invalid or expired GUARD identity proof", status: 401 };
        }

        const { code } = await ensureGuardCode(txn, nickname, currentUser);
        return { guardCode: code };
      });

      if (result.error) {
        return json({ error: result.error }, result.status);
      }

      return json(result);
    }

    if (request.method === "POST" &&
        url.pathname === "/v1/guard/cases/challenge") {
      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body?.nickname);
      const deviceId = body?.deviceId;
      const registrationId = body?.registrationId;
      const purpose = body?.purpose;
      if (!validNickname(nickname) ||
          !Number.isInteger(deviceId) || deviceId < 1 || deviceId > 0x7fffffff ||
          !Number.isInteger(registrationId) || registrationId < 1 ||
          registrationId > 0x7fffffff || !GUARD_CASE_ACTIONS.has(purpose)) {
        return json({ error: "Invalid Guard case challenge request" }, 400);
      }

      const now = Date.now();
      const challenge = createPushChallenge();
      const expiresAt = now + GUARD_CASE_CHALLENGE_TTL_MS;
      const result = await this.ctx.storage.transaction(async (txn) => {
        const user = await txn.get(`user:${nickname}`);
        if (!guardDeviceMatches(user, deviceId, registrationId)) {
          return { error: "Registered device not found", httpStatus: 404 };
        }

        const limitKey = `guard-case-challenge-limit:${nickname}`;
        const previous = await txn.get(limitKey);
        const window = previous?.expiresAt > now
          ? previous
          : { count: 0, expiresAt: now + GUARD_CASE_CHALLENGE_WINDOW_MS };
        if (window.count >= GUARD_CASE_CHALLENGE_WINDOW_MAX) {
          return {
            error: "Too many Guard case challenges",
            httpStatus: 429,
            retryAfterSeconds: Math.ceil((window.expiresAt - now) / 1000),
          };
        }

        await txn.put(limitKey, { ...window, count: window.count + 1 });
        await txn.put(
          guardCaseChallengeKey(nickname, deviceId, registrationId),
          { challenge, purpose, expiresAt },
        );
        return { challenge, expiresAt };
      });

      if (result.error) {
        return json({
          error: result.error,
          ...(result.retryAfterSeconds
            ? { retryAfterSeconds: result.retryAfterSeconds }
            : {}),
        }, result.httpStatus);
      }
      return json(result);
    }

    // No Guard case is ever approved or executed from these endpoints. Only
    // the authenticated requester may submit, check, or cancel their case.
    const guardCaseRoute = url.pathname.match(
      /^\/v1\/guard\/cases\/([a-f0-9-]{36})\/(status|cancel)$/i,
    );
    if (request.method === "POST" &&
        (url.pathname === "/v1/guard/cases" || guardCaseRoute)) {
      const action = guardCaseRoute ? guardCaseRoute[2].toLowerCase() : "submit";
      const caseId = guardCaseRoute?.[1].toLowerCase() || "";
      if (caseId && !GUARD_CASE_ID_PATTERN.test(caseId)) {
        return json({ error: "Invalid Guard case ID" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const fields = guardCaseProofFields(body);
      if (!fields) {
        return json({ error: "Invalid Guard case proof" }, 400);
      }

      if (action === "submit") {
        const targetCode = body?.targetCode;
        const reason = body?.reason;
        const details = body?.details;
        const idempotencyKey = body?.idempotencyKey;
        if (!validGuardCode(targetCode) || !GUARD_CASE_REASONS.has(reason) ||
            typeof details !== "string" ||
            details !== details.trim() || details.length < 10 ||
            details.length > 2000 ||
            typeof idempotencyKey !== "string" ||
            !GUARD_CASE_ID_PATTERN.test(idempotencyKey)) {
          return json({ error: "Invalid Guard case details" }, 400);
        }
        Object.assign(fields, { targetCode, reason, details, idempotencyKey });
      }

      const result = await handleGuardCaseAction(
        this.ctx.storage, fields, action, caseId,
      );
      if (result.error) {
        return json({
          error: result.error,
          ...(result.retryAfterSeconds
            ? { retryAfterSeconds: result.retryAfterSeconds }
            : {}),
        }, result.httpStatus);
      }
      return json(result);
    }

    // Read-only operations access for eventual Moderator integration. This
    // secret is independent of relay authentication and is disabled by default.
    // It never grants case approval or account-removal privileges.
    const guardReviewDetail = url.pathname.match(
      /^\/v1\/internal\/guard-cases\/([a-f0-9-]{36})$/i,
    );
    const guardReviewList = url.pathname === "/v1/internal/guard-cases";
    const guardAuditBackfill =
      url.pathname === "/v1/internal/guard-cases/backfill-audit";
    if ((request.method === "GET" && (guardReviewList || guardReviewDetail)) ||
        (request.method === "POST" && guardAuditBackfill)) {
      const expected = this.env.GUARD_REVIEW_SECRET;
      if (typeof expected !== "string" || expected.length < 32 ||
          expected === this.env.RELAY_SHARED_SECRET ||
          expected === this.env.GUARD_MIGRATION_SECRET ||
          request.headers.get("Authorization") !== `Bearer ${expected}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      if (guardReviewDetail) {
        const caseId = guardReviewDetail[1].toLowerCase();
        if (!GUARD_CASE_ID_PATTERN.test(caseId)) {
          return json({ error: "Invalid Guard case ID" }, 400);
        }

        const record = await this.ctx.storage.get(`guard-case:${caseId}`);
        if (!record) return json({ error: "Guard case not found" }, 404);

        const audit = await verifyGuardAudit(this.ctx.storage, record);
        if (audit.state === "corrupt") {
          return json({ error: "Guard audit integrity violation" }, 409);
        }
        return json({
          case: record,
          auditStatus: audit.state,
          events: audit.events,
        });
      }

      let limit;
      let after;
      if (guardReviewList) {
        const rawLimit = url.searchParams.get("limit");
        limit = rawLimit == null ? 25 : Number(rawLimit);
        after = url.searchParams.get("after");
      } else {
        let body;
        try {
          body = await request.json();
        } catch (_) {
          return json({ error: "Invalid JSON" }, 400);
        }
        limit = body?.limit ?? 25;
        after = body?.after ?? null;
      }

      if (!Number.isInteger(limit) || limit < 1 ||
          limit > GUARD_REVIEW_MAX_PAGE ||
          (after !== null && !GUARD_CASE_ID_PATTERN.test(after))) {
        return json({ error: "Invalid Guard case cursor or limit" }, 400);
      }

      const options = {
        prefix: "guard-case:", limit: limit + 1,
        ...(after ? { startAfter: `guard-case:${after.toLowerCase()}` } : {}),
      };
      const entries = Array.from((await this.ctx.storage.list(options)).entries());
      const batch = entries.slice(0, limit);

      if (guardReviewList) {
        const cases = [];
        for (const [, record] of batch) {
          const audit = await verifyGuardAudit(this.ctx.storage, record);
          if (audit.state === "corrupt") {
            return json({ error: "Guard audit integrity violation" }, 409);
          }
          cases.push({
            ...guardCasePublicRecord(record),
            requester: record.requester,
            auditStatus: audit.state,
          });
        }
        return json({
          cases,
          nextCursor: entries.length > limit
            ? batch.at(-1)[0].substring("guard-case:".length) : null,
          done: entries.length <= limit,
        });
      }

      let migrated = 0;
      let processed = 0;
      for (const [key] of batch) {
        try {
          const changed = await this.ctx.storage.transaction(async (txn) => {
            const record = await txn.get(key);
            if (!record) return false;
            return backfillLegacyGuardAudit(txn, record, Date.now());
          });
          if (changed) migrated++;
          processed++;
        } catch (_) {
          // Earlier batches remain durable; reruns are safe and idempotent.
          return json({
            error: "Guard audit backfill halted on an invalid record",
            processed,
            migrated,
          }, 409);
        }
      }

      return json({
        processed,
        migrated,
        nextCursor: entries.length > limit
          ? batch.at(-1)[0].substring("guard-case:".length) : null,
        done: entries.length <= limit,
      });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/turn-credentials/challenge"
    ) {
      let body;

      try {
        body = await request.json();
      } catch {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body.nickname);
      const deviceId = Number(body.deviceId);
      const registrationId = Number(body.registrationId);

      if (
        !validNickname(nickname) ||
        !Number.isInteger(deviceId) ||
        deviceId < 1 ||
        deviceId > 0x7fffffff ||
        !Number.isInteger(registrationId) ||
        registrationId < 1 ||
        registrationId > 0x7fffffff
      ) {
        return json({ error: "Invalid TURN challenge request" }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      const bundle = user?.bundle;

      if (
        !bundle ||
        bundle.deviceId !== deviceId ||
        Number(bundle.registrationId) !== registrationId
      ) {
        return json({ error: "Device not registered" }, 404);
      }

      const challenge = createPushChallenge();
      const expiresAt = Date.now() + PUSH_CHALLENGE_TTL_MS;

      const challengeKey =
        `turn-challenge:${nickname}:${deviceId}:${registrationId}`;

      await this.ctx.storage.put(
        challengeKey,
        {
          challenge,
          expiresAt,
        },
      );

      return json({
        challenge,
        expiresAt,
      });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/turn-credentials"
    ) {
      let body;

      try {
        body = await request.json();
      } catch {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body.nickname);
      const deviceId = Number(body.deviceId);
      const registrationId = Number(body.registrationId);
      const challenge = String(body.challenge || "").trim();
      const signature = String(body.signature || "").trim();

      if (
        !validNickname(nickname) ||
        !Number.isInteger(deviceId) ||
        deviceId < 1 ||
        deviceId > 0x7fffffff ||
        !Number.isInteger(registrationId) ||
        registrationId < 1 ||
        registrationId > 0x7fffffff ||
        !challenge ||
        !signature
      ) {
        return json({ error: "Invalid TURN credential request" }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      const bundle = user?.bundle;

      if (
        !bundle ||
        bundle.deviceId !== deviceId ||
        Number(bundle.registrationId) !== registrationId
      ) {
        return json({ error: "Device not registered" }, 404);
      }

      const challengeKey =
        `turn-challenge:${nickname}:${deviceId}:${registrationId}`;

      const stored = await this.ctx.storage.get(challengeKey);

      if (
        !stored ||
        stored.challenge !== challenge ||
        Number(stored.expiresAt) < Date.now()
      ) {
        return json({ error: "Invalid or expired TURN challenge" }, 401);
      }

      const authMessage = JSON.stringify([
        "stellar-turn-v1",
        nickname,
        deviceId,
        registrationId,
        challenge,
      ]);

      const verified = await verifySignalIdentitySignature({
        identityKey: bundle.identityKey,
        message: authMessage,
        signature,
      });

      if (!verified) {
        return json({
          error: "Invalid TURN signature",
        }, 401);
      }

      await this.ctx.storage.delete(challengeKey);

      const turnKeyId = String(this.env.TURN_KEY_ID || "").trim();
      const turnKeySecret = String(this.env.TURN_KEY_SECRET || "").trim();

      if (!turnKeyId || !turnKeySecret) {
        return json({
          error: "TURN service is not configured",
        }, 503);
      }

      const turnUrl =
        "https://rtc.live.cloudflare.com/v1/turn/keys/" +
        encodeURIComponent(turnKeyId) +
        "/credentials/generate-ice-servers";

      let turnResponse;

      try {
        turnResponse = await fetch(turnUrl, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${turnKeySecret}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            ttl: 3600,
          }),
        });
      } catch (error) {
        console.error("TURN_UPSTREAM_FETCH_FAILED", JSON.stringify({
          errorName: error instanceof Error ? error.name : "UnknownError",
          message: String(
            error instanceof Error ? error.message : error
          ).slice(0, 240),
        }));

        return json({
          error: "TURN credential generation request failed",
        }, 502);
      }

      if (!turnResponse.ok) {
        const contentType =
          turnResponse.headers.get("content-type") || "";
        let providerError = "";

        try {
          const responseBody = await turnResponse.text();

          providerError = responseBody
            .replace(
              /Bearer\s+[^\s"'\\]}]+/gi,
              "Bearer [REDACTED]"
            )
            .replace(
              /(authorization|token|secret|api[_-]?key)(\s*["']?\s*[:=]\s*["']?)[^\s"'\\]},]+/gi,
              "$1$2[REDACTED]"
            )
            .slice(0, 400);
        } catch (error) {
          providerError =
            `<body-read-failed:${error instanceof Error ? error.name : "UnknownError"}>`;
        }

        console.error("TURN_UPSTREAM_HTTP_ERROR", JSON.stringify({
          status: turnResponse.status,
          contentType: contentType.slice(0, 100),
          providerError,
        }));

        return json({
          error: "TURN credential generation failed",
          status: turnResponse.status,
        }, 502);
      }

      const turnData = await turnResponse.json();

      return new Response(
        JSON.stringify(turnData),
        {
          status: 201,
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          },
        },
      );
    }
      if (
        request.method === "POST" &&
        url.pathname === "/v1/internal/relay-auth"
      ) {
      const authorization =
        request.headers.get("Authorization") || "";

      const expectedSecret =
        this.env.RELAY_SHARED_SECRET || "";

      if (
        !expectedSecret ||
        authorization !== `Bearer ${expectedSecret}`
      ) {
        return json({ error: "Unauthorized" }, 401);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(
        typeof body.nickname === "string"
          ? body.nickname
          : "",
      );

      const deviceId = Number(body.deviceId);
      const registrationId = Number(body.registrationId);

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge
          : "";

      const signature =
        typeof body.signature === "string"
          ? body.signature
          : "";

      const nicknameValid = validNickname(nickname);
      const deviceIdValid =
        Number.isInteger(deviceId) &&
        deviceId >= 1 &&
        deviceId <= 0x7fffffff;
      const registrationIdValid =
        Number.isInteger(registrationId) &&
        registrationId >= 1 &&
        registrationId <= 0x7fffffff;
      const challengePresent = challenge.length > 0;
      const signaturePresent = signature.length > 0;

      if (
        !nicknameValid ||
        !deviceIdValid ||
        !registrationIdValid ||
        !challengePresent ||
        !signaturePresent
      ) {
        console.warn("DIRECTORY_RELAY_AUTH_INVALID_FIELDS", JSON.stringify({
          nicknameValid,
          deviceIdValid,
          registrationIdValid,
          challengePresent,
          signaturePresent,
        }));

        return json({
          error: "Invalid relay auth request",
        }, 400);
      }

      const user =
        await this.ctx.storage.get(`user:${nickname}`);

      if (!user || !user.bundle) {
        return json({
          error: "User not found",
        }, 404);
      }

      const bundle = user.bundle;

      if (
        Number(bundle.deviceId) !== deviceId ||
        Number(bundle.registrationId) !== registrationId
      ) {
        return json({
          error: "identity_mismatch",
        }, 409);
      }

      const authMessage = JSON.stringify([
        "stellar-relay-v1",
        nickname,
        deviceId,
        registrationId,
        challenge,
      ]);

      const verified =
        await verifySignalIdentitySignature({
          identityKey: bundle.identityKey,
          message: authMessage,
          signature,
        });

      if (!verified) {
        return json({
          error: "Invalid relay signature",
        }, 401);
      }

      return json({ ok: true });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/internal/moderation-auth"
    ) {
      const authorization =
        request.headers.get("Authorization") || "";

      const expectedSecret =
        this.env.RELAY_SHARED_SECRET || "";

      if (
        !expectedSecret ||
        authorization !== `Bearer ${expectedSecret}`
      ) {
        return json({ error: "Unauthorized" }, 401);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(
        typeof body.nickname === "string"
          ? body.nickname
          : "",
      );

      const deviceId = Number(body.deviceId);
      const registrationId = Number(body.registrationId);

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge
          : "";

      const signature =
        typeof body.signature === "string"
          ? body.signature
          : "";

      if (
        !validNickname(nickname) ||
        !Number.isInteger(deviceId) ||
        deviceId <= 0 ||
        !Number.isInteger(registrationId) ||
        registrationId <= 0 ||
        !challenge ||
        !signature
      ) {
        return json({
          error: "Invalid moderation auth request",
        }, 400);
      }

      const user =
        await this.ctx.storage.get(`user:${nickname}`);

      if (!user || !user.bundle) {
        return json({
          error: "User not found",
        }, 404);
      }

      const bundle = user.bundle;

      if (
        Number(bundle.deviceId) !== deviceId ||
        Number(bundle.registrationId) !== registrationId
      ) {
        return json({
          error: "identity_mismatch",
        }, 409);
      }

      const authMessage = JSON.stringify([
        "stellar-moderation-v1",
        nickname,
        deviceId,
        registrationId,
        challenge,
      ]);

      const verified =
        await verifySignalIdentitySignature({
          identityKey: bundle.identityKey,
          message: authMessage,
          signature,
        });

      if (!verified) {
        return json({
          error: "Invalid moderation signature",
        }, 401);
      }

      return json({ ok: true });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/bundle")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/users/".length, url.pathname.length - "/bundle".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      if (!validSignalBundle(body.bundle, true)) {
        return json({ error: "Invalid bundle" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (existingBundle?.identityKey !== body.bundle.identityKey ||
          existingBundle?.registrationId !== body.bundle.registrationId ||
          existingBundle?.deviceId !== body.bundle.deviceId) {
        return json({ error: "Identity mismatch" }, 409);
      }

      const user = {
        ...existing,
        bundle: body.bundle,
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
        updated: true,
      });
    }


    if (request.method === "DELETE" &&
        url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const auth = request.headers.get("authorization") || "";
      const expected = this.env.RELAY_SHARED_SECRET || "";
      if (!expected || auth !== `Bearer ${expected}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const token =
        typeof body.token === "string"
          ? body.token.trim()
          : "";

      if (!token || token.length > 4096) {
        return json({ error: "Invalid push token" }, 400);
      }

      const key = `user:${nickname}`;

      const result = await this.ctx.storage.transaction(async (txn) => {
        const existing = await txn.get(key);

        if (!existing) {
          return {
            error: "User not found",
            status: 404,
          };
        }

        const registrations = Array.isArray(existing.pushRegistrations)
          ? existing.pushRegistrations.filter(
              (registration) =>
                registration &&
                typeof registration === "object" &&
                typeof registration.token === "string" &&
                registration.token,
            )
          : existing.push &&
            typeof existing.push === "object" &&
            typeof existing.push.token === "string" &&
            existing.push.token
            ? [
                {
                  token: existing.push.token,
                  platform: existing.push.platform,
                  updatedAt: existing.push.updatedAt,
                },
              ]
            : [];

        const nextRegistrations = registrations.filter(
          (registration) => registration.token !== token,
        );

        if (nextRegistrations.length === registrations.length) {
          return {
            ok: true,
            removed: false,
          };
        }

        const nextLegacyPush = nextRegistrations[0]
          ? {
              token: nextRegistrations[0].token,
              platform: nextRegistrations[0].platform,
              updatedAt: nextRegistrations[0].updatedAt,
            }
          : null;

        const user = {
          ...existing,
          pushRegistrations: nextRegistrations,
          push: nextLegacyPush,
        };

        await txn.put(key, user);

        return {
          ok: true,
          removed: true,
        };
      });

      if (result?.error) {
        return json({
          error: result.error,
        }, result.status);
      }

      return json({
        ok: true,
        nickname,
        removed: result?.removed === true,
      });
    }

    if (request.method === "POST" &&
        url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token/challenge")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token/challenge".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const deviceId =
        typeof body.deviceId === "number"
          ? body.deviceId
          : null;

      const registrationId =
        typeof body.registrationId === "number"
          ? body.registrationId
          : null;

      if (!Number.isInteger(deviceId) ||
          !Number.isInteger(registrationId)) {
        return json({
          error: "Invalid device identity",
        }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (!existingBundle ||
          typeof existingBundle.registrationId !== "number" ||
          typeof existingBundle.deviceId !== "number" ||
          existingBundle.registrationId !== registrationId ||
          existingBundle.deviceId !== deviceId) {
        return json({
          error: "Identity mismatch",
        }, 409);
      }

      const challengeKey =
        `push-challenge:${nickname}:${deviceId}:${registrationId}`;

      const now = Date.now();
      const stored = await this.ctx.storage.get(challengeKey);

      if (stored &&
          typeof stored.challenge === "string" &&
          typeof stored.expiresAt === "number" &&
          stored.expiresAt > now) {
        return json({
          nickname,
          challenge: stored.challenge,
          expiresAt: stored.expiresAt,
        });
      }

      const challenge = createPushChallenge();
      const expiresAt = now + PUSH_CHALLENGE_TTL_MS;

      await this.ctx.storage.put(
        challengeKey,
        {
          challenge,
          expiresAt,
        },
      );

      return json({
        nickname,
        challenge,
        expiresAt,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const auth = request.headers.get("authorization") || "";
      const expected = this.env.RELAY_SHARED_SECRET || "";
      if (!expected || auth !== `Bearer ${expected}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );
      if (!validNickname(nickname)) return json({ error: "Invalid nickname" }, 400);

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);
      if (!existing) return json({ error: "User not found" }, 404);

      const pushRegistrations = Array.isArray(existing.pushRegistrations)
        ? existing.pushRegistrations
        : [];

      return json({
        nickname,
        pushRegistrations,
        push: existing.push ?? pushRegistrations[0] ?? null,
      });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const token =
        typeof body.token === "string"
          ? body.token.trim()
          : "";

      const platform =
        typeof body.platform === "string"
          ? body.platform.trim().toLowerCase()
          : "";

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge.trim()
          : "";

      const signature =
        typeof body.signature === "string"
          ? body.signature.trim()
          : "";

      if (!token ||
          token.length > 4096 ||
          !["android", "ios"].includes(platform) ||
          !challenge ||
          challenge.length > 512 ||
          !signature) {
        return json({ error: "Invalid push authorization" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (!existingBundle ||
          typeof existingBundle.identityKey !== "string" ||
          typeof existingBundle.registrationId !== "number" ||
          typeof existingBundle.deviceId !== "number") {
        return json({
          error: "Push authorization unavailable",
        }, 409);
      }

      const challengeKey =
        `push-challenge:${nickname}:${existingBundle.deviceId}:${existingBundle.registrationId}`;
      const storedChallenge =
        await this.ctx.storage.get(challengeKey);

      const now = Date.now();

      if (!storedChallenge ||
          storedChallenge.challenge !== challenge ||
          typeof storedChallenge.expiresAt !== "number" ||
          storedChallenge.expiresAt <= now) {
        if (storedChallenge) {
          await this.ctx.storage.delete(challengeKey);
        }

        return json({
          error: "Invalid or expired push challenge",
        }, 401);
      }

      const authMessage = buildPushAuthMessage({
        nickname,
        deviceId: existingBundle.deviceId,
        registrationId: existingBundle.registrationId,
        platform,
        token,
        challenge,
      });

      const validSignature =
        await verifySignalIdentitySignature({
          identityKey: existingBundle.identityKey,
          message: authMessage,
          signature,
        });

      if (!validSignature) {
        return json({
          error: "Invalid push authorization",
        }, 401);
      }

      const result = await this.ctx.storage.transaction(async (txn) => {
        const currentUser = await txn.get(key);

        if (!currentUser) {
          return {
            error: "User not found",
            status: 404,
          };
        }

        const currentBundle = currentUser.bundle;

        if (!currentBundle ||
            typeof currentBundle.identityKey !== "string" ||
            typeof currentBundle.registrationId !== "number" ||
            typeof currentBundle.deviceId !== "number" ||
            currentBundle.identityKey !== existingBundle.identityKey ||
            currentBundle.registrationId !== existingBundle.registrationId ||
            currentBundle.deviceId !== existingBundle.deviceId) {
          return {
            error: "Push authorization unavailable",
            status: 409,
          };
        }

        const currentChallenge =
          await txn.get(challengeKey);

        if (!currentChallenge ||
            currentChallenge.challenge !== challenge ||
            typeof currentChallenge.expiresAt !== "number" ||
            currentChallenge.expiresAt <= Date.now()) {
          if (currentChallenge) {
            await txn.delete(challengeKey);
          }

          return {
            error: "Invalid or expired push challenge",
            status: 401,
          };
        }

        const registrations = Array.isArray(currentUser.pushRegistrations)
          ? currentUser.pushRegistrations.filter(
              (registration) =>
                registration &&
                typeof registration === "object" &&
                typeof registration.token === "string" &&
                typeof registration.platform === "string" &&
                typeof registration.deviceId === "number" &&
                typeof registration.registrationId === "number",
            )
          : [];

        if (registrations.length === 0 &&
            currentUser.push &&
            typeof currentUser.push === "object" &&
            typeof currentUser.push.token === "string" &&
            typeof currentUser.push.platform === "string") {
          registrations.push({
            token: currentUser.push.token,
            platform: currentUser.push.platform,
            deviceId: currentBundle.deviceId,
            registrationId: currentBundle.registrationId,
            updatedAt: typeof currentUser.push.updatedAt === "number"
                ? currentUser.push.updatedAt
                : now,
          });
        }

        const nextRegistrations = registrations.filter(
          (registration) =>
            registration.deviceId !== currentBundle.deviceId ||
            registration.registrationId !== currentBundle.registrationId ||
            registration.platform !== platform,
        );

        const withoutDuplicateToken = nextRegistrations.filter(
          (registration) => registration.token !== token,
        );

        withoutDuplicateToken.push({
          token,
          platform,
          deviceId: currentBundle.deviceId,
          registrationId: currentBundle.registrationId,
          updatedAt: now,
        });

        const user = {
          ...currentUser,
          pushRegistrations: withoutDuplicateToken,
          push: {
            token,
            platform,
            updatedAt: now,
          },
        };

        await txn.delete(challengeKey);
        await txn.put(key, user);

        return {
          ok: true,
        };
      });

      if (result?.error) {
        return json({
          error: result.error,
        }, result.status);
      }

      return json({
        ok: true,
        nickname,
        registered: true,
      });
    }


    // Profile photos are public profile data. Writes require a signature
    // from the Signal identity key currently registered for this device.
    const photoChallengeMatch = url.pathname.match(
      /^\/v1\/users\/([^/]+)\/profile-photo\/challenge$/,
    );

    if (request.method === "POST" && photoChallengeMatch) {
      let nickname;

      try {
        nickname = normalizeNickname(decodeURIComponent(photoChallengeMatch[1]));
      } catch (_) {
        return json({ error: "Invalid nickname" }, 400);
      }

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const { deviceId, registrationId, operation } = body || {};

      if (!Number.isInteger(deviceId) ||
          deviceId < 1 ||
          deviceId > 0x7fffffff ||
          !Number.isInteger(registrationId) ||
          registrationId < 1 ||
          registrationId > 0x7fffffff ||
          !["put", "delete"].includes(operation)) {
        return json({ error: "Invalid profile photo challenge request" }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);
      const bundle = user?.bundle;

      if (!bundle ||
          bundle.deviceId !== deviceId ||
          Number(bundle.registrationId) !== registrationId ||
          typeof bundle.identityKey !== "string") {
        return json({ error: "Device not registered" }, 404);
      }

      const challenge = createPushChallenge();
      const expiresAt = Date.now() + PUSH_CHALLENGE_TTL_MS;
      const challengeKey = profilePhotoChallengeKey(
        nickname,
        deviceId,
        registrationId,
        operation,
      );

      await this.ctx.storage.put(challengeKey, { challenge, expiresAt });

      return json({ nickname, challenge, expiresAt });
    }

    const photoRouteMatch = url.pathname.match(
      /^\/v1\/users\/([^/]+)\/profile-photo$/,
    );

    if (photoRouteMatch) {
      let nickname;

      try {
        nickname = normalizeNickname(decodeURIComponent(photoRouteMatch[1]));
      } catch (_) {
        return json({ error: "Invalid nickname" }, 400);
      }

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      const photoKey = profilePhotoStorageKey(nickname);

      if (request.method === "GET") {
        const photo = await this.ctx.storage.get(photoKey);

        if (!photo ||
            typeof photo.photo !== "string" ||
            !PROFILE_PHOTO_MIME_TYPES.has(photo.mimeType) ||
            typeof photo.updatedAt !== "number") {
          return json({ error: "Profile photo not found" }, 404);
        }

        return json({
          nickname,
          photo: photo.photo,
          mimeType: photo.mimeType,
          updatedAt: photo.updatedAt,
        });
      }

      if (request.method !== "PUT" && request.method !== "DELETE") {
        return json({ error: "Method not allowed" }, 405);
      }

      const contentLength = Number(request.headers.get("content-length") || "0");
      if (Number.isFinite(contentLength) &&
          contentLength > PROFILE_PHOTO_MAX_BYTES * 2 + 16384) {
        return json({ error: "Profile photo request too large" }, 413);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const { deviceId, registrationId, challenge, signature } = body || {};
      const operation = request.method === "PUT" ? "put" : "delete";

      if (!Number.isInteger(deviceId) ||
          deviceId < 1 ||
          deviceId > 0x7fffffff ||
          !Number.isInteger(registrationId) ||
          registrationId < 1 ||
          registrationId > 0x7fffffff ||
          typeof challenge !== "string" ||
          challenge.length < 20 ||
          challenge.length > 128 ||
          typeof signature !== "string" ||
          signature.length > 256) {
        return json({ error: "Invalid profile photo authorization" }, 400);
      }

      let photoBytes = null;
      let mimeType = "";
      let sha256 = "";

      if (operation === "put") {
        mimeType = typeof body.mimeType === "string"
          ? body.mimeType.trim().toLowerCase()
          : "";

        const encodedPhoto = typeof body.photo === "string" ? body.photo : "";

        if (!PROFILE_PHOTO_MIME_TYPES.has(mimeType) ||
            encodedPhoto.length === 0 ||
            encodedPhoto.length > Math.ceil(PROFILE_PHOTO_MAX_BYTES * 4 / 3) + 8) {
          return json({ error: "Invalid profile photo data" }, 400);
        }

        photoBytes = decodeBase64(encodedPhoto);

        if (!photoBytes ||
            !validProfilePhotoBytes(photoBytes, mimeType)) {
          return json({ error: "Invalid profile photo format or size" }, 400);
        }

        const digest = new Uint8Array(
          await crypto.subtle.digest("SHA-256", photoBytes),
        );
        sha256 = bytesToHex(digest);
      }

      const userKey = `user:${nickname}`;
      const existingUser = await this.ctx.storage.get(userKey);
      const existingBundle = existingUser?.bundle;

      if (!existingBundle ||
          existingBundle.deviceId !== deviceId ||
          Number(existingBundle.registrationId) !== registrationId ||
          typeof existingBundle.identityKey !== "string") {
        return json({ error: "Device not registered" }, 409);
      }

      const challengeKey = profilePhotoChallengeKey(
        nickname,
        deviceId,
        registrationId,
        operation,
      );

      const storedChallenge = await this.ctx.storage.get(challengeKey);

      if (!storedChallenge ||
          storedChallenge.challenge !== challenge ||
          typeof storedChallenge.expiresAt !== "number" ||
          storedChallenge.expiresAt <= Date.now()) {
        return json({ error: "Invalid or expired profile photo challenge" }, 401);
      }

      const message = buildProfilePhotoAuthMessage({
        nickname,
        deviceId,
        registrationId,
        operation,
        challenge,
        mimeType,
        sha256,
      });

      const signatureValid = await verifySignalIdentitySignature({
        identityKey: existingBundle.identityKey,
        message,
        signature,
      });

      if (!signatureValid) {
        return json({ error: "Invalid profile photo signature" }, 401);
      }

      const result = await this.ctx.storage.transaction(async (txn) => {
        const currentUser = await txn.get(userKey);
        const currentBundle = currentUser?.bundle;

        if (!currentBundle ||
            currentBundle.identityKey !== existingBundle.identityKey ||
            currentBundle.deviceId !== deviceId ||
            Number(currentBundle.registrationId) !== registrationId) {
          return { error: "Device identity changed", status: 409 };
        }

        const currentChallenge = await txn.get(challengeKey);

        if (!currentChallenge ||
            currentChallenge.challenge !== challenge ||
            typeof currentChallenge.expiresAt !== "number" ||
            currentChallenge.expiresAt <= Date.now()) {
          if (currentChallenge) {
            await txn.delete(challengeKey);
          }
          return {
            error: "Challenge already used or expired",
            status: 401,
          };
        }

        await txn.delete(challengeKey);

        if (operation === "put") {
          await txn.put(photoKey, {
            photo: bytesToBase64(photoBytes),
            mimeType,
            updatedAt: Date.now(),
          });
        } else {
          await txn.delete(photoKey);
        }

        return { ok: true };
      });

      if (result.error) {
        return json({ error: result.error }, result.status);
      }

      return json({
        ok: true,
        nickname,
        operation,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/users/".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      if (!user) {
        return json({ error: "User not found" }, 404);
      }

      return json(publicUserRecord(user));
    }

    if (request.method === "POST" && url.pathname === "/v1/register") {
      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body.nickname);

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      if (!validSignalBundle(body.bundle, true)) {
        return json({ error: "Invalid bundle" }, 400);
      }

      const result = await this.ctx.storage.transaction(async (txn) => {
        const key = `user:${nickname}`;
        if (await txn.get(key)) {
          return { registered: false };
        }

        await ensureGuardCode(txn, nickname, {
          nickname,
          bundle: body.bundle,
        });
        return { registered: true };
      });

      if (!result.registered) {
        return json({
          error: "Nickname already registered",
        }, 409);
      }

      // GUARD codes are deliberately absent from registration responses.
      // Owners retrieve their own codes with a signed challenge above.
      return json({
        ok: true,
        nickname,
      }, 201);
    }

    // Explicit, resumable legacy-account backfill. Disabled until operators
    // configure a separate migration secret; never runs on normal user reads.
    if (request.method === "POST" &&
        url.pathname === "/v1/internal/guard-codes/migrate") {
      const expectedSecret = this.env.GUARD_MIGRATION_SECRET;
      if (!expectedSecret ||
          request.headers.get("Authorization") !== `Bearer ${expectedSecret}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const limit = body?.limit ?? 25;
      const after = body?.after ?? null;
      if (!Number.isInteger(limit) || limit < 1 ||
          limit > GUARD_MIGRATION_MAX_BATCH ||
          (after !== null && !validNickname(after))) {
        return json({ error: "Invalid migration cursor or limit" }, 400);
      }

      const options = { prefix: "user:", limit: limit + 1 };
      if (after !== null) {
        options.startAfter = `user:${after}`;
      }

      const page = await this.ctx.storage.list(options);
      const entries = Array.from(page.entries());
      const batch = entries.slice(0, limit);
      let created = 0;

      for (const [key] of batch) {
        const nickname = key.substring("user:".length);
        const result = await this.ctx.storage.transaction(async (txn) => {
          const user = await txn.get(key);
          if (!user) return { created: false };
          return ensureGuardCode(txn, nickname, user);
        });
        if (result.created) created++;
      }

      const hasMore = entries.length > limit;
      const lastKey = batch.at(-1)?.[0];
      return json({
        processed: batch.length,
        created,
        alreadyAssigned: batch.length - created,
        nextCursor: hasMore ? lastKey.substring("user:".length) : null,
        done: !hasMore,
      });
    }

    if (
      request.method === "GET" &&
      url.pathname === "/v1/internal/moderation-users"
    ) {
      const authorization =
        request.headers.get("Authorization") || "";

      const expectedSecret =
        this.env.RELAY_SHARED_SECRET || "";

      if (
        !expectedSecret ||
        authorization !== `Bearer ${expectedSecret}`
      ) {
        return json({ error: "Unauthorized" }, 401);
      }

      const result = await this.ctx.storage.list({
        prefix: "user:",
      });

      const users = [];

      for (const value of result.values()) {
        if (value && typeof value.nickname === "string") {
          users.push(value.nickname);
        }
      }

      users.sort((a, b) => a.localeCompare(b));

      return json({ users });
    }

    if (request.method === "GET" && url.pathname === "/v1/users") {
      const result = await this.ctx.storage.list({
        prefix: "user:",
      });

      const users = [];

      for (const value of result.values()) {
        if (value && typeof value.nickname === "string") {
          users.push(value.nickname);
        }
      }

      users.sort();

      return json({ users });
    }

    return new Response("Not Found", { status: 404 });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "stellar-directory",
      });
    }

    if (
      !url.pathname.startsWith("/v1/")
    ) {
      return new Response("Not Found", {
        status: 404,
      });
    }

    const id = env.DIRECTORY.idFromName("global");
    const stub = env.DIRECTORY.get(id);

    return stub.fetch(request);
  },
};
