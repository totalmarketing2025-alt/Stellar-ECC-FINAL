function readU16(bytes, offset) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    .getUint16(offset, false);
}

function readU32(bytes, offset) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    .getUint32(offset, false);
}

function isValidStoryRecoveryEnvelope(value) {
  if (typeof value !== "string" || value.length > 4096) return false;
  let envelope;
  try { envelope = JSON.parse(value); } catch (_) { return false; }
  const base64 = (input, length, ending = "") => typeof input === "string" &&
    /^[A-Za-z0-9+/]+={0,2}$/.test(input) && input.length === length &&
    (ending === "" || (input.endsWith(ending) &&
      (ending !== "=" || !input.endsWith("=="))));
  return envelope?.version === 1 && base64(envelope.nonce, 16) &&
    base64(envelope.ciphertext, 44, "=") && base64(envelope.mac, 24, "==");
}

function decodeRecipientRoute(buffer) {
  const bytes = new Uint8Array(buffer);
  let offset = 0;

  if (bytes.length < 8) {
    throw new Error("Invalid envelope");
  }

  const version = readU16(bytes, offset);
  if (version !== 1 && version !== 2) {
    throw new Error("Unsupported envelope version");
  }
  offset += 2; // version
  offset += 4; // ttl

  if (offset + 2 > bytes.length) {
    throw new Error("Invalid envelope");
  }

  const tokenLen = readU16(bytes, offset);
  offset += 2;

  if (offset + tokenLen > bytes.length) {
    throw new Error("Invalid envelope");
  }

  offset += tokenLen;

  if (offset + 2 > bytes.length) {
    throw new Error("Invalid envelope");
  }

  const routeLen = readU16(bytes, offset);
  offset += 2;

  if (offset + routeLen > bytes.length) {
    throw new Error("Invalid envelope");
  }

  const route = new TextDecoder().decode(
    bytes.slice(offset, offset + routeLen),
  );

  offset += routeLen;

  if (version === 2) {
    if (offset + 1 > bytes.length) {
      throw new Error("Invalid envelope");
    }
    const ciphertextType = bytes[offset++];
    if (ciphertextType !== 2 && ciphertextType !== 3) {
      throw new Error("Invalid Signal ciphertext type");
    }
  }

  if (offset + 4 > bytes.length) {
    throw new Error("Invalid envelope");
  }

  const ciphertextLen = readU32(bytes, offset);
  offset += 4;

  if (offset + ciphertextLen !== bytes.length) {
    throw new Error("Invalid envelope");
  }

  return route;
}


function base64UrlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function stringToBase64Url(value) {
  return base64UrlEncode(new TextEncoder().encode(value));
}

async function readJsonWithLimit(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) throw new Error("INVALID_JSON");
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        try { await reader.cancel(); } catch (_) {}
        throw new Error("BODY_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    try { reader.releaseLock(); } catch (_) {}
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

function pemToArrayBuffer(pem) {
  const normalizedPem = pem.replace(/\\n/g, "\n");

  const base64 = normalizedPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");

  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);

  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }

  return bytes.buffer;
}

function getFcmRetryDelayMs(response, attempt) {
  const retryAfter = response
    ? response.headers.get("Retry-After")
    : null;

  if (retryAfter) {
    const seconds = Number(retryAfter);

    if (Number.isFinite(seconds) && seconds >= 0) {
      return Math.min(seconds * 1000, 10000);
    }

    const retryAt = Date.parse(retryAfter);

    if (Number.isFinite(retryAt)) {
      const delay = Math.max(0, retryAt - Date.now());
      return Math.min(delay, 10000);
    }
  }

  return Math.min(1000 * (2 ** attempt), 10000);
}

async function classifyFcmResponse(response) {
  let body = null;

  try {
    body = await response.json();
  } catch (_) {
    body = null;
  }

  const error = body?.error;
  const details = Array.isArray(error?.details)
    ? error.details.map((detail) => ({
        type: detail?.["@type"],
        errorCode: detail?.errorCode,
        fieldViolations: Array.isArray(detail?.fieldViolations)
          ? detail.fieldViolations.map((item) => ({
              field: item?.field,
              description: item?.description,
            }))
          : undefined,
      }))
    : [];

  console.error("FCM_RESPONSE", JSON.stringify({
    status: response.status,
    statusText: response.statusText,
    errorStatus: error?.status,
    errorMessage: error?.message,
    details,
  }));

  const responseDetails = Array.isArray(error?.details)
    ? error.details
    : [];

  const hasUnregisteredError = responseDetails.some(
    (detail) =>
      detail &&
      typeof detail === "object" &&
      detail["@type"] ===
        "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
      detail.errorCode === "UNREGISTERED",
  );

  if (hasUnregisteredError) {
    return "invalid-token";
  }

  if (
    response.status === 429 ||
    response.status === 500 ||
    response.status === 502 ||
    response.status === 503 ||
    response.status === 504
  ) {
    return "transient";
  }

  /*
   * INVALID_ARGUMENT is intentionally NOT treated as an invalid
   * registration. FCM may use INVALID_ARGUMENT for malformed
   * requests or invalid message parameters, so the token must
   * remain registered until FCM explicitly reports UNREGISTERED.
   */

  return "other";
}

