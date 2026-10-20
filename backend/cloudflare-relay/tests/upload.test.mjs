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

  assert.match(source, /class RelayRoom/);

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

const uploadId = "123e4567-e89b-12d3-a456-426614174000";

function createHarness() {
  const transfers = new Map();
  const chunks = new Map();
  const sent = [];

  const sql = {
    exec(statement, ...params) {
      const query = statement.replace(/\s+/g, " ").trim();

      if (
        query.startsWith("DELETE FROM relay_upload_chunks") ||
        query.startsWith("DELETE FROM relay_upload_transfers")
      ) {
        return { one: () => null, toArray: () => [] };
      }

      if (
        query.includes("SELECT upload_id FROM relay_upload_transfers")
      ) {
        const row = transfers.get(params[0]);
        return {
          one: () => row ? { upload_id: row.upload_id } : null,
          toArray: () => row ? [{ upload_id: row.upload_id }] : [],
        };
      }

      if (query.startsWith("INSERT INTO relay_upload_transfers")) {
        const [
          id, sender, recipient, totalBytes, chunkCount, createdAt, expiresAt,
        ] = params;

        transfers.set(id, {
          upload_id: id,
          sender,
          recipient,
          total_bytes: totalBytes,
          chunk_count: chunkCount,
          received_count: 0,
          created_at: createdAt,
          expires_at: expiresAt,
          status: "uploading",
        });

        return { one: () => null, toArray: () => [] };
      }

      if (
        query.includes(
          "FROM relay_upload_transfers WHERE upload_id = ?",
        )
      ) {
        const row = transfers.get(params[0]);
        return {
          one: () => row ?? null,
          toArray: () => row ? [row] : [],
        };
      }

      if (
        query.includes("SELECT chunk_index, chunk FROM relay_upload_chunks")
      ) {
        const id = params[0];
        const rows = [...chunks.entries()]
          .filter(([key]) => key.startsWith(`${id}:`))
          .map(([key, chunk]) => ({
            chunk_index: Number(key.slice(id.length + 1)),
            chunk,
          }))
          .sort((a, b) => a.chunk_index - b.chunk_index);
        return {
          one: () => rows[0] ?? null,
          toArray: () => rows,
          [Symbol.iterator]: function* () { yield* rows; },
        };
      }

      if (query.startsWith("SELECT chunk FROM relay_upload_chunks")) {
        const row = chunks.get(`${params[0]}:${params[1]}`);
        return {
          one: () => row ? { chunk: row } : null,
          toArray: () => row ? [{ chunk: row }] : [],
        };
      }

      if (query.startsWith("INSERT INTO relay_upload_chunks")) {
        const [id, index, bytes] = params;
        chunks.set(`${id}:${index}`, new Uint8Array(bytes));
        return { one: () => null, toArray: () => [] };
      }

      if (
        query.startsWith("UPDATE relay_upload_transfers") &&
        query.includes("SET status = 'finalizing'")
      ) {
        const row = transfers.get(params[0]);
        const claimed =
          row &&
          row.sender === params[1] &&
          row.status === "uploading";

        if (claimed) row.status = "finalizing";

        return {
          one: () => claimed ? { upload_id: row.upload_id } : null,
          toArray: () => claimed ? [{ upload_id: row.upload_id }] : [],
        };
      }

      if (
        query.startsWith("UPDATE relay_upload_transfers") &&
        query.includes("SET status = 'completed'")
      ) {
        const row = transfers.get(params[0]);
        if (
          row &&
          row.sender === params[1] &&
          row.status === "finalizing"
        ) {
          row.status = "completed";
        }
        return { one: () => null, toArray: () => [] };
      }

      if (
        query.startsWith("UPDATE relay_upload_transfers") &&
        query.includes("received_count = received_count + 1")
      ) {
        const row = transfers.get(params[0]);
        if (row && row.status === "uploading") {
          row.received_count++;
        }
        return { one: () => null, toArray: () => [] };
      }

      if (query.startsWith("SELECT COALESCE(SUM(length(chunk))")) {
        let receivedBytes = 0;
        for (const [key, bytes] of chunks) {
          if (key.startsWith(`${params[0]}:`)) {
            receivedBytes += bytes.length;
          }
        }
        return {
          one: () => ({ received_bytes: receivedBytes }),
          toArray: () => [{ received_bytes: receivedBytes }],
        };
      }

      throw new Error(`Unhandled test SQL: ${query}`);
    },
  };

  const RelayRoom = loadRelayRoom();
  const room = Object.create(RelayRoom.prototype);
  room.ctx = {
    storage: { sql },
    getWebSockets: () => [],
  };

  const ws = {
    send(message) {
      sent.push(message);
    },
  };

  return { room, ws, sent, transfers, chunks };
}

