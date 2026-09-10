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

export class RelayRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
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
