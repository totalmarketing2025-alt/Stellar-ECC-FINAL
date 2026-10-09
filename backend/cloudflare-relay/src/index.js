function readU16(bytes, offset) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    .getUint16(offset, false);
}

function readU32(bytes, offset) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    .getUint32(offset, false);
}

function decodeRecipientRoute(buffer) {
  const bytes = new Uint8Array(buffer);
  let offset = 0;

  if (bytes.length < 8) {
    throw new Error("Invalid envelope");
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

function pemToArrayBuffer(pem) {
  const base64 = pem
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

  console.error("FCM_RESPONSE", JSON.stringify({
    status: response.status,
    statusText: response.statusText,
    body,
  }));

  const error = body?.error;

  const details = Array.isArray(error?.details)
    ? error.details
    : [];

  const hasUnregisteredError = details.some(
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
      console.error("FCM_FETCH_ERROR", String(error));

      if (attempt === 2) {
        return "other";
      }

      await new Promise((resolve) =>
        setTimeout(resolve, getFcmRetryDelayMs(null, attempt)),
      );
      continue;
    }

    if (response.ok) {
      return "sent";
    }

    const kind = await classifyFcmResponse(response);

    if (kind === "invalid-token") {
      return "invalid-token";
    }

    if (kind !== "transient" || attempt === 2) {
      return "other";
    }

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

const RELAY_AUTH_TTL_MS = 60 * 1000;

const MODERATION_AUTH_TTL_MS = 60 * 1000;

function createRelayChallenge() {
  const bytes = crypto.getRandomValues(
    new Uint8Array(32),
  );

  return base64UrlEncode(bytes);
}

function validRelayPeer(peer) {
  return (
    typeof peer === "string" &&
    /^[a-z0-9_.-]{1,64}$/.test(peer)
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
  }

  async queueEnvelope(recipient, sender, message) {
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

  async flushQueue(ws, recipient) {
    const now = Date.now();

    const result = this.ctx.storage.sql.exec(
      `SELECT
         id,
         sender,
         envelope,
         expires_at,
         chunked,
         chunk_count
       FROM relay_queue
       WHERE recipient = ?
       ORDER BY id ASC`,
      recipient,
    );

    for (const row of result) {
      try {
        if (Number(row.expires_at) <= now) {
          this.ctx.storage.sql.exec(
            `DELETE FROM relay_queue_chunks
             WHERE delivery_id = ?`,
            row.id,
          );

          this.ctx.storage.sql.exec(
            `DELETE FROM relay_queue
             WHERE id = ? AND recipient = ?`,
            row.id,
            recipient,
          );

          continue;
        }

        /*
         * IMPORTANT:
         * Queue rows are NOT deleted here.
         * The client ACKs only after the complete logical
         * envelope has been reconstructed, decrypted and
         * processed locally.
         */
        ws.send(
          `${RELAY_DELIVERY_PREFIX}${row.id}`,
        );

        if (
          typeof row.sender === "string" &&
          row.sender
        ) {
          ws.send(
            `${RELAY_SENDER_PREFIX}${row.sender}`,
          );
        }

        if (Number(row.chunked) === 1) {
          const chunks = this.ctx.storage.sql.exec(
            `SELECT chunk_index, chunk
             FROM relay_queue_chunks
             WHERE delivery_id = ?
             ORDER BY chunk_index ASC`,
            row.id,
          );

          const expectedCount = Number(row.chunk_count);

          let index = 0;

          for (const chunkRow of chunks) {
            if (index >= expectedCount) {
              throw new Error(
                `Too many chunks for delivery ${row.id}`,
              );
            }

            if (Number(chunkRow.chunk_index) !== index) {
              throw new Error(
                `Missing chunk ${index} for delivery ${row.id}`,
              );
            }

            ws.send(
              `${RELAY_CHUNK_PREFIX}${row.id}:${index}:${expectedCount}`,
            );

            ws.send(
              new Uint8Array(chunkRow.chunk),
            );

            index++;
          }

          if (index !== expectedCount) {
            throw new Error(
              `Incomplete chunk set for delivery ${row.id}`,
            );
          }
        } else {
          ws.send(
            new Uint8Array(row.envelope),
          );
        }
      } catch (_) {
        break;
      }
    }
  }

  async sendPushWake(recipient, callMeta = null) {
    const directoryUrl = this.env.DIRECTORY_URL;
    const sharedSecret = this.env.RELAY_SHARED_SECRET;
    const projectId = this.env.FCM_PROJECT_ID;
    const clientEmail = this.env.FCM_CLIENT_EMAIL;
    const privateKey = this.env.FCM_PRIVATE_KEY;

    if (
      !directoryUrl ||
      !sharedSecret ||
      !projectId ||
      !clientEmail ||
      !privateKey ||
      privateKey === "DEV_PLACEHOLDER" ||
      clientEmail.startsWith("dev-placeholder@")
    ) {
      console.error("FCM_CONFIG_MISSING", JSON.stringify({
        directoryUrl: Boolean(directoryUrl),
        sharedSecret: Boolean(sharedSecret),
        projectId: Boolean(projectId),
        clientEmail: Boolean(clientEmail),
        privateKey: Boolean(privateKey),
      }));
      return;
    }

    const response = await fetch(
      `${directoryUrl}/v1/users/${encodeURIComponent(recipient)}/push-token`,
      {
        headers: {
          Authorization: `Bearer ${sharedSecret}`,
        },
      },
    );

    if (!response.ok) {
      console.error("FCM_DIRECTORY_ERROR", JSON.stringify({
        status: response.status,
        statusText: response.statusText,
      }));
      return;
    }

    const body = await response.json();

    console.log("FCM_DIRECTORY_REGISTRATIONS", JSON.stringify({
      count: Array.isArray(body.pushRegistrations)
        ? body.pushRegistrations.length
        : body.push
          ? 1
          : 0,
    }));

    const registrations = Array.isArray(body.pushRegistrations)
      ? body.pushRegistrations
      : body.push
        ? [body.push]
        : [];

    const validRegistrations = registrations.filter(
      (registration) =>
        registration &&
        typeof registration.token === "string" &&
        registration.token &&
        (registration.platform === "android" ||
          registration.platform === "ios"),
    );

    if (validRegistrations.length === 0) {
      console.error("FCM_NO_VALID_REGISTRATIONS");
      return;
    }

    console.log("FCM_VALID_REGISTRATIONS", validRegistrations.length);

    let accessToken;

    try {
      accessToken = await createFcmAccessToken(
        clientEmail,
        privateKey,
      );
    } catch (error) {
      console.error("FCM_ACCESS_TOKEN_ERROR", String(error));
      return;
    }

    const sends = validRegistrations.map(async (registration) => {
      const result = await sendFcmMessage({
        projectId,
        accessToken,
        token: registration.token,
        data: {
          wake: "1",
          ...(callMeta
            ? {
                type: "call",
                callId: callMeta.callId,
                from: callMeta.from,
                kind: callMeta.kind,
                ...(callMeta.chatId
                  ? { chatId: callMeta.chatId }
                  : {}),
              }
            : {}),
        },
        priority: callMeta ? "high" : "normal",
      });

      if (result === "invalid-token") {
        await removePushToken(
          directoryUrl,
          sharedSecret,
          recipient,
          registration.token,
        );
      }
    });

    await Promise.all(sends);
  }

  async fetch(request) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return Response.json({
        ok: true,
        service: "stellar-relay",
      });
    }

    const rawPeer =
      new URL(request.url).searchParams.get("peer");

    const normalizedPeer = String(rawPeer || "")
      .trim()
      .toLowerCase();

    if (!validRelayPeer(normalizedPeer)) {
      return new Response("Invalid peer", { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    this.ctx.acceptWebSocket(server);

    const challenge = createRelayChallenge();

    server.serializeAttachment({
      peer: normalizedPeer,
      authenticated: false,
      authState: "challenge-sent",
      challenge,
      challengeExpiresAt: Date.now() + RELAY_AUTH_TTL_MS,
    });

    server.send(
      `${RELAY_AUTH_CHALLENGE_PREFIX}${challenge}`,
    );

    /*
     * IMPORTANT:
     * No queue flush here.
     *
     * The socket is only routing-identified by ?peer=.
     * It is not authenticated until the XEd25519 challenge
     * completes through the Directory.
     */

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  async webSocketMessage(ws, message) {

    const attachment = ws.deserializeAttachment() || {};
    const now = Date.now();

    /*
     * Authentication protocol is the only accepted protocol
     * before authenticated=true.
     */
    if (!attachment.authenticated) {
      if (
        typeof message !== "string" ||
        !message.startsWith(RELAY_AUTH_RESPONSE_PREFIX)
      ) {
        try {
          ws.close(1008, "Relay authentication required");
        } catch (_) {}
        return;
      }

      if (attachment.authState !== "challenge-sent") {
        try {
          ws.close(1008, "Invalid relay authentication state");
        } catch (_) {}
        return;
      }

      if (
        !attachment.challenge ||
        Number(attachment.challengeExpiresAt) < now
      ) {
        try {
          ws.close(1008, "Relay authentication expired");
        } catch (_) {}
        return;
      }

      let response;

      try {
        response = JSON.parse(
          message.slice(RELAY_AUTH_RESPONSE_PREFIX.length),
        );
      } catch (_) {
        try {
          ws.close(1008, "Invalid relay authentication");
        } catch (_) {}
        return;
      }

      if (attachment.authState !== "challenge-sent") {
        try {
          ws.close(1008, "Relay authentication replay");
        } catch (_) {}
        return;
      }

      if (
        response.challenge !== attachment.challenge ||
        !Number.isInteger(Number(response.deviceId)) ||
        !Number.isInteger(Number(response.registrationId)) ||
        typeof response.signature !== "string" ||
        !response.signature
      ) {
        try {
          ws.close(1008, "Invalid relay authentication");
        } catch (_) {}
        return;
      }

      /*
       * Move to verifying state before external async I/O.
       * This prevents duplicate responses on the same socket
       * from starting parallel verification attempts.
       */
      const serverAttachment = {
        ...attachment,
        authState: "verifying",
      };

      ws.serializeAttachment(serverAttachment);

      const directoryUrl = this.env.DIRECTORY_URL;
      const sharedSecret = this.env.RELAY_SHARED_SECRET;

      if (!directoryUrl || !sharedSecret) {
        try {
          ws.close(1011, "Relay authentication unavailable");
        } catch (_) {}
        return;
      }

      try {
        const verificationResponse = await fetch(
          `${directoryUrl}/v1/internal/relay-auth`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${sharedSecret}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              nickname: attachment.peer,
              deviceId: Number(response.deviceId),
              registrationId: Number(response.registrationId),
              challenge: response.challenge,
              signature: response.signature,
            }),
          },
        );

        if (!verificationResponse.ok) {
          const errorBody = await verificationResponse.text();

          console.error("RELAY_AUTH_DIRECTORY_REJECTED", JSON.stringify({
            status: verificationResponse.status,
            statusText: verificationResponse.statusText,
            body: errorBody.slice(0, 500),
          }));

          try {
            ws.close(1008, "Relay authentication failed");
          } catch (_) {}
          return;
        }

        const result = await verificationResponse.json();

        if (result?.ok !== true) {
          try {
            ws.close(1008, "Relay authentication failed");
          } catch (_) {}
          return;
        }

        /*
         * Re-check the socket-bound challenge after the external
         * Directory verification. Authentication must not be
         * finalized after the challenge has expired.
         */
        if (
          !attachment.challenge ||
          attachment.challenge !== response.challenge ||
          Number(attachment.challengeExpiresAt) < Date.now()
        ) {
          try {
            ws.close(1008, "Relay authentication expired");
          } catch (_) {}
          return;
        }

        /*
         * Final state is persisted in the WebSocket attachment
         * so it survives Durable Object hibernation.
         */
        ws.serializeAttachment({
          peer: attachment.peer,
          authenticated: true,
          authState: "authenticated",
          challenge: null,
          challengeExpiresAt: null,
          authenticatedAt: Date.now(),
        });

        ws.send(RELAY_AUTH_OK);

        /*
         * Queue is flushed only after authentication succeeds.
         */
        await this.flushQueue(
          ws,
          attachment.peer,
        );
      } catch (_) {
        try {
          ws.close(1011, "Relay authentication error");
        } catch (_) {}
      }

      return;
    }

    if (
      attachment.authState !== "authenticated"
    ) {
      try {
        ws.close(1008, "Invalid relay authentication state");
      } catch (_) {}
      return;
    }

    if (
      typeof message === "string" &&
      message.startsWith(RELAY_ACK_PREFIX)
    ) {
      const deliveryId = Number(
        message.slice(RELAY_ACK_PREFIX.length),
      );

      if (!Number.isInteger(deliveryId) || deliveryId <= 0) {
        return;
      }

      const authenticatedAttachment =
        ws.deserializeAttachment() || {};

      if (
        authenticatedAttachment.authenticated !== true ||
        authenticatedAttachment.authState !== "authenticated"
      ) {
        return;
      }

      const recipient = String(
        authenticatedAttachment.peer || "",
      )
        .trim()
        .toLowerCase();

      if (!recipient) {
        return;
      }

      /*
       * ACK is scoped to the authenticated recipient.
       * A peer cannot delete another peer's queued envelope.
       */
      this.ctx.storage.sql.exec(
        `DELETE FROM relay_queue_chunks
         WHERE delivery_id = ?`,
        deliveryId,
      );

      this.ctx.storage.sql.exec(
        `DELETE FROM relay_queue
         WHERE id = ? AND recipient = ?`,
        deliveryId,
        recipient,
      );

      ws.send(
        `${RELAY_ACK_OK_PREFIX}${deliveryId}`,
      );

      return;
    }

    const callWakePrefix = "STELLAR_CALL_WAKE_V1:";

    if (typeof message === "string" && message.startsWith(callWakePrefix)) {
      try {
        const payload = JSON.parse(
          message.slice(callWakePrefix.length),
        );

        const recipient = String(payload.recipient || "")
          .trim()
          .toLowerCase();

        const callId = String(payload.callId || "").trim();
        const kind = String(payload.kind || "").trim().toLowerCase();
        const chatId = payload.chatId
          ? String(payload.chatId).trim()
          : "";

        const senderAttachment = ws.deserializeAttachment();

        if (
          senderAttachment?.authenticated !== true ||
          senderAttachment?.authState !== "authenticated"
        ) {
          return;
        }

        const sender = String(senderAttachment?.peer || "")
          .trim()
          .toLowerCase();

        if (
          !recipient ||
          !sender ||
          !callId ||
          (kind !== "voice" && kind !== "video")
        ) {
          return;
        }

        this.ctx.waitUntil(
          this.sendPushWake(recipient, {
            callId,
            from: sender,
            kind,
            ...(chatId ? { chatId } : {}),
          }).catch(() => {
            console.error("FCM_CALL_WAKE_FAILED");
          }),
        );
      } catch (_) {
        // Invalid call wake metadata is ignored.
      }

      return;
    }

    let recipient;

    try {
      const data =
        typeof message === "string"
          ? new TextEncoder().encode(message)
          : message instanceof ArrayBuffer
            ? message
            : message.buffer;

      recipient = decodeRecipientRoute(data)
        .trim()
        .toLowerCase();
    } catch (_) {
      return;
    }

    const senderAttachment = ws.deserializeAttachment();

    if (
      senderAttachment?.authenticated !== true ||
      senderAttachment?.authState !== "authenticated"
    ) {
      return;
    }

    const sender = String(senderAttachment?.peer || "")
      .trim()
      .toLowerCase();

    if (!sender) {
      return;
    }

    for (const peer of this.ctx.getWebSockets()) {
      if (peer === ws) {
        continue;
      }

      try {
        const attachment = peer.deserializeAttachment();

        if (
          attachment &&
          attachment.authenticated === true &&
          attachment.authState === "authenticated" &&
          attachment.peer === recipient
        ) {
          peer.send(
            `${RELAY_SENDER_PREFIX}${sender}`,
          );

          peer.send(message);
          return;
        }
      } catch (_) {
        // Ignore disconnected peers.
      }
    }

    await this.queueEnvelope(
      recipient,
      sender,
      message,
    );

    // Push notification must never block or break relay delivery.
    // The envelope is already safely queued before FCM is attempted.
    this.ctx.waitUntil(
      this.sendPushWake(recipient).catch(() => {
        console.error("FCM_PUSH_WAKE_FAILED");
      }),
    );
  }

  async webSocketClose(ws) {
    try {
      ws.close();
    } catch (_) {}
  }

  async webSocketError(ws) {
    try {
      ws.close();
    } catch (_) {}
  }
}


export class ModerationRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;

    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS moderation_messages (
        message_id TEXT PRIMARY KEY,
        sender TEXT NOT NULL,
        recipient TEXT NOT NULL,
        chat_id TEXT,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        content_type TEXT NOT NULL,
        plaintext TEXT NOT NULL,
        attachment_mime_type TEXT
      )
    `);

    try {
      this.ctx.storage.sql.exec(
        `ALTER TABLE moderation_messages
         ADD COLUMN attachment_mime_type TEXT`,
      );
    } catch (error) {
      if (!String(error).toLowerCase().includes("duplicate column")) {
        throw error;
      }
    }
  }

  async authenticateModerationSession(request) {
    const authorization =
      request.headers.get("Authorization") || "";

    const prefix = "Bearer ";

    if (!authorization.startsWith(prefix)) {
      return null;
    }

    const token = authorization.slice(prefix.length);

    if (!token) {
      return null;
    }

    const sessionKey =
      `moderation-session:${token}`;

    const session =
      await this.ctx.storage.get(sessionKey);

    if (!session) {
      return null;
    }

    if (
      typeof session.expiresAt !== "number" ||
      session.expiresAt <= Date.now()
    ) {
      await this.ctx.storage.delete(sessionKey);
      return null;
    }

    if (
      typeof session.nickname !== "string" ||
      typeof session.deviceId !== "number" ||
      typeof session.registrationId !== "number"
    ) {
      return null;
    }

    return session;
  }

  async authenticateModerationAdminSession(request) {
    const authorization =
      request.headers.get("Authorization") || "";

    const prefix = "Bearer ";

    if (!authorization.startsWith(prefix)) {
      return null;
    }

    const token = authorization.slice(prefix.length);

    if (!token) {
      return null;
    }

    const sessionKey =
      `moderation-admin-session:${token}`;

    const session =
      await this.ctx.storage.get(sessionKey);

    if (!session) {
      return null;
    }

    if (
      typeof session.expiresAt !== "number" ||
      session.expiresAt <= Date.now()
    ) {
      await this.ctx.storage.delete(sessionKey);
      return null;
    }

    if (session.role !== "admin") {
      return null;
    }

    return session;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (
      request.method === "GET" &&
      url.pathname === "/v1/moderation/admin/messages"
    ) {
      const session =
        await this.authenticateModerationAdminSession(request);

      if (!session) {
        return Response.json(
          { error: "Unauthorized" },
          { status: 401 },
        );
      }

      const limitValue = Number(url.searchParams.get("limit"));
      const limit =
        Number.isInteger(limitValue) && limitValue > 0
          ? Math.min(limitValue, 100)
          : 50;

      const offsetValue = Number(url.searchParams.get("offset"));
      const offset =
        Number.isInteger(offsetValue) && offsetValue >= 0
          ? offsetValue
          : 0;

      const rows = this.ctx.storage.sql
        .exec(
          `SELECT
             message_id,
             sender,
             recipient,
             chat_id,
             created_at,
             expires_at,
             content_type,
             plaintext,
             attachment_mime_type
           FROM moderation_messages
           WHERE expires_at > ?
           ORDER BY created_at DESC
           LIMIT ? OFFSET ?`,
          Date.now(),
          limit,
          offset,
        )
        .toArray();

      return Response.json({
        messages: rows,
      });
    }


    const adminAttachmentPrefix =
      "/v1/moderation/admin/messages/";
    const adminAttachmentSuffix = "/attachment";

    if (
      request.method === "GET" &&
      url.pathname.startsWith(adminAttachmentPrefix) &&
      url.pathname.endsWith(adminAttachmentSuffix)
    ) {
      const messageId = decodeURIComponent(
        url.pathname.slice(
          adminAttachmentPrefix.length,
          -adminAttachmentSuffix.length,
        ),
      );

      const session =
        await this.authenticateModerationAdminSession(request);

      if (!session) {
        return Response.json(
          { error: "Unauthorized" },
          { status: 401 },
        );
      }

      if (
        typeof messageId !== "string" ||
        messageId.length === 0 ||
        messageId.length > 256
      ) {
        return Response.json(
          { error: "Invalid messageId" },
          { status: 400 },
        );
      }

      const message = this.ctx.storage.sql
        .exec(
          `SELECT
             message_id,
             attachment_mime_type,
             expires_at
           FROM moderation_messages
           WHERE message_id = ?`,
          messageId,
        )
        .one();

      if (!message) {
        return Response.json(
          { error: "Message not found" },
          { status: 404 },
        );
      }

      if (
        typeof message.expires_at !== "number" ||
        message.expires_at <= Date.now()
      ) {
        return Response.json(
          { error: "Message has expired" },
          { status: 410 },
        );
      }

      if (
        typeof message.attachment_mime_type !== "string" ||
        message.attachment_mime_type.length === 0
      ) {
        return Response.json(
          { error: "Message has no attachment" },
          { status: 404 },
        );
      }

      const key = `messages/${messageId}/attachment`;
      const object =
        await this.env.MODERATION_ATTACHMENTS.get(key);

      if (!object) {
        return Response.json(
          { error: "Attachment not found" },
          { status: 404 },
        );
      }

      return new Response(object.body, {
        status: 200,
        headers: {
          "Content-Type": message.attachment_mime_type,
          "Content-Length": String(object.size),
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
        },
      });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/moderation/admin/challenge"
    ) {
      const challenge = createModerationAdminChallenge();
      const expiresAt =
        Date.now() + MODERATION_AUTH_TTL_MS;

      await this.ctx.storage.put(
        `moderation-admin-auth-challenge:${challenge}`,
        {
          challenge,
          expiresAt,
        },
      );

      return Response.json({
        challenge,
        expiresAt,
      });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/moderation/auth/challenge"
    ) {
      const challenge = createModerationChallenge();
      const expiresAt = Date.now() + MODERATION_AUTH_TTL_MS;

      await this.ctx.storage.put(
        `moderation-auth-challenge:${challenge}`,
        {
          challenge,
          expiresAt,
        },
      );

      return Response.json({
        challenge,
        expiresAt,
      });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/moderation/admin/verify"
    ) {
      const adminSecret =
        this.env.MODERATION_ADMIN_SECRET;

      if (
        typeof adminSecret !== "string" ||
        adminSecret.length === 0
      ) {
        return Response.json(
          { error: "Moderation admin authentication unavailable" },
          { status: 503 },
        );
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return Response.json(
          { error: "Invalid JSON" },
          { status: 400 },
        );
      }

      if (
        !body ||
        typeof body !== "object" ||
        Array.isArray(body)
      ) {
        return Response.json(
          { error: "Request body must be a JSON object" },
          { status: 400 },
        );
      }

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge
          : "";

      const proof =
        typeof body.proof === "string"
          ? body.proof
          : "";

      if (!challenge || !proof) {
        return Response.json(
          { error: "Invalid moderation admin auth request" },
          { status: 400 },
        );
      }

      const challengeKey =
        `moderation-admin-auth-challenge:${challenge}`;

      const challengeState =
        await this.ctx.storage.get(challengeKey);

      if (!challengeState) {
        return Response.json(
          { error: "Invalid or expired challenge" },
          { status: 401 },
        );
      }

        if (
          typeof challengeState.expiresAt !== "number" ||
          challengeState.expiresAt <= Date.now()
        ) {
          await this.ctx.storage.delete(challengeKey);

          return Response.json(
            { error: "Invalid or expired challenge" },
            { status: 401 },
          );
        }

        const validProof =
          await verifyModerationAdminProof({
            challenge,
            proof,
            secret: adminSecret,
          });

        if (!validProof) {
          return Response.json(
            { error: "Invalid moderation admin proof" },
            { status: 401 },
          );
        }

        await this.ctx.storage.delete(challengeKey);

        const sessionToken =
          createModerationSessionToken();

        const expiresAt =
          Date.now() + MODERATION_AUTH_TTL_MS;

        await this.ctx.storage.put(
          `moderation-admin-session:${sessionToken}`,
          {
            role: "admin",
            expiresAt,
          },
        );

        return Response.json({
          token: sessionToken,
          expiresAt,
        });
      }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/moderation/auth/verify"
    ) {
      const directoryUrl = this.env.DIRECTORY_URL;
      const sharedSecret = this.env.RELAY_SHARED_SECRET;

      if (!directoryUrl || !sharedSecret) {
        return Response.json(
          { error: "Moderation authentication unavailable" },
          { status: 503 },
        );
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return Response.json(
          { error: "Invalid JSON" },
          { status: 400 },
        );
      }

      if (
        !body ||
        typeof body !== "object" ||
        Array.isArray(body)
      ) {
        return Response.json(
          { error: "Request body must be a JSON object" },
          { status: 400 },
        );
      }

      const nickname =
        typeof body.nickname === "string"
          ? body.nickname.trim().toLowerCase()
          : "";

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
        !/^[a-z0-9_.-]{1,64}$/.test(nickname) ||
        !Number.isInteger(deviceId) ||
        deviceId <= 0 ||
        !Number.isInteger(registrationId) ||
        registrationId <= 0 ||
        !challenge ||
        !signature
      ) {
        return Response.json(
          { error: "Invalid moderation auth request" },
          { status: 400 },
        );
      }

      const challengeKey =
        `moderation-auth-challenge:${challenge}`;

      const challengeState =
        await this.ctx.storage.get(challengeKey);

      if (!challengeState) {
        return Response.json(
          { error: "Invalid or expired challenge" },
          { status: 401 },
        );
      }

      if (
        typeof challengeState.expiresAt !== "number" ||
        challengeState.expiresAt <= Date.now()
      ) {
        await this.ctx.storage.delete(challengeKey);

        return Response.json(
          { error: "Invalid or expired challenge" },
          { status: 401 },
        );
      }

      if (challengeState.challenge !== challenge) {
        return Response.json(
          { error: "Invalid challenge" },
          { status: 401 },
        );
      }

      let verificationResponse;

      try {
        verificationResponse = await fetch(
          `${directoryUrl}/v1/internal/moderation-auth`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${sharedSecret}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              nickname,
              deviceId,
              registrationId,
              challenge,
              signature,
            }),
          },
        );
      } catch (_) {
        return Response.json(
          { error: "Moderation identity verification unavailable" },
          { status: 503 },
        );
      }

      if (!verificationResponse.ok) {
        const bodyText =
          await verificationResponse.text();

        return Response.json(
          {
            error:
              bodyText || "Moderation identity verification failed",
          },
          { status: verificationResponse.status },
        );
      }

      await this.ctx.storage.delete(challengeKey);

      const sessionToken =
        createModerationSessionToken();

      const sessionExpiresAt =
        Date.now() + MODERATION_AUTH_TTL_MS;

      await this.ctx.storage.put(
        `moderation-session:${sessionToken}`,
        {
          nickname,
          deviceId,
          registrationId,
          expiresAt: sessionExpiresAt,
        },
      );

      return Response.json({
        ok: true,
        token: sessionToken,
        expiresAt: sessionExpiresAt,
      });
    }

    const receivedAttachmentPrefix =
      "/v1/moderation/received-messages/";
    const receivedAttachmentSuffix = "/attachment";

    if (
      request.method === "POST" &&
      url.pathname.startsWith(receivedAttachmentPrefix) &&
      url.pathname.endsWith(receivedAttachmentSuffix)
    ) {
      const messageId = decodeURIComponent(
        url.pathname.slice(
          receivedAttachmentPrefix.length,
          -receivedAttachmentSuffix.length,
        ),
      );

      return this.storeReceivedAttachment(request, messageId);
    }

    const attachmentPrefix = "/v1/messages/";
    const attachmentSuffix = "/attachment";

    if (
      request.method === "POST" &&
      url.pathname.startsWith(attachmentPrefix) &&
      url.pathname.endsWith(attachmentSuffix)
    ) {
      const messageId = decodeURIComponent(
        url.pathname.slice(
          attachmentPrefix.length,
          -attachmentSuffix.length,
        ),
      );

      return this.storeAttachment(request, messageId);
    }

    if (url.pathname === "/v1/moderation/received-messages") {
      return this.storeReceivedMessage(request);
    }

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: {
          Allow: "POST",
        },
      });
    }

    const session =
      await this.authenticateModerationSession(request);

    if (!session) {
      return Response.json(
        { error: "Unauthorized" },
        { status: 401 },
      );
    }

    let body;

    try {
      body = await request.json();
    } catch (_) {
      return Response.json(
        { error: "Invalid JSON" },
        { status: 400 },
      );
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return Response.json(
        { error: "Request body must be a JSON object" },
        { status: 400 },
      );
    }

    const requiredStrings = [
      "messageId",
      "sender",
      "recipient",
      "contentType",
      "plaintext",
    ];

    for (const field of requiredStrings) {
      if (
        typeof body[field] !== "string" ||
        body[field].length === 0
      ) {
        return Response.json(
          { error: `Invalid ${field}` },
          { status: 400 },
        );
      }
    }

    if (body.sender !== session.nickname) {
      return Response.json(
        { error: "Sender does not match authenticated identity" },
        { status: 403 },
      );
    }

    if (
      body.messageId.length > 256 ||
      body.sender.length > 256 ||
      body.recipient.length > 256 ||
      body.contentType.length > 128
    ) {
      return Response.json(
        { error: "Metadata field too long" },
        { status: 400 },
      );
    }

    if (body.plaintext.length > 256 * 1024) {
      return Response.json(
        { error: "Plaintext too large" },
        { status: 413 },
      );
    }

    if (
      !Number.isInteger(body.createdAt) ||
      body.createdAt < 0
    ) {
      return Response.json(
        { error: "Invalid message timestamp" },
        { status: 400 },
      );
    }

    const receivedAt = Date.now();
    const expiresAt =
      receivedAt + 7 * 24 * 60 * 60 * 1000;

    const chatId =
      body.chatId == null
        ? null
        : typeof body.chatId === "string" && body.chatId.length <= 256
          ? body.chatId
          : null;

    if (body.chatId != null && chatId == null) {
      return Response.json(
        { error: "Invalid chatId" },
        { status: 400 },
      );
    }

    const result = this.ctx.storage.sql.exec(
      `
        INSERT INTO moderation_messages (
          message_id,
          sender,
          recipient,
          chat_id,
          created_at,
          expires_at,
          content_type,
          plaintext,
          attachment_mime_type
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO NOTHING
      `,
      body.messageId,
      body.sender,
      body.recipient,
      chatId,
      body.createdAt,
      expiresAt,
      body.contentType,
      body.plaintext,
      body.attachmentMimeType ?? null,
    );

    if (result.rowsWritten === 0) {
      await this.scheduleNextAlarm();

      return Response.json(
        { ok: true, stored: false, duplicate: true },
        { status: 200 },
      );
    }

    await this.scheduleNextAlarm();

    return Response.json(
      { ok: true, stored: true },
      { status: 201 },
    );
  }

  async storeReceivedMessage(request) {
    const session =
      await this.authenticateModerationSession(request);

    if (!session) {
      return Response.json(
        { error: "Unauthorized" },
        { status: 401 },
      );
    }

    let body;

    try {
      body = await request.json();
    } catch (_) {
      return Response.json(
        { error: "Invalid JSON" },
        { status: 400 },
      );
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return Response.json(
        { error: "Request body must be a JSON object" },
        { status: 400 },
      );
    }

    const requiredStrings = [
      "messageId",
      "sender",
      "recipient",
      "contentType",
      "plaintext",
    ];

    for (const field of requiredStrings) {
      if (
        typeof body[field] !== "string" ||
        body[field].length === 0
      ) {
        return Response.json(
          { error: `Invalid ${field}` },
          { status: 400 },
        );
      }
    }

    if (body.recipient !== session.nickname) {
      return Response.json(
        { error: "Recipient does not match authenticated identity" },
        { status: 403 },
      );
    }

    if (
      body.messageId.length > 256 ||
      body.sender.length > 256 ||
      body.recipient.length > 256 ||
      body.contentType.length > 128
    ) {
      return Response.json(
        { error: "Metadata field too long" },
        { status: 400 },
      );
    }

    if (body.plaintext.length > 256 * 1024) {
      return Response.json(
        { error: "Plaintext too large" },
        { status: 413 },
      );
    }

    if (
      !Number.isInteger(body.createdAt) ||
      body.createdAt < 0
    ) {
      return Response.json(
        { error: "Invalid message timestamp" },
        { status: 400 },
      );
    }

    const receivedAt = Date.now();
    const expiresAt =
      receivedAt + 7 * 24 * 60 * 60 * 1000;

    const chatId =
      body.chatId == null
        ? null
        : typeof body.chatId === "string" && body.chatId.length <= 256
          ? body.chatId
          : null;

    if (body.chatId != null && chatId == null) {
      return Response.json(
        { error: "Invalid chatId" },
        { status: 400 },
      );
    }

    const result = this.ctx.storage.sql.exec(
      `
        INSERT INTO moderation_messages (
          message_id,
          sender,
          recipient,
          chat_id,
          created_at,
          expires_at,
          content_type,
          plaintext,
          attachment_mime_type
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO NOTHING
      `,
      body.messageId,
      body.sender,
      body.recipient,
      chatId,
      body.createdAt,
      expiresAt,
      body.contentType,
      body.plaintext,
      body.attachmentMimeType ?? null,
    );

    if (result.rowsWritten === 0) {
      await this.scheduleNextAlarm();

      return Response.json(
        { ok: true, stored: false, duplicate: true },
        { status: 200 },
      );
    }

    await this.scheduleNextAlarm();

    return Response.json(
      { ok: true, stored: true },
      { status: 201 },
    );
  }

  async storeReceivedAttachment(request, messageId) {
    const session =
      await this.authenticateModerationSession(request);

    if (!session) {
      return Response.json(
        { error: "Unauthorized" },
        { status: 401 },
      );
    }

    if (
      typeof messageId !== "string" ||
      messageId.length === 0 ||
      messageId.length > 256
    ) {
      return Response.json(
        { error: "Invalid messageId" },
        { status: 400 },
      );
    }

    const message = this.ctx.storage.sql
      .exec(
        `SELECT
           message_id,
           recipient,
           attachment_mime_type,
           expires_at
         FROM moderation_messages
         WHERE message_id = ?`,
        messageId,
      )
      .one();

    if (!message) {
      return Response.json(
        { error: "Message not found" },
        { status: 404 },
      );
    }

    if (message.recipient !== session.nickname) {
      return Response.json(
        { error: "Attachment does not belong to authenticated recipient" },
        { status: 403 },
      );
    }

    if (
      typeof message.expires_at !== "number" ||
      message.expires_at <= Date.now()
    ) {
      return Response.json(
        { error: "Message has expired" },
        { status: 410 },
      );
    }

    const contentType = request.headers.get("Content-Type");

    if (
      typeof message.attachment_mime_type !== "string" ||
      message.attachment_mime_type.length === 0
    ) {
      return Response.json(
        { error: "Message does not declare an attachment MIME type" },
        { status: 400 },
      );
    }

    if (contentType !== message.attachment_mime_type) {
      return Response.json(
        { error: "Attachment MIME type does not match message metadata" },
        { status: 400 },
      );
    }

    if (
      typeof contentType !== "string" ||
      contentType.length === 0 ||
      contentType.length > 128
    ) {
      return Response.json(
        { error: "Invalid attachment MIME type" },
        { status: 400 },
      );
    }

    const contentLength = request.headers.get("Content-Length");
    const declaredLength =
      contentLength == null ? null : Number(contentLength);

    if (
      declaredLength != null &&
      (!Number.isSafeInteger(declaredLength) || declaredLength < 0)
    ) {
      return Response.json(
        { error: "Invalid attachment size" },
        { status: 400 },
      );
    }

    if (
      declaredLength != null &&
      declaredLength > 8 * 1024 * 1024
    ) {
      return Response.json(
        { error: "Attachment is too large. Maximum size is 8 MB." },
        { status: 413 },
      );
    }

    const body = request.body;

    if (body == null) {
      return Response.json(
        { error: "Attachment body is required" },
        { status: 400 },
      );
    }

    const key = `messages/${messageId}/attachment`;

    await this.env.MODERATION_ATTACHMENTS.put(key, body, {
      httpMetadata: {
        contentType,
      },
    });

    return Response.json(
      {
        ok: true,
        stored: true,
        key,
      },
      { status: 201 },
    );
  }

  async storeAttachment(request, messageId) {
    const session =
      await this.authenticateModerationSession(request);

    if (!session) {
      return Response.json(
        { error: "Unauthorized" },
        { status: 401 },
      );
    }

    if (
      typeof messageId !== "string" ||
      messageId.length === 0 ||
      messageId.length > 256
    ) {
      return Response.json(
        { error: "Invalid messageId" },
        { status: 400 },
      );
    }

    const message = this.ctx.storage.sql
      .exec(
        `SELECT message_id, sender, attachment_mime_type, expires_at
         FROM moderation_messages
         WHERE message_id = ?`,
        messageId,
      )
      .one();

    if (!message) {
      return Response.json(
        { error: "Message not found" },
        { status: 404 },
      );
    }

    if (message.sender !== session.nickname) {
      return Response.json(
        { error: "Attachment does not belong to authenticated identity" },
        { status: 403 },
      );
    }

    if (
      typeof message.expires_at !== "number" ||
      message.expires_at <= Date.now()
    ) {
      return Response.json(
        { error: "Message has expired" },
        { status: 410 },
      );
    }

    const contentType = request.headers.get("Content-Type");

    if (
      typeof message.attachment_mime_type !== "string" ||
      message.attachment_mime_type.length === 0
    ) {
      return Response.json(
        { error: "Message does not declare an attachment MIME type" },
        { status: 400 },
      );
    }

    if (contentType !== message.attachment_mime_type) {
      return Response.json(
        { error: "Attachment MIME type does not match message metadata" },
        { status: 400 },
      );
    }

    if (
      typeof contentType !== "string" ||
      contentType.length === 0 ||
      contentType.length > 128
    ) {
      return Response.json(
        { error: "Invalid attachment MIME type" },
        { status: 400 },
      );
    }

    const contentLength = request.headers.get("Content-Length");
    const declaredLength =
      contentLength == null ? null : Number(contentLength);

    if (
      declaredLength != null &&
      (!Number.isSafeInteger(declaredLength) || declaredLength < 0)
    ) {
      return Response.json(
        { error: "Invalid attachment size" },
        { status: 400 },
      );
    }

    if (
      declaredLength != null &&
      declaredLength > 8 * 1024 * 1024
    ) {
      return Response.json(
        { error: "Attachment is too large. Maximum size is 8 MB." },
        { status: 413 },
      );
    }

    const body = request.body;

    if (body == null) {
      return Response.json(
        { error: "Attachment body is required" },
        { status: 400 },
      );
    }

    const key = `messages/${messageId}/attachment`;

    await this.env.MODERATION_ATTACHMENTS.put(key, body, {
      httpMetadata: {
        contentType,
      },
    });

    return Response.json(
      {
        ok: true,
        stored: true,
        key,
      },
      { status: 201 },
    );
  }

  async scheduleNextAlarm() {
    const next = this.ctx.storage.sql
      .exec(
        `SELECT MIN(expires_at) AS next_expires_at
         FROM moderation_messages
         WHERE expires_at > ?`,
        Date.now(),
      )
      .one();

    if (
      !next ||
      next.next_expires_at == null
    ) {
      return;
    }

    const nextExpiresAt = Number(next.next_expires_at);
    const currentAlarm = await this.ctx.storage.getAlarm();

    if (
      currentAlarm == null ||
      nextExpiresAt < currentAlarm
    ) {
      await this.ctx.storage.setAlarm(nextExpiresAt);
    }
  }

  async alarm() {
    const now = Date.now();

    const expired = this.ctx.storage.sql
      .exec(
        `SELECT message_id
         FROM moderation_messages
         WHERE expires_at <= ?`,
        now,
      )
      .toArray();

    for (const row of expired) {
      const messageId = row.message_id;

      if (
        typeof messageId === "string" &&
        messageId.length > 0
      ) {
        await this.env.MODERATION_ATTACHMENTS.delete(
          `messages/${messageId}/attachment`,
        );
      }
    }

    this.ctx.storage.sql.exec(
      `DELETE FROM moderation_messages
       WHERE expires_at <= ?`,
      now,
    );

    await this.scheduleNextAlarm();
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        service: "stellar-relay",
        runtime: {
          DIRECTORY_URL: Boolean(env.DIRECTORY_URL),
          RELAY_SHARED_SECRET: Boolean(env.RELAY_SHARED_SECRET),
        },
      });
    }

    const isModerationAttachment =
      url.pathname.startsWith("/v1/messages/") &&
      url.pathname.endsWith("/attachment");

    const isModerationReceivedMessages =
      url.pathname === "/v1/moderation/received-messages";

    const isModerationReceivedAttachment =
      url.pathname.startsWith(
        "/v1/moderation/received-messages/",
      ) &&
      url.pathname.endsWith("/attachment");

    const isModerationAdminMessages =
      url.pathname === "/v1/moderation/admin/messages";

    const isModerationAdminAttachment =
      url.pathname.startsWith(
        "/v1/moderation/admin/messages/",
      ) &&
      url.pathname.endsWith("/attachment");

    if (
      url.pathname === "/v1/messages" ||
      url.pathname === "/v1/moderation/auth/challenge" ||
      url.pathname === "/v1/moderation/auth/verify" ||
      url.pathname === "/v1/moderation/admin/challenge" ||
      url.pathname === "/v1/moderation/admin/verify" ||
      isModerationAttachment ||
      isModerationReceivedMessages ||
      isModerationReceivedAttachment ||
      isModerationAdminMessages ||
      isModerationAdminAttachment
    ) {
      const isAdminMessagesGet =
        isModerationAdminMessages &&
        request.method === "GET";

      const isAdminAttachmentGet =
        isModerationAdminAttachment &&
        request.method === "GET";

      if (
        !isAdminMessagesGet &&
        !isAdminAttachmentGet &&
        request.method !== "POST"
      ) {
        return new Response("Method Not Allowed", {
          status: 405,
          headers: {
            Allow:
              isModerationAdminMessages ||
              isModerationAdminAttachment
                ? "GET"
                : "POST",
          },
        });
      }

      const id = env.MODERATION.idFromName("global");
      const stub = env.MODERATION.get(id);

      return stub.fetch(request);
    }

    if (url.pathname !== "/v1/connect") {
      return new Response("Not Found", {
        status: 404,
      });
    }

    // All connected users share one relay room.
    const id = env.RELAY.idFromName("global");
    const stub = env.RELAY.get(id);

    return stub.fetch(request);
  },
};