function startPayload(overrides = {}) {
  return JSON.stringify({
    uploadId,
    recipient: "bob",
    totalBytes: 4,
    chunkCount: 1,
    ...overrides,
  });
}

function makeChunkFrame(bytes, overrides = {}) {
  const id = overrides.uploadId ?? uploadId;
  const index = overrides.index ?? 0;
  const count = overrides.chunkCount ?? 1;
  const total = overrides.totalBytes ?? bytes.length;

  const frame = new Uint8Array(53 + bytes.length);
  frame.set(new TextEncoder().encode("STUP1"), 0);
  frame.set(new TextEncoder().encode(id), 5);

  const view = new DataView(frame.buffer);
  view.setUint32(41, index, false);
  view.setUint32(45, count, false);
  view.setUint32(49, total, false);
  frame.set(bytes, 53);

  return frame;
}

function parsePrefixed(sent, prefix) {
  const message = sent.find((item) => item.startsWith(prefix));
  assert.ok(message, `Expected response with prefix ${prefix}`);
  return JSON.parse(message.slice(prefix.length));
}

const ACK = "STELLAR_UPLOAD_ACK_V1:";
const ERROR = "STELLAR_UPLOAD_ERROR_V1:";

test("upload start creates a transfer and acknowledges zero bytes", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");

  assert.equal(transfers.get(uploadId).recipient, "bob");
  assert.equal(transfers.get(uploadId).status, "uploading");

  assert.deepEqual(parsePrefixed(sent, ACK), {
    type: "started",
    uploadId,
    receivedBytes: 0,
    totalBytes: 4,
  });
});

test("upload start rejects a chunk-count mismatch", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(
    ws,
    startPayload({ chunkCount: 2 }),
    "alice",
  );

  assert.equal(transfers.size, 0);
  assert.equal(parsePrefixed(sent, ERROR).code, "invalid_start");
});

test("upload start rejects an unauthenticated sender", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "");

  assert.equal(transfers.size, 0);
  assert.equal(parsePrefixed(sent, ERROR).code, "invalid_start");
});

test("upload chunk is stored and ACK reports received bytes", async () => {
  const { room, ws, sent, transfers, chunks } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");
  sent.length = 0;

  await room.handleUploadChunk(
    ws,
    makeChunkFrame(new Uint8Array([1, 2, 3, 4])),
    "alice",
  );

  assert.equal(transfers.get(uploadId).received_count, 1);
  assert.deepEqual(
    [...chunks.get(`${uploadId}:0`)],
    [1, 2, 3, 4],
  );

  assert.deepEqual(parsePrefixed(sent, ACK), {
    type: "chunk",
    uploadId,
    index: 0,
    receivedBytes: 4,
    totalBytes: 4,
  });
});

test("identical retransmitted chunk is acknowledged without double counting", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");

  const frame = makeChunkFrame(new Uint8Array([1, 2, 3, 4]));

  await room.handleUploadChunk(ws, frame, "alice");
  await room.handleUploadChunk(ws, frame, "alice");

  assert.equal(transfers.get(uploadId).received_count, 1);

  const acks = sent
    .filter((item) => item.startsWith(ACK))
    .map((item) => JSON.parse(item.slice(ACK.length)));

  assert.equal(acks.length, 3);
  assert.equal(acks[1].receivedBytes, 4);
  assert.equal(acks[2].receivedBytes, 4);
});

