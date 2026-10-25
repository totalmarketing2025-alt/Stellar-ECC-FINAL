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