async function removePushToken(directoryUrl, sharedSecret, nickname, token) {
  try {
    await fetch(
      `${directoryUrl}/v1/users/${encodeURIComponent(nickname)}/push-token`,
      {
        method: "DELETE",
        headers: {
          Authorization: `Bearer ${sharedSecret}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ token }),
      },
    );
  } catch (_) {
    // Push cleanup must never affect relay delivery.
  }
}

async function sendFcmMessage({
  projectId,
  accessToken,
  token,
  data,
  priority = "normal",
  platform = "unknown",
}) {
  for (let attempt = 0; attempt < 3; attempt++) {
    let response;

    try {
      response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token,
              data,
              android: {
                priority,
              },
            },
          }),
        },
      );
    } catch (error) {
      console.error("FCM_FETCH_ERROR", JSON.stringify({
        platform,
        kind: data?.type === "call" ? "call" : "message",
        attempt: attempt + 1,
        error: String(error),
      }));

      if (attempt === 2) {
        console.error("FCM_SEND_FAILURE", JSON.stringify({
          platform,
          kind: data?.type === "call" ? "call" : "message",
          reason: "network_error",
          attempts: attempt + 1,
        }));
        return "other";
      }

      await new Promise((resolve) =>
        setTimeout(resolve, getFcmRetryDelayMs(null, attempt)),
      );
      continue;
    }

    if (response.ok) {
      console.log("FCM_SEND_SUCCESS", JSON.stringify({
        status: response.status,
        platform,
        kind: data?.type === "call" ? "call" : "message",
        attempt: attempt + 1,
      }));
      return "sent";
    }

    const responseKind = await classifyFcmResponse(response);

    if (responseKind === "invalid-token") {
      console.error("FCM_SEND_FAILURE", JSON.stringify({
        status: response.status,
        platform,
        kind: data?.type === "call" ? "call" : "message",
        reason: "invalid_token",
        attempt: attempt + 1,
      }));
      return "invalid-token";
    }

    if (responseKind !== "transient" || attempt === 2) {
      console.error("FCM_SEND_FAILURE", JSON.stringify({
        status: response.status,
        platform,
        kind: data?.type === "call" ? "call" : "message",
        reason: responseKind,
        attempt: attempt + 1,
      }));
      return "other";
    }

    console.warn("FCM_RETRY", JSON.stringify({
      status: response.status,
      platform,
      kind: data?.type === "call" ? "call" : "message",
      nextAttempt: attempt + 2,
    }));

    await new Promise((resolve) =>
      setTimeout(resolve, getFcmRetryDelayMs(response, attempt)),
    );
  }

  return "other";
}

async function createFcmAccessToken(clientEmail, privateKey) {
  const now = Math.floor(Date.now() / 1000);

  const header = stringToBase64Url(
    JSON.stringify({
      alg: "RS256",
      typ: "JWT",
    }),
  );

  const payload = stringToBase64Url(
    JSON.stringify({
      iss: clientEmail,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }),
  );

  const unsignedToken = `${header}.${payload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsignedToken),
  );

  const assertion =
    `${unsignedToken}.${base64UrlEncode(new Uint8Array(signature))}`;

  const tokenResponse = await fetch(
    "https://oauth2.googleapis.com/token",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body:
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer" +
        `&assertion=${encodeURIComponent(assertion)}`,
    },
  );

  if (!tokenResponse.ok) {
    let oauthError = null;

    try {
      oauthError = await tokenResponse.json();
    } catch (_) {
      oauthError = null;
    }

    console.error("FCM_OAUTH_ERROR", JSON.stringify({
      status: tokenResponse.status,
      statusText: tokenResponse.statusText,
      body: oauthError,
    }));

    throw new Error(`FCM OAuth token request failed (${tokenResponse.status})`);
  }

  const tokenBody = await tokenResponse.json();

  if (
    typeof tokenBody.access_token !== "string" ||
    !tokenBody.access_token
  ) {
    throw new Error("FCM OAuth access token missing");
  }

  return tokenBody.access_token;
}

const RELAY_AUTH_CHALLENGE_PREFIX =
  "STELLAR_RELAY_AUTH_CHALLENGE_V1:";

const RELAY_AUTH_RESPONSE_PREFIX =
  "STELLAR_RELAY_AUTH_RESPONSE_V1:";

const RELAY_AUTH_OK =
  "STELLAR_RELAY_AUTH_OK_V1";

const RELAY_DELIVERY_PREFIX =
  "STELLAR_RELAY_DELIVERY_V1:";

const RELAY_SENDER_PREFIX =
  "STELLAR_RELAY_SENDER_V1:";

const RELAY_CHUNK_PREFIX =
  "STELLAR_RELAY_CHUNK_V1:";

const RELAY_CHUNK_SIZE = 512 * 1024;

const RELAY_ACK_PREFIX =
  "STELLAR_RELAY_ACK_V1:";

const RELAY_ACK_OK_PREFIX =
  "STELLAR_RELAY_ACK_OK_V1:";

// Sender-side durable acceptance receipt. This is separate from
// the recipient's STELLAR_RELAY_ACK_V1 delivery acknowledgement.
const RELAY_SEND_PREFIX = "STELLAR_RELAY_SEND_V1:";
const RELAY_SEND_OK_PREFIX = "STELLAR_RELAY_SEND_OK_V1:";

// Sender-side attachment upload protocol.
// Separate from recipient delivery ACK/chunk protocol.
const RELAY_UPLOAD_CHUNK_PREFIX =
  "STELLAR_UPLOAD_CHUNK_V1:";

const RELAY_UPLOAD_START_PREFIX =
  "STELLAR_UPLOAD_START_V1:";

// Binary frame: STUP1 + UUID (36 bytes) + index/count/total (uint32)
// followed by the encrypted envelope chunk.
const RELAY_UPLOAD_FRAME_MAGIC = "STUP1";

const RELAY_UPLOAD_ACK_PREFIX =
  "STELLAR_UPLOAD_ACK_V1:";

const RELAY_UPLOAD_DONE_PREFIX =
  "STELLAR_UPLOAD_DONE_V1:";

const RELAY_UPLOAD_ERROR_PREFIX =
  "STELLAR_UPLOAD_ERROR_V1:";

const RELAY_UPLOAD_CHUNK_SIZE = 128 * 1024;
// 8 MiB attachment payloads expand via base64 before Signal encryption.
const RELAY_UPLOAD_MAX_BYTES = 12 * 1024 * 1024;
// Allow slow mobile clients enough time for ACK-gated 128 KiB chunks.
const RELAY_UPLOAD_TTL_MS = 15 * 60 * 1000;

const RELAY_AUTH_TTL_MS = 60 * 1000;

const MODERATION_AUTH_TTL_MS = 60 * 1000;
// Admin login sessions last 8 hours; challenges remain short-lived.
const MODERATION_ADMIN_SESSION_TTL_MS = 8 * 60 * 60 * 1000;

function createRelayChallenge() {
  const bytes = crypto.getRandomValues(
    new Uint8Array(32),
  );

  return base64UrlEncode(bytes);
}

function validRelayPeer(peer) {
  return (
    typeof peer === "string" &&
    /^[a-z0-9_]{3,32}$/.test(peer)
  );
}

function createModerationChallenge() {
  const bytes = crypto.getRandomValues(
    new Uint8Array(32),
  );

  return base64UrlEncode(bytes);
}

function createModerationSessionToken() {
  const bytes = crypto.getRandomValues(
    new Uint8Array(32),
  );

  return base64UrlEncode(bytes);
}

function createModerationAdminChallenge() {
  const bytes = crypto.getRandomValues(
    new Uint8Array(32),
  );

  return base64UrlEncode(bytes);
}

async function constantTimeStringEqual(candidate, expected) {
  if (
    typeof candidate !== "string" ||
    typeof expected !== "string"
  ) {
    return false;
  }

  const encoder = new TextEncoder();
  const [candidateHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(candidate)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);

  const a = new Uint8Array(candidateHash);
  const b = new Uint8Array(expectedHash);
  let difference = 0;

  for (let i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }

  return difference === 0;
}

async function verifyModerationAdminProof({
  challenge,
  proof,
  secret,
}) {
  if (
    typeof challenge !== "string" ||
    challenge.length === 0 ||
    typeof proof !== "string" ||
    proof.length === 0 ||
    typeof secret !== "string" ||
    secret.length === 0
  ) {
    return false;
  }

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    {
      name: "HMAC",
      hash: "SHA-256",
    },
    false,
    ["verify"],
  );

  let signature;

  try {
    signature = Uint8Array.from(
      atob(
        proof
          .replace(/-/g, "+")
          .replace(/_/g, "/")
          .padEnd(
            proof.length + ((4 - (proof.length % 4)) % 4),
            "=",
          ),
      ),
      (char) => char.charCodeAt(0),
    );
  } catch (_) {
    return false;
  }

  return crypto.subtle.verify(
    "HMAC",
    key,
    signature,
    new TextEncoder().encode(challenge),
  );
}

export class RelayRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;

    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS relay_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipient TEXT NOT NULL,
        sender TEXT,
        envelope BLOB NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        chunked INTEGER NOT NULL DEFAULT 0,
        chunk_count INTEGER NOT NULL DEFAULT 0
      )
    `);

    const columns = this.ctx.storage.sql.exec(
      `PRAGMA table_info(relay_queue)`,
    );

    const columnNames = Array.from(columns).map(
      (column) => column.name,
    );

    if (!columnNames.includes("sender")) {
      this.ctx.storage.sql.exec(
        `ALTER TABLE relay_queue ADD COLUMN sender TEXT`,
      );
    }

    if (!columnNames.includes("chunked")) {
      this.ctx.storage.sql.exec(
        `ALTER TABLE relay_queue ADD COLUMN chunked INTEGER NOT NULL DEFAULT 0`,
      );
    }

    if (!columnNames.includes("chunk_count")) {
      this.ctx.storage.sql.exec(
        `ALTER TABLE relay_queue ADD COLUMN chunk_count INTEGER NOT NULL DEFAULT 0`,
      );
    }

    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS relay_queue_chunks (
        delivery_id INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        chunk BLOB NOT NULL,
        PRIMARY KEY (delivery_id, chunk_index)
      )
    `);

    // Idempotency ledger for sender-side durable acceptance receipts.
    // Keep entries after queue delivery ACKs so retrying the same
    // receipt ID can never create another queued envelope.
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS relay_send_receipts (
        sender TEXT NOT NULL,
        receipt_id TEXT NOT NULL,
        recipient TEXT NOT NULL,
        envelope_hash TEXT NOT NULL,
        delivery_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (sender, receipt_id)
      )
    `);

    // Temporary sender-side attachment uploads.
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS relay_upload_transfers (
        upload_id TEXT PRIMARY KEY,
        sender TEXT NOT NULL,
        recipient TEXT NOT NULL,
        total_bytes INTEGER NOT NULL,
        chunk_count INTEGER NOT NULL,
        received_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'uploading'
      )
    `);

    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS relay_upload_chunks (
        upload_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        chunk BLOB NOT NULL,
        PRIMARY KEY (upload_id, chunk_index)
      )
    `);
  }

  async queueEnvelope(recipient, sender, message) {
    if (await this.ctx.storage.get(`relay-revoked:${recipient}`)) {
      throw new Error("Recipient account revoked");
    }
    const bytes =
      typeof message === "string"
        ? new TextEncoder().encode(message)
        : message instanceof ArrayBuffer
          ? new Uint8Array(message)
          : new Uint8Array(
              message.buffer,
              message.byteOffset,
              message.byteLength,
            );

    if (bytes.length < 6) {
      throw new Error("Invalid envelope");
    }

    const ttlSeconds = readU32(bytes, 2);
    const createdAt = Date.now();
    const expiresAt = createdAt + ttlSeconds * 1000;

    const chunked = bytes.length > RELAY_CHUNK_SIZE;
    const chunkCount = chunked
      ? Math.ceil(bytes.length / RELAY_CHUNK_SIZE)
      : 0;

    /*
     * Keep the legacy single-BLOB row for small envelopes.
     *
     * Large envelopes are represented by one logical parent row
     * plus <=512 KiB child BLOB rows. This stays below the
     * Durable Objects SQLite 2 MiB row/BLOB limit.
     */
    this.ctx.storage.sql.exec(
      `INSERT INTO relay_queue
        (
          recipient,
          sender,
          envelope,
          created_at,
          expires_at,
          chunked,
          chunk_count
        )
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      recipient,
      sender,
      chunked ? new Uint8Array(0) : bytes,
      createdAt,
      expiresAt,
      chunked ? 1 : 0,
      chunkCount,
    );

    const row = this.ctx.storage.sql
      .exec(`SELECT last_insert_rowid() AS id`)
      .one();

    const deliveryId = Number(row.id);

    if (!chunked) {
      return deliveryId;
    }

    for (
      let chunkIndex = 0;
      chunkIndex < chunkCount;
      chunkIndex++
    ) {
      const start = chunkIndex * RELAY_CHUNK_SIZE;
      const end = Math.min(
        start + RELAY_CHUNK_SIZE,
        bytes.length,
      );

      this.ctx.storage.sql.exec(
        `INSERT INTO relay_queue_chunks
          (delivery_id, chunk_index, chunk)
         VALUES (?, ?, ?)`,
        deliveryId,
        chunkIndex,
        bytes.slice(start, end),
      );
    }

    return deliveryId;
  }

  async queueEnvelopeWithReceipt(recipient, sender, message, receiptId) {
    if (await this.ctx.storage.get(`relay-revoked:${recipient}`)) {
      throw new Error("Recipient account revoked");
    }
    const bytes =
      typeof message === "string"
        ? new TextEncoder().encode(message)
        : message instanceof ArrayBuffer
          ? new Uint8Array(message)
          : new Uint8Array(
              message.buffer,
              message.byteOffset,
              message.byteLength,
            );

    if (bytes.length < 8) {
      throw new Error("Invalid envelope");
    }

    const decodedRecipient = decodeRecipientRoute(bytes)
      .trim()
      .toLowerCase();

    if (!decodedRecipient || decodedRecipient !== recipient) {
      throw new Error("Receipt envelope recipient mismatch");
    }

    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const envelopeHash = Array.from(new Uint8Array(digest))
      .map((value) => value.toString(16).padStart(2, "0"))
      .join("");

    const createdAt = Date.now();
    const expiresAt = createdAt + readU32(bytes, 2) * 1000;
    const chunked = bytes.length > RELAY_CHUNK_SIZE;
    const chunkCount = chunked
      ? Math.ceil(bytes.length / RELAY_CHUNK_SIZE)
      : 0;

    /*
     * The receipt ledger and queued envelope must commit together.
     * A retry with the same sender, receipt ID, recipient and bytes
     * returns the original delivery ID instead of creating a duplicate.
     */
    return this.ctx.storage.transactionSync(() => {
      const existingRows = Array.from(
        this.ctx.storage.sql.exec(
          `SELECT recipient, envelope_hash, delivery_id
           FROM relay_send_receipts
           WHERE sender = ? AND receipt_id = ?`,
          sender,
          receiptId,
        ),
      );

      if (existingRows.length > 0) {
        const existing = existingRows[0];

        if (
          existing.recipient !== recipient ||
          existing.envelope_hash !== envelopeHash
        ) {
          throw new Error("RELAY_RECEIPT_ID_CONFLICT");
        }

        return {
          deliveryId: Number(existing.delivery_id),
          duplicate: true,
        };
      }

      this.ctx.storage.sql.exec(
        `INSERT INTO relay_queue
          (recipient, sender, envelope, created_at, expires_at,
           chunked, chunk_count)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        recipient,
        sender,
        chunked ? new Uint8Array(0) : bytes,
        createdAt,
        expiresAt,
        chunked ? 1 : 0,
        chunkCount,
      );

      const row = this.ctx.storage.sql
        .exec(`SELECT last_insert_rowid() AS id`)
        .one();

      const deliveryId = Number(row.id);

      if (chunked) {
        for (
          let chunkIndex = 0;
          chunkIndex < chunkCount;
          chunkIndex++
        ) {
          const start = chunkIndex * RELAY_CHUNK_SIZE;
          const end = Math.min(start + RELAY_CHUNK_SIZE, bytes.length);

          this.ctx.storage.sql.exec(
            `INSERT INTO relay_queue_chunks
              (delivery_id, chunk_index, chunk)
             VALUES (?, ?, ?)`,
            deliveryId,
            chunkIndex,
            bytes.slice(start, end),
          );
        }
      }

      this.ctx.storage.sql.exec(
        `INSERT INTO relay_send_receipts
          (sender, receipt_id, recipient, envelope_hash,
           delivery_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        sender,
        receiptId,
        recipient,
        envelopeHash,
        deliveryId,
        createdAt,
      );

      return { deliveryId, duplicate: false };
    });
  }

  async handleSendWithReceipt(ws, receiptId, message) {
    const attachment = ws.deserializeAttachment() || {};

    if (
      attachment.authenticated !== true ||
      attachment.authState !== "authenticated"
    ) {
      throw new Error("Relay authentication required");
    }

    const sender = String(attachment.peer || "").trim().toLowerCase();

    if (!sender) {
      throw new Error("Missing authenticated sender");
    }

    const bytes =
      message instanceof ArrayBuffer
        ? new Uint8Array(message)
        : new Uint8Array(
            message.buffer,
            message.byteOffset,
            message.byteLength,
          );

    const recipient = decodeRecipientRoute(bytes).trim().toLowerCase();

    if (!recipient) {
      throw new Error("Missing envelope recipient");
    }

    const result = await this.queueEnvelopeWithReceipt(
      recipient,
      sender,
      bytes,
      receiptId,
    );

    // The envelope and idempotency record are durable before this ACK.
    ws.send(`${RELAY_SEND_OK_PREFIX}${receiptId}`);

    // Online delivery still uses the existing queue/chunk/recipient-ACK
    // protocol. The queued row is NOT deleted by this sender receipt.
    let deliveredOnline = false;

    for (const peer of this.ctx.getWebSockets()) {
      if (peer === ws) continue;

      try {
        const peerAttachment = peer.deserializeAttachment();

        if (
          peerAttachment?.authenticated === true &&
          peerAttachment?.authState === "authenticated" &&
          String(peerAttachment.peer || "").trim().toLowerCase() === recipient
        ) {
          deliveredOnline = await this.flushQueue(peer, recipient);
          break;
        }
      } catch (_) {
        // Ignore a disconnected peer; the durable queue remains.
      }
    }

    // Wake offline recipients and recipients whose online socket failed.
    // The durable queue remains authoritative; FCM is only a wake-up hint.
    if (!deliveredOnline) {
      this.ctx.waitUntil(
        this.sendPushWake(recipient).catch(() => {
          console.error("FCM_RECEIPT_WAKE_FAILED");
        }),
      );
    }

    console.log(
      "RELAY_SEND_RECEIPT_ACCEPTED",
      JSON.stringify({
        sender,
        recipient,
        receiptId,
        deliveryId: result.deliveryId,
        duplicate: result.duplicate,
      }),
    );
  }

  sendUploadError(ws, uploadId, code) {
    try {
      ws.send(
        `${RELAY_UPLOAD_ERROR_PREFIX}${JSON.stringify({
          uploadId: uploadId || "",
          code,
        })}`,
      );
    } catch (_) {}
  }

  async handleUploadStart(ws, payload, sender) {
    let uploadId = "";

    try {
      const meta = JSON.parse(payload);
      uploadId = String(meta.uploadId || "");

      const recipient = String(meta.recipient || "")
        .trim()
        .toLowerCase();
      const totalBytes = Number(meta.totalBytes);
      const chunkCount = Number(meta.chunkCount);

      if (
        !sender ||
        !/^[0-9a-f-]{36}$/i.test(uploadId) ||
        !recipient ||
        recipient.length > 128 ||
        !Number.isInteger(totalBytes) ||
        totalBytes < 1 ||
        totalBytes > RELAY_UPLOAD_MAX_BYTES ||
        !Number.isInteger(chunkCount) ||
        chunkCount !== Math.ceil(
          totalBytes / RELAY_UPLOAD_CHUNK_SIZE,
        )
      ) {
        this.sendUploadError(ws, uploadId, "invalid_start");
        return;
      }

      const now = Date.now();

      this.ctx.storage.sql.exec(
        `DELETE FROM relay_upload_chunks
         WHERE upload_id IN (
           SELECT upload_id FROM relay_upload_transfers
           WHERE expires_at <= ?
         )`,
        now,
      );

      this.ctx.storage.sql.exec(
        `DELETE FROM relay_upload_transfers WHERE expires_at <= ?`,
        now,
      );

      const existing = this.ctx.storage.sql.exec(
        `SELECT upload_id FROM relay_upload_transfers
         WHERE upload_id = ?`,
        uploadId,
      ).one();

      if (existing) {
        this.sendUploadError(ws, uploadId, "upload_id_exists");
        return;
      }

      this.ctx.storage.sql.exec(
        `INSERT INTO relay_upload_transfers
          (upload_id, sender, recipient, total_bytes, chunk_count,
           received_count, created_at, expires_at, status)
         VALUES (?, ?, ?, ?, ?, 0, ?, ?, 'uploading')`,
        uploadId,
        sender,
        recipient,
        totalBytes,
        chunkCount,
        now,
        now + RELAY_UPLOAD_TTL_MS,
      );

      ws.send(`${RELAY_UPLOAD_ACK_PREFIX}${JSON.stringify({
        type: "started",
        uploadId,
        receivedBytes: 0,
        totalBytes,
      })}`);
    } catch (_) {
      this.sendUploadError(ws, uploadId, "invalid_start");
    }
  }

  async handleUploadChunk(ws, frame, sender) {
    let uploadId = "";

    try {
      // 5-byte magic + 36-byte UUID + three uint32 fields = 53 bytes.
      if (frame.length < 53) {
        this.sendUploadError(ws, uploadId, "invalid_chunk_frame");
        return;
      }

      uploadId = String.fromCharCode(...frame.subarray(5, 41));

      const chunkIndex = readU32(frame, 41);
      const chunkCount = readU32(frame, 45);
      const totalBytes = readU32(frame, 49);
      const chunk = frame.slice(53);

      if (
        !/^[0-9a-f-]{36}$/i.test(uploadId) ||
        !sender ||
        chunk.length < 1 ||
        chunk.length > RELAY_UPLOAD_CHUNK_SIZE
      ) {
        this.sendUploadError(ws, uploadId, "invalid_chunk");
        return;
      }

      const transfer = this.ctx.storage.sql.exec(
        `SELECT upload_id, sender, recipient, total_bytes, chunk_count,
                received_count, expires_at, status
         FROM relay_upload_transfers WHERE upload_id = ?`,
        uploadId,
      ).one();

      if (
        !transfer ||
        transfer.sender !== sender ||
        transfer.status !== "uploading" ||
        Number(transfer.expires_at) <= Date.now() ||
        Number(transfer.total_bytes) !== totalBytes ||
        Number(transfer.chunk_count) !== chunkCount ||
        chunkIndex >= chunkCount ||
        chunkCount !== Math.ceil(
          totalBytes / RELAY_UPLOAD_CHUNK_SIZE,
        )
      ) {
        this.sendUploadError(ws, uploadId, "unknown_or_invalid_transfer");
        return;
      }

      const expectedLength = chunkIndex === chunkCount - 1
        ? totalBytes - RELAY_UPLOAD_CHUNK_SIZE * (chunkCount - 1)
        : RELAY_UPLOAD_CHUNK_SIZE;

      if (chunk.length !== expectedLength) {
        this.sendUploadError(ws, uploadId, "invalid_chunk_size");
        return;
      }

      const previous = this.ctx.storage.sql.exec(
        `SELECT chunk FROM relay_upload_chunks
         WHERE upload_id = ? AND chunk_index = ?`,
        uploadId,
        chunkIndex,
      ).one();

      if (previous) {
        const previousBytes = new Uint8Array(previous.chunk);
        const identical =
          previousBytes.length === chunk.length &&
          previousBytes.every(
            (value, index) => value === chunk[index],
          );

        if (!identical) {
          this.sendUploadError(ws, uploadId, "chunk_conflict");
          return;
        }
      } else {
        this.ctx.storage.sql.exec(
          `INSERT INTO relay_upload_chunks
            (upload_id, chunk_index, chunk)
           VALUES (?, ?, ?)`,
          uploadId,
          chunkIndex,
          chunk,
        );

        this.ctx.storage.sql.exec(
          `UPDATE relay_upload_transfers
           SET received_count = received_count + 1
           WHERE upload_id = ? AND status = 'uploading'`,
          uploadId,
        );
      }

      const sum = this.ctx.storage.sql.exec(
        `SELECT COALESCE(SUM(length(chunk)), 0) AS received_bytes
         FROM relay_upload_chunks WHERE upload_id = ?`,
        uploadId,
      ).one();

      ws.send(`${RELAY_UPLOAD_ACK_PREFIX}${JSON.stringify({
        type: "chunk",
        uploadId,
        index: chunkIndex,
        receivedBytes: Number(sum?.received_bytes || 0),
        totalBytes,
      })}`);
    } catch (_) {
      this.sendUploadError(ws, uploadId, "chunk_storage_failed");
    }
  }

  async handleUploadDone(ws, payload, sender) {
    let uploadId = "";

    try {
      const meta = JSON.parse(payload);
      uploadId = String(meta.uploadId || "");

      if (!/^[0-9a-f-]{36}$/i.test(uploadId) || !sender) {
        this.sendUploadError(ws, uploadId, "invalid_done");
        return;
      }

      const transfer = this.ctx.storage.sql.exec(
        `SELECT upload_id, sender, recipient, total_bytes, chunk_count,
                received_count, expires_at, status
         FROM relay_upload_transfers WHERE upload_id = ?`,
        uploadId,
      ).one();

      if (!transfer || transfer.sender !== sender) {
        this.sendUploadError(ws, uploadId, "unknown_transfer");
        return;
      }

      // A concurrent DONE must not start a second delivery.
      if (transfer.status === "finalizing") {
        this.sendUploadError(ws, uploadId, "upload_in_progress");
        return;
      }

      // Make a repeated DONE request safe if the final ACK was lost.
      if (transfer.status === "completed") {
        ws.send(`${RELAY_UPLOAD_ACK_PREFIX}${JSON.stringify({
          type: "done",
          uploadId,
          totalBytes: Number(transfer.total_bytes),
          delivery: "accepted",
        })}`);
        return;
      }

      if (
        transfer.status !== "uploading" ||
        Number(transfer.expires_at) <= Date.now() ||
        Number(transfer.received_count) !== Number(transfer.chunk_count)
      ) {
        this.sendUploadError(
          ws,
          uploadId,
          "upload_incomplete_or_expired",
        );
        return;
      }

      const rows = Array.from(this.ctx.storage.sql.exec(
        `SELECT chunk_index, chunk FROM relay_upload_chunks
         WHERE upload_id = ? ORDER BY chunk_index ASC`,
        uploadId,
      ));

      if (rows.length !== Number(transfer.chunk_count)) {
        this.sendUploadError(ws, uploadId, "missing_chunks");
        return;
      }

      const envelope = new Uint8Array(Number(transfer.total_bytes));
      let offset = 0;

      for (let index = 0; index < rows.length; index++) {
        if (Number(rows[index].chunk_index) !== index) {
          this.sendUploadError(ws, uploadId, "chunk_order_invalid");
          return;
        }

        const part = new Uint8Array(rows[index].chunk);

        if (offset + part.length > envelope.length) {
          this.sendUploadError(ws, uploadId, "envelope_size_invalid");
          return;
        }

        envelope.set(part, offset);
        offset += part.length;
      }

      if (offset !== envelope.length) {
        this.sendUploadError(ws, uploadId, "envelope_size_invalid");
        return;
      }

      const envelopeRecipient = decodeRecipientRoute(envelope)
        .trim()
        .toLowerCase();

      if (
        !envelopeRecipient ||
        envelopeRecipient !== transfer.recipient
      ) {
        this.sendUploadError(ws, uploadId, "recipient_mismatch");
        return;
      }

      // Atomically claim finalization to prevent duplicate delivery.
      const claim = this.ctx.storage.sql.exec(
        `UPDATE relay_upload_transfers
         SET status = 'finalizing'
         WHERE upload_id = ? AND sender = ? AND status = 'uploading'
         RETURNING upload_id`,
        uploadId,
        sender,
      );

      if (claim.toArray().length === 0) {
        const latest = this.ctx.storage.sql.exec(
          `SELECT upload_id, sender, recipient, total_bytes, chunk_count,
                  received_count, expires_at, status
           FROM relay_upload_transfers WHERE upload_id = ?`,
          uploadId,
        ).one();

        if (latest?.status === "completed" && latest.sender === sender) {
          ws.send(`${RELAY_UPLOAD_ACK_PREFIX}${JSON.stringify({
            type: "done",
            uploadId,
            totalBytes: Number(latest.total_bytes),
            delivery: "accepted",
          })}`);
        } else if (
          latest?.status === "finalizing" &&
          latest.sender === sender
        ) {
          this.sendUploadError(ws, uploadId, "upload_in_progress");
        } else {
          this.sendUploadError(
            ws,
            uploadId,
            "upload_incomplete_or_expired",
          );
        }
        return;
      }

      const delivery = await this.deliverUploadedEnvelope(
        ws,
        transfer.recipient,
        sender,
        envelope,
      );

      this.ctx.storage.sql.exec(
        `UPDATE relay_upload_transfers
         SET status = 'completed'
         WHERE upload_id = ? AND sender = ? AND status = 'finalizing'`,
        uploadId,
        sender,
      );

      this.ctx.storage.sql.exec(
        `DELETE FROM relay_upload_chunks WHERE upload_id = ?`,
        uploadId,
      );

      ws.send(`${RELAY_UPLOAD_ACK_PREFIX}${JSON.stringify({
        type: "done",
        uploadId,
        totalBytes: envelope.length,
        delivery,
      })}`);
    } catch (_) {
      this.sendUploadError(ws, uploadId, "finalize_failed");
    }
  }

  async deliverUploadedEnvelope(senderSocket, recipient, sender, envelope) {
    for (const peer of this.ctx.getWebSockets()) {
      if (peer === senderSocket) continue;

      try {
        const peerAttachment = peer.deserializeAttachment();

        if (
          peerAttachment?.authenticated === true &&
          peerAttachment?.authState === "authenticated" &&
          String(peerAttachment.peer || "").trim().toLowerCase() === recipient
        ) {
 #]v◊M≠¢Gß≤⁄Óù∆≠y⁄àõ€ùŸZY⁄ùÕÃ
JKà€€ú›⁄^ôYõﬁ
ZY⁄à
Kà^
›[\ï^
€€ù^à	’\»ô\›‹ô\»[›\àXÿ€›[ùY[ù]H[ô›‹ûHŸ^\Àà⁄]\›‹ûH\»õ›[ò€YYâ Kà›[Nà€€ú›^›[J€€‹éà›[\ê€€‹úÀù^ŸX€€ô\ûKZY⁄àKçJJKà€€ú›⁄^ôYõﬁ
ZY⁄àå
Kà›][ôYù]€ãöX€€äà€îô\‹ŸYà›€‹ö⁄[ô»»ù[àÿ⁄€‹ŸQö[KàX€€éà€€ú›X€€äX€€úÀôõ€\ó€‹[äKàXô[à^
Ÿö[Sò[YHœ»›[\ï^
€€ù^	‘Ÿ[X›ôX€›ô\ûHö[I JKà
Kà€€ú›⁄^ôYõﬁ
ZY⁄àMäKà^öY[
à€€ùõ€\éà‹\‹‹ò\ŸKàÿúÿ›\ôU^àùYKà]]Ÿö[[ùŒà€€ú›–]]Ÿö[[ùÀú\‹›€‹ôKàX€‹ò][€éà[ú]X€‹ò][€äàXô[^à›[\ï^
€€ù^	‘ôX€›ô\ûH\‹‹ò\ŸI Kàõ‹ô\éà€€ú››][ôR[ú]õ‹ô\ä
Kà
Kà
Kà€€ú›‹XŸ\ä
Kà⁄^ôYõﬁ
à⁄Yà›XõKö[ôö[ö]Kà⁄[àö[Yù]€ãöX€€äà€îô\‹ŸYà›€‹ö⁄[ô»»ù[à‹ô\›‹ôKàX€€éà›€‹ö⁄[ô¬à»€€ú›⁄^ôYõﬁ
⁄YàNZY⁄àNà⁄[à⁄\ò›[\îõŸ‹ô\‹“[ôXÿ]‹ä›õ⁄ŸU⁄YàäJBàà€€ú›X€€äX€€úÀúô\›‹ôJKàXô[à^
›[\ï^
€€ù^	‘ô\›‹ôI JKà
Kà
KàKà
Kà
Kà
Kà
N¬àBüB