test("chunk from a different sender is rejected", async () => {
  const { room, ws, sent, transfers, chunks } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");
  sent.length = 0;

  await room.handleUploadChunk(
    ws,
    makeChunkFrame(new Uint8Array([1, 2, 3, 4])),
    "mallory",
  );

  assert.equal(transfers.get(uploadId).received_count, 0);
  assert.equal(chunks.size, 0);

  assert.equal(
    parsePrefixed(sent, ERROR).code,
    "unknown_or_invalid_transfer",
  );
});


test("DONE rejects an incomplete upload", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");
  sent.length = 0;

  await room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "alice",
  );

  assert.equal(
    parsePrefixed(sent, ERROR).code,
    "upload_incomplete_or_expired",
  );
  assert.equal(transfers.get(uploadId).status, "uploading");
});

test("DONE acknowledges an already completed transfer without redelivery", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");
  transfers.get(uploadId).status = "completed";

  let deliveryCalls = 0;
  room.deliverUploadedEnvelope = async () => {
    deliveryCalls++;
    return "online";
  };

  sent.length = 0;

  await room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "alice",
  );

  assert.equal(deliveryCalls, 0);
  assert.deepEqual(parsePrefixed(sent, ACK), {
    type: "done",
    uploadId,
    totalBytes: 4,
    delivery: "accepted",
  });
});

test("DONE rejects a sender who does not own the transfer", async () => {
  const { room, ws, sent, transfers } = createHarness();

  await room.handleUploadStart(ws, startPayload(), "alice");
  sent.length = 0;

  await room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "mallory",
  );

  assert.equal(
    parsePrefixed(sent, ERROR).code,
    "unknown_transfer",
  );
  assert.equal(transfers.get(uploadId).status, "uploading");
});


function makeEnvelope(recipient) {
  const encoder = new TextEncoder();
  const token = encoder.encode("t");
  const route = encoder.encode(recipient);
  const ciphertext = new Uint8Array([9]);
  const bytes = new Uint8Array(
    2 + 4 + 2 + token.length + 2 + route.length + 4 + ciphertext.length,
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
  view.setUint32(offset, ciphertext.length, false);
  offset += 4;
  bytes.set(ciphertext, offset);

  return bytes;
}

test("DONE delivers a complete envelope and marks transfer completed", async () => {
  const { room, ws, sent, transfers } = createHarness();
  const envelope = makeEnvelope("bob");

  await room.handleUploadStart(
    ws,
    startPayload({ totalBytes: envelope.length }),
    "alice",
  );

  await room.handleUploadChunk(
    ws,
    makeChunkFrame(envelope, { totalBytes: envelope.length }),
    "alice",
  );

  let delivery = null;
  room.deliverUploadedEnvelope = async (...args) => {
    delivery = args;
    return "queued";
  };

  sent.length = 0;

  await room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "alice",
  );

  assert.equal(transfers.get(uploadId).status, "completed");
  assert.equal(delivery[1], "bob");
  assert.equal(delivery[2], "alice");
  assert.deepEqual([...delivery[3]], [...envelope]);

  assert.deepEqual(parsePrefixed(sent, ACK), {
    type: "done",
    uploadId,
    totalBytes: envelope.length,
    delivery: "queued",
  });
});

test("DONE rejects an envelope whose recipient differs from transfer", async () => {
  const { room, ws, sent, transfers } = createHarness();
  const envelope = makeEnvelope("mallory");

  await room.handleUploadStart(
    ws,
    startPayload({ totalBytes: envelope.length }),
    "alice",
  );

  await room.handleUploadChunk(
    ws,
    makeChunkFrame(envelope, { totalBytes: envelope.length }),
    "alice",
  );

  let deliveryCalls = 0;
  room.deliverUploadedEnvelope = async () => {
    deliveryCalls++;
    return "queued";
  };

  sent.length = 0;

  await room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "alice",
  );

  assert.equal(parsePrefixed(sent, ERROR).code, "recipient_mismatch");
  assert.equal(deliveryCalls, 0);
  assert.equal(transfers.get(uploadId).status, "uploading");
});


