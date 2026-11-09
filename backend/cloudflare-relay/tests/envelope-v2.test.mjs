import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(
  new URL("../src/index.js", import.meta.url),
  "utf8",
);

const start = source.indexOf("function decodeRecipientRoute(");
const end = source.indexOf("\nfunction base64UrlEncode(", start);

assert.ok(start >= 0 && end > start);

const decoder = new Function(
  source.slice(0, end) + "\nreturn decodeRecipientRoute;",
)();

function makeEnvelope(version, type = 2) {
  const encoder = new TextEncoder();
  const token = encoder.encode("test-token");
  const route = encoder.encode("alice");
  const body = encoder.encode("encrypted-payload");

  const size =
    2 + 4 + 2 + token.length +
    2 + route.length +
    (version === 2 ? 1 : 0) +
    4 + body.length;

  const bytes = new Uint8Array(size);
  const view = new DataView(bytes.buffer);
  let offset = 0;

  view.setUint16(offset, version, false);
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

  if (version === 2) {
    bytes[offset++] = type;
  }

  view.setUint32(offset, body.length, false);
  offset += 4;
  bytes.set(body, offset);

  return bytes;
}

test("Envelope V1 recipient is decoded", () => {
  assert.equal(decoder(makeEnvelope(1)), "alice");
});

test("Envelope V2 Signal recipient is decoded", () => {
  assert.equal(decoder(makeEnvelope(2, 2)), "alice");
});

test("Envelope V2 PreKey recipient is decoded", () => {
  assert.equal(decoder(makeEnvelope(2, 3)), "alice");
});

test("Envelope V2 rejects invalid ciphertext type", () => {
  assert.throws(() => decoder(makeEnvelope(2, 9)));
});

test("Envelope rejects unsupported version", () => {
  assert.throws(() => decoder(makeEnvelope(7)));
});

test("Envelope V2 rejects truncated ciphertext", () => {
  const bytes = makeEnvelope(2);
  assert.throws(() => decoder(bytes.slice(0, -1)));
});
