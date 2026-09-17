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
    throw new Error("FCM OAuth token request failed");
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

export class RelayRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;

    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS relay_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipient TEXT NOT NULL,
        envelope BLOB NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      )
    `);
  }

  async queueEnvelope(recipient, message) {
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

    await this.ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS relay_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipient TEXT NOT NULL,
        envelope BLOB NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      )`,
    );

    await this.ctx.storage.sql.exec(
      `INSERT INTO relay_queue
        (recipient, envelope, created_at, expires_at)
       VALUES (?, ?, ?, ?)`,
      recipient,
      bytes,
      createdAt,
      expiresAt,
    );
  }

  async flushQueue(ws, recipient) {
    const now = Date.now();

    const result = this.ctx.storage.sql.exec(
      `SELECT id, envelope, expires_at
       FROM relay_queue
       WHERE recipient = ?
       ORDER BY id ASC`,
      recipient,
    );

    for (const row of result) {
      try {
        if (Number(row.expires_at) <= now) {
          this.ctx.storage.sql.exec(
            `DELETE FROM relay_queue WHERE id = ?`,
            row.id,
          );
          continue;
        }

        const envelope = new Uint8Array(row.envelope);
        ws.send(envelope);

        this.ctx.storage.sql.exec(
          `DELETE FROM relay_queue WHERE id = ?`,
          row.id,
        );
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
      return;
    }

    const body = await response.json();

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
      return;
    }

    const accessToken = await createFcmAccessToken(
      clientEmail,
      privateKey,
    );

    const sends = validRegistrations.map((registration) =>
      fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
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
              android: {
                priority: "high",
              },
            },
          }),
        },
      ).catch(() => null),
    );

    await Promise.all(sends);
  }

  async fetch(request) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return Response.json({
        ok: true,
        service: "stellar-relay",
      });
    }

    const peer = new URL(request.url).searchParams.get("peer");

    if (!peer) {
      return new Response("Missing peer", { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    this.ctx.acceptWebSocket(server);

    const normalizedPeer = peer.trim().toLowerCase();

    server.serializeAttachment({
      peer: normalizedPeer,
    });

    await this.ctx.blockConcurrencyWhile(async () => {
      await this.flushQueue(server, normalizedPeer);
    });

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  async webSocketMessage(ws, message) {
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
          }).catch((error) => {
            console.error("FCM_CALL_WAKE_ERROR", error);
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

    for (const peer of this.ctx.getWebSockets()) {
      if (peer === ws) {
        continue;
      }

      try {
        const attachment = peer.deserializeAttachment();

        if (
          attachment &&
          attachment.peer === recipient
        ) {
          peer.send(message);
          return;
        }
      } catch (_) {
        // Ignore disconnected peers.
      }
    }

    await this.queueEnvelope(recipient, message);

    // Push notification must never block or break relay delivery.
    // The envelope is already safely queued before FCM is attempted.
    this.ctx.waitUntil(
      this.sendPushWake(recipient).catch((error) => {
        console.error("FCM_PUSH_WAKE_ERROR", error);
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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        service: "stellar-relay",
      });
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