test("concurrent DONE only delivers once", async () => {
  const { room, ws, sent, transfers } = createHarness();
  const envelope = makeEnvelope("bob");

  await room.handleUploadStart(
    ws,
    startPayload({ totalBytes: envelope.length }),
    "alice",
  );

  await room.handleUploadChunk(
    ws,
    makeChunkFrame(envelope, { totalBytes: envelope.length }),
    "alice",
  );

  let releaseDelivery;
  let deliveryCalls = 0;

  room.deliverUploadedEnvelope = async () => {
    deliveryCalls++;
    return await new Promise((resolve) => {
      releaseDelivery = () => resolve("queued");
    });
  };

  sent.length = 0;

  const firstDone = room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "alice",
  );

  // The first request pauses inside delivery, after claiming finalizing.
  assert.equal(transfers.get(uploadId).status, "finalizing");

  await room.handleUploadDone(
    ws,
    JSON.stringify({ uploadId }),
    "alice",
  );

  assert.equal(deliveryCalls, 1);
  assert.equal(parsePrefixed(sent, ERROR).code, "upload_in_progress");

  releaseDelivery();
  await firstDone;

  assert.equal(deliveryCalls, 1);
  assert.equal(transfers.get(uploadId).status, "completed");
});

test("large upload preserves every byte at 2, 5 and 7 MiB", async (t) => {
  const MiB = 1024 * 1024;
  const chunkSize = 128 * 1024;

  for (const sizeMiB of [2, 5, 7]) {
    await t.test(`${sizeMiB} MiB`, async () => {
      const totalBytes = sizeMiB * MiB;
      const route = new TextEncoder().encode("bob");
      const token = new TextEncoder().encode("t");

      // Valid envelope header followed by deterministic ciphertext bytes.
      const headerBytes = 2 + 4 + 2 + token.length + 2 + route.length + 4;
      const ciphertextLength = totalBytes - headerBytes;
      assert.ok(ciphertextLength > 0);

      const envelope = new Uint8Array(totalBytes);
      const view = new DataView(envelope.buffer);
      let offset = 0;

      view.setUint16(offset, 1, false);
      offset += 2;
      view.setUint32(offset, 3600, false);
      offset += 4;
      view.setUint16(offset, token.length, false);
      offset += 2;
      envelope.set(token, offset);
      offset += token.length;
      view.setUint16(offset, route.length, false);
      offset += 2;
      envelope.set(route, offset);
      offset += route.length;
      view.setUint32(offset, ciphertextLength, false);
      offset += 4;

      for (let i = offset; i < envelope.length; i++) {
        envelope[i] = (i * 31 + 17) & 0xff;
      }

      const chunkCount = Math.ceil(totalBytes / chunkSize);
      const { room, ws, sent, transfers } = createHarness();

      await room.handleUploadStart(
        ws,
        startPayload({ totalBytes, chunkCount }),
        "alice",
      );

      assert.equal(transfers.get(uploadId)?.status, "uploading");

      for (let index = 0; index < chunkCount; index++) {
        const start = index * chunkSize;
        const end = Math.min(start + chunkSize, totalBytes);
        const chunk = envelope.slice(start, end);

        await room.handleUploadChunk(
          ws,
          makeChunkFrame(chunk, {
            index,
            chunkCount,
            totalBytes,
          }),
          "alice",
        );
      }

      assert.equal(transfers.get(uploadId).received_count, chunkCount);

      let delivered = null;
      room.deliverUploadedEnvelope = async (...args) => {
        delivered = args;
        return "queued";
      };

      sent.length = 0;

      await room.handleUploadDone(
        ws,
        JSON.stringify({ uploadId }),
        "alice",
      );

      assert.equal(transfers.get(uploadId).status, "completed");
      assert.ok(delivered, "Expected the envelope to be delivered");
      assert.equal(delivered[1], "bob");
      assert.equal(delivered[2], "alice");
      assert.equal(delivered[3].length, totalBytes);
      assert.deepEqual(delivered[3], envelope);

      assert.deepEqual(parsePrefixed(sent, ACK), {
        type: "done",
        uploadId,
        totalBytes,
        delivery: "queued",
      });
    });
  }
});
