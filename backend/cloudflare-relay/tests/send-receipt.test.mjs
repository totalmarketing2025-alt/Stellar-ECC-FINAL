import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";

const sourceUrl = new URL("../src/index.js", import.meta.url);
const originalSource = await readFile(sourceUrl, "utf8");

function loadRelayRoom() {
  const source = originalSource
    .replace(/\bexport class RelayRoom\b/, "class RelayRoom")
    .replace(/\bexport class ModerationRoom\b/, "class ModerationRoom")
    .replace(/\bexport default\s*\{/, "const worker = {");

  const factory = new Function(
    "crypto",
    "console",
    "TextEncoder",
    "setTimeout",
    "fetch",
    "btoa",
    "atob",
    `${source}\nreturn { RelayRoom };`,
  );

  return factory(
    webcrypto,
    { log() {}, warn() {}, error() {} },
    TextEncoder,
    setTimeout,
    fetch,
    btoa,
    atob,
  ).RelayRoom;
}

const RelayRoom = loadRelayRoom();
const encoder = new TextEncoder();

function makeEnvelope(recipient, payload = "payload") {
  const token = encoder.encode("test-token");
  const route = encoder.encode(recipient);
  const body = encoder.encode(payload);

  const bytes = new Uint8Array(
    2 + 4 + 2 + token.length + 2 + route.length + 4 + body.length,
  );

  const view = new DataView(bytes.buffer);
  let offset = 0;

  view.setUint16(offset, 1, false);
  offset += 2;

  view.setUint32(offset, 3600, false);
  offset += 4;

  view.setUint16(offset, token.length, false);
  offset += 2;
  bytes.set(token, offset);
  offset += token.length;

  view.setUint16(offset, route.length, false);
  offset += 2;
  bytes.set(route, offset);
  offset += route.length;

  view.setUint32(offset, body.length, false);
  offset += 4;

  bytes.set(body, offset);

  return bytes;
}

function createHarness({ failReceiptInsert = false } = {}) {
  const receipts = new Map();
  const queue = [];
  const chunks = [];
  let nextId = 1;

  const sql = {
    exec(statement, ...params) {
      const query = statement.replace(/\s+/g, " ").trim();

      if (query.includes("FROM relay_send_receipts")) {
        const key = `${params[0]}|${params[1]}`;
        const row = receipts.get(key);
        return row ? [ { ...row } ] : [];
      }

      if (
        query.includes("FROM relay_queue") &&
        query.startsWith("SELECT")
      ) {
        const recipient = params[0];
        return queue
          .filter((row) => row.recipient === recipient)
          .map((row) => ({
            id: row.id,
            sender: row.sender,
            envelope: new Uint8Array(row.envelope),
            expires_at: row.expires_at,
            chunked: row.chunked,
            chunk_count: row.chunk_count,
          }));
      }

      if (query.startsWith("INSERT INTO relay_queue")) {
        const [
          recipient, sender, envelope, createdAt,
          expiresAt, chunked, chunkCount,
        ] = params;

        queue.push({
          id: nextId++,
          recipient,
          sender,
          envelope: new Uint8Array(envelope),
          created_at: createdAt,
          expires_at: expiresAt,
          chunked,
          chunk_count: chunkCount,
        });

        return [];
      }

      if (query.includes("last_insert_rowid()")) {
        const result = [{ id: queue.at(-1).id }];
        result.one = () => result[0];
        return result;
      }

      if (query.startsWith("INSERT INTO relay_queue_chunks")) {
        chunks.push({
          delivery_id: params[0],
          chunk_index: params[1],
          chunk: new Uint8Array(params[2]),
        });
        return [];
      }

      if (query.startsWith("INSERT INTO relay_send_receipts")) {
        if (failReceiptInsert) {
          throw new Error("SIMULATED_RECEIPT_INSERT_FAILURE");
        }

        const [
          sender, receiptId, recipient, envelopeHash,
          deliveryId, createdAt,
        ] = params;

        receipts.set(`${sender}|${receiptId}`, {
          sender,
          receipt_id: receiptId,
          recipient,
          envelope_hash: envelopeHash,
          delivery_id: deliveryId,
          created_at: createdAt,
        });

        return [];
      }

      if (query.startsWith("DELETE FROM relay_queue_chunks")) {
        const [deliveryId, recipient] = params;
        const owned = queue.some(
          (row) => row.id === deliveryId && row.recipient === recipient
        );

        if (owned) {
          for (let i = chunks.length - 1; i >= 0; i--) {
            if (chunks[i].delivery_id === deliveryId) {
              chunks.splice(i, 1);
            }
          }
        }

        return [];
      }

      if (query.startsWith("DELETE FROM relay_queue")) {
        const [deliveryId, recipient] = params;

        for (let i = queue.length - 1; i >= 0; i--) {
          if (
            queue[i].id === deliveryId &&
            queue[i].recipient === recipient
          ) {
            queue.splice(i, 1);
          }
        }

        return [];
      }

      throw new Error(`Unexpected SQL in test: ${query}`);
    },
  };

  const storage = {
    sql,

    transactionSync(callback) {
      const oldReceipts = new Map(
        [...receipts].map(([key, value]) => [key, { ...value }]),
      );
      const oldQueue = queue.map((row) => ({
        ...row,
        envelope: new Uint8Array(row.envelope),
      }));
      const oldChunks = chunks.map((row) => ({
        ...row,
        chunk: new Uint8Array(row.chunk),
      }));
      const oldNextId = nextId;

      try {
        return callback();
      } catch (error) {
        receipts.clear();
        for (const [key, value] of oldReceipts) {
          receipts.set(key, value);
        }

        queue.splice(0, queue.length, ...oldQueue);
        chunks.splice(0, chunks.length, ...oldChunks);
        nextId = oldNextId;

        throw error;
      }
    },
  };

  const room = Object.create(RelayRoom.prototype);
  room.ctx = { storage };
  room.env = {};

  return { room, receipts, queue, chunks };
}

test("first send durably queues envelope and receipt", async () => {
  const h = createHarness();
  const envelope = makeEnvelope("recipient-a");

  const result = await h.room.queueEnvelopeWithReceipt(
    "recipient-a", "sender-a", envelope, "receipt-001",
  );

  assert.equal(result.duplicate, false);
  assert.equal(result.deliveryId, 1);
  assert.equal(h.queue.length, 1);
  assert.equal(h.receipts.size, 1);
  assert.equal(h.queue[0].recipient, "recipient-a");
});

test("retry with same receipt and bytes does not duplicate queue row", async () => {
  const h = createHarness();
  const envelope = makeEnvelope("recipient-a");

  const first = await h.room.queueEnvelopeWithReceipt(
    "recipient-a", "sender-a", envelope, "receipt-002",
  );

  const second = await h.room.queueEnvelopeWithReceipt(
    "recipient-a", "sender-a", envelope, "receipt-002",
  );

  assert.equal(first.duplicate, false);
  assert.equal(second.duplicate, true);
  assert.equal(second.deliveryId, first.deliveryId);
  assert.equal(h.queue.length, 1);
  assert.equal(h.receipts.size, 1);
});

test("reusing receipt ID with different envelope is rejected", async () => {
  const h = createHarness();

  await h.room.queueEnvelopeWithReceipt(
    "recipient-a", "sender-a",
    makeEnvelope("recipient-a", "original"),
    "receipt-003",
  );

  await assert.rejects(
    h.room.queueEnvelopeWithReceipt(
      "recipient-a", "sender-a",
      makeEnvelope("recipient-a", "modified"),
      "receipt-003",
    ),
    /RELAY_RECEIPT_ID_CONFLICT/,
  );

  assert.equal(h.queue.length, 1);
  assert.equal(h.receipts.size, 1);
});

test("receipt insert failure rolls back queue insert", async () => {
  const h = createHarness({ failReceiptInsert: true });

  await assert.rejects(
    h.room.queueEnvelopeWithReceipt(
      "recipient-a", "sender-a",
      makeEnvelope("recipient-a"),
      "receipt-004",
    ),
    /SIMULATED_RECEIPT_INSERT_FAILURE/,
  );

  assert.equal(h.queue.length, 0);
  assert.equal(h.receipts.size, 0);
  assert.equal(h.chunks.length, 0);
});


function createDirectDeliveryHarness({ failOnSendCall }) {
  const h = createHarness();
  const senderAttachment = {
    peer: "sender-a",
    authenticated: true,
    authState: "authenticated",
  };
  const recipientAttachment = {
    peer: "recipient-a",
    authenticated: true,
    authState: "authenticated",
  };

  let sendCalls = 0;

  const senderSocket = {
    deserializeAttachment() {
      return senderAttachment;
    },
  };

  const recipientSocket = {
    deserializeAttachment() {
      return recipientAttachment;
    },
    send(_data) {
      sendCalls += 1;
      if (sendCalls === failOnSendCall) {
        throw new Error("SIMULATED_WEBSOCKET_DISCONNECT");
      }
    },
  };

  h.room.ctx.getWebSockets = () => [
    senderSocket,
    recipientSocket,
  ];
  h.room.ctx.waitUntil = () => {};

  return { ...h, senderSocket, sendCalls: () => sendCalls };
}

test("legacy direct delivery queues when recipient socket drops sender marker", async () => {
  const h = createDirectDeliveryHarness({ failOnSendCall: 1 });
  const envelope = makeEnvelope("recipient-a");

  await h.room.webSocketMessage(
    h.senderSocket,
    envelope,
  );

  assert.equal(
    h.queue.length,
    1,
    "Envelope must remain durably queued when the recipient disconnects",
  );
  assert.equal(h.queue[0].recipient, "recipient-a");
  assert.equal(h.queue[0].sender, "sender-a");
});

test("legacy direct delivery queues when recipient socket drops envelope", async () => {
  const h = createDirectDeliveryHarness({ failOnSendCall: 2 });
  const envelope = makeEnvelope("recipient-a");

  await h.room.webSocketMessage(
    h.senderSocket,
    envelope,
  );

  assert.equal(
    h.queue.length,
    1,
    "Envelope must remain durably queued when binary delivery fails",
  );
  assert.equal(h.queue[0].recipient, "recipient-a");
  assert.equal(h.queue[0].sender, "sender-a");
});

test("legacy direct delivery remains queued until recipient ACK", async () => {
  const h = createDirectDeliveryHarness({ failOnSendCall: 0 });
  const envelope = makeEnvelope("recipient-a");

  await h.room.webSocketMessage(
    h.senderSocket,
    envelope,
  );

  assert.equal(
    h.queue.length,
    1,
    "Online delivery must remain durable until recipient ACK",
  );
  assert.equal(h.queue[0].recipient, "recipient-a");
  assert.equal(h.queue[0].sender, "sender-a");
});


function createAckSocket(peer, authenticated = true) {
  const sent = [];

  return {
    sent,
    deserializeAttachment() {
      return {
        peer,
        authenticated,
        authState: authenticated ? "authenticated" : "pending",
      };
    },
    send(data) {
      sent.push(data);
    },
  };
}

test("valid recipient ACK deletes its queue row and chunks", async () => {
  const h = createHarness();

  const queued = await h.room.queueEnvelopeWithReceipt(
    "recipient-a",
    "sender-a",
    makeEnvelope("recipient-a"),
    "ack-test-001",
  );

  h.chunks.push(
    { delivery_id: queued.deliveryId, chunk_index: 0, chunk: new Uint8Array([1, 2]) },
    { delivery_id: queued.deliveryId, chunk_index: 1, chunk: new Uint8Array([3, 4]) },
  );

  const socket = createAckSocket("recipient-a");

  await h.room.webSocketMessage(
    socket,
    `STELLAR_RELAY_ACK_V1:${queued.deliveryId}`,
  );

  assert.equal(h.queue.length, 0);
  assert.equal(h.chunks.length, 0);
  assert.deepEqual(
    socket.sent,
    [`STELLAR_RELAY_ACK_OK_V1:${queued.deliveryId}`],
  );
});

test("wrong recipient ACK cannot delete another recipient queue row or chunks", async () => {
  const h = createHarness();

  const queued = await h.room.queueEnvelopeWithReceipt(
    "recipient-a",
    "sender-a",
    makeEnvelope("recipient-a"),
    "ack-test-002",
  );

  h.chunks.push({
    delivery_id: queued.deliveryId,
    chunk_index: 0,
    chunk: new Uint8Array([5, 6]),
  });

  const socket = createAckSocket("recipient-b");

  await h.room.webSocketMessage(
    socket,
    `STELLAR_RELAY_ACK_V1:${queued.deliveryId}`,
  );

  assert.equal(h.queue.length, 1);
  assert.equal(h.queue[0].recipient, "recipient-a");
  assert.equal(h.chunks.length, 1);
  assert.equal(h.chunks[0].delivery_id, queued.deliveryId);
});

test("repeated recipient ACK does not affect other queued deliveries", async () => {
  const h = createHarness();

  const first = await h.room.queueEnvelopeWithReceipt(
    "recipient-a",
    "sender-a",
    makeEnvelope("recipient-a"),
    "ack-test-003",
  );

  const second = await h.room.queueEnvelopeWithReceipt(
    "recipient-a",
    "sender-b",
    makeEnvelope("recipient-a", "second"),
    "ack-test-004",
  );

  const socket = createAckSocket("recipient-a");

  await h.room.webSocketMessage(
    socket,
    `STELLAR_RELAY_ACK_V1:${first.deliveryId}`,
  );

  await h.room.webSocketMessage(
    socket,
    `STELLAR_RELAY_ACK_V1:${first.deliveryId}`,
  );

  assert.equal(h.queue.length, 1);
  assert.equal(h.queue[0].id, second.deliveryId);
  assert.equal(socket.sent.length, 2);
});


function createReceiptWakeHarness({ online = false, failOnSendCall = 0 } = {}) {
  const h = createHarness();
  const pending = [];
  const wakes = [];
  let recipientSendCalls = 0;

  const senderSocket = {
    sent: [],
    deserializeAttachment() {
      return {
        peer: "sender-a",
        authenticated: true,
        authState: "authenticated",
      };
    },
    send(data) {
      this.sent.push(data);
    },
  };

  const recipientSocket = {
    sent: [],
    deserializeAttachment() {
      return {
        peer: "recipient-a",
        authenticated: true,
        authState: "authenticated",
      };
    },
    send(data) {
      recipientSendCalls++;
      if (recipientSendCalls === failOnSendCall) {
        throw new Error("SIMULATED_WEBSOCKET_DISCONNECT");
      }
      this.sent.push(data);
    },
  };

  h.room.ctx.getWebSockets = () =>
    online ? [senderSocket, recipientSocket] : [senderSocket];

  h.room.ctx.waitUntil = (promise) => pending.push(promise);

  h.room.sendPushWake = async (recipient) => {
    wakes.push(recipient);
  };

  return {
    ...h,
    senderSocket,
    recipientSocket,
    pending,
    wakes,
  };
}

test("offline receipt recipient receives an FCM wake-up", async () => {
  const h = createReceiptWakeHarness({ online: false });

  await h.room.handleSendWithReceipt(
    h.senderSocket,
    "wake-offline-001",
    makeEnvelope("recipient-a"),
  );

  await Promise.all(h.pending);

  assert.equal(h.queue.length, 1);
  assert.deepEqual(h.wakes, ["recipient-a"]);
  assert.equal(h.senderSocket.sent.length, 1);
});

test("online receipt delivery does not send an unnecessary FCM wake-up", async () => {
  const h = createReceiptWakeHarness({ online: true });

  await h.room.handleSendWithReceipt(
    h.senderSocket,
    "wake-online-001",
    makeEnvelope("recipient-a"),
  );

  await Promise.all(h.pending);

  assert.equal(h.queue.length, 1);
  assert.equal(h.wakes.length, 0);
  assert.equal(h.recipientSocket.sent.length, 3);
});

test("receipt delivery failure keeps the queue and sends an FCM wake-up", async () => {
  const h = createReceiptWakeHarness({
    online: true,
    failOnSendCall: 3,
  });

  await h.room.handleSendWithReceipt(
    h.senderSocket,
    "wake-failure-001",
    makeEnvelope("recipient-a"),
  );

  await Promise.all(h.pending);

  assert.equal(h.queue.length, 1);
  assert.deepEqual(h.wakes, ["recipient-a"]);
});


// Reaction payloads are opaque to the relay. These tests verify that
// their encrypted envelope uses the same durable delivery and ACK protocol.

test("reaction envelope is durably queued for an offline recipient", async () => {
  const h = createReceiptWakeHarness({ online: false });
  const envelope = makeEnvelope(
    "recipient-a",
    "STELLAR_REACTION_V1:" +
      JSON.stringify({
        messageId: "message-reaction-001",
        emoji: "❤️",
      }),
  );

  await h.room.handleSendWithReceipt(
    h.senderSocket,
    "reaction-offline-001",
    envelope,
  );

  await Promise.all(h.pending);

  assert.equal(h.queue.length, 1);
  assert.equal(h.queue[0].recipient, "recipient-a");
  assert.equal(h.queue[0].sender, "sender-a");
  assert.deepEqual(h.queue[0].envelope, envelope);
  assert.deepEqual(h.wakes, ["recipient-a"]);
  assert.deepEqual(
    h.senderSocket.sent,
    ["STELLAR_RELAY_SEND_OK_V1:reaction-offline-001"],
  );
});

test("reaction receipt retry with identical bytes does not duplicate the queue row", async () => {
  const h = createHarness();
  const envelope = makeEnvelope(
    "recipient-a",
    "STELLAR_REACTION_V1:" +
      JSON.stringify({
        messageId: "message-reaction-002",
        emoji: "😂",
      }),
  );

  const first = await h.room.queueEnvelopeWithReceipt(
    "recipient-a",
    "sender-a",
    envelope,
    "reaction-retry-001",
  );

  const retry = await h.room.queueEnvelopeWithReceipt(
    "recipient-a",
    "sender-a",
    envelope,
    "reaction-retry-001",
  );

  assert.equal(first.duplicate, false);
  assert.equal(retry.duplicate, true);
  assert.equal(retry.deliveryId, first.deliveryId);
  assert.equal(h.queue.length, 1);
  assert.deepEqual(h.queue[0].envelope, envelope);
});

test("recipient retrieves reaction envelope and ACK removes its queued row", async () => {
  const h = createReceiptWakeHarness({ online: false });
  const envelope = makeEnvelope(
    "recipient-a",
    "STELLAR_REACTION_V1:" +
      JSON.stringify({
        messageId: "message-reaction-003",
        emoji: "👍",
      }),
  );

  await h.room.handleSendWithReceipt(
    h.senderSocket,
    "reaction-delivery-001",
    envelope,
  );

  await Promise.all(h.pending);

  assert.equal(h.queue.length, 1);
  const deliveryId = h.queue[0].id;

  const flushed = await h.room.flushQueue(
    h.recipientSocket,
    "recipient-a",
  );

  assert.equal(flushed, true);
  assert.equal(h.recipientSocket.sent.length, 3);
  assert.equal(
    h.recipientSocket.sent[0],
    `STELLAR_RELAY_DELIVERY_V1:${deliveryId}`,
  );
  assert.equal(
    h.recipientSocket.sent[1],
    "STELLAR_RELAY_SENDER_V1:sender-a",
  );
  assert.deepEqual(h.recipientSocket.sent[2], envelope);

  // Sending the envelope is not enough to delete it.
  assert.equal(h.queue.length, 1);

  await h.room.webSocketMessage(
    h.recipientSocket,
    `STELLAR_RELAY_ACK_V1:${deliveryId}`,
  );

  assert.equal(h.queue.length, 0);
  assert.equal(
    h.recipientSocket.sent[3],
    `STELLAR_RELAY_ACK_OK_V1:${deliveryId}`,
  );
});
