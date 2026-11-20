import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { webcrypto, randomUUID } from "node:crypto";

const source = fs.readFileSync(
  new URL("../src/index.js", import.meta.url), "utf8",
).replace(/\nexport default[\s\S]*$/, "")
  .replace(/export class DirectoryStore/g, "class DirectoryStore");

const { DirectoryStore } = new Function(
  "crypto", "btoa", "atob", "TextEncoder",
  `${source}\nreturn { DirectoryStore };`,
)(webcrypto, btoa, atob, TextEncoder);

class Storage {
  constructor() {
    this.items = new Map();
    this.lock = Promise.resolve();
  }

  async get(key) {
    return this.items.has(key) ? structuredClone(this.items.get(key)) : undefined;
  }

  async put(key, value) {
    this.items.set(key, structuredClone(value));
  }

  async delete(key) {
    return this.items.delete(key);
  }

  async list({ prefix = "", startAfter, limit = Infinity } = {}) {
    const keys = [...this.items.keys()]
      .filter((key) => key.startsWith(prefix) &&
        (startAfter === undefined || key > startAfter))
      .sort().slice(0, limit);
    return new Map(await Promise.all(keys.map(async (key) => [
      key, await this.get(key),
    ])));
  }

  async transaction(fn) {
    let release;
    const previous = this.lock;
    this.lock = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      return await fn(this);
    } finally {
      release();
    }
  }
}

const P = (1n << 255n) - 19n;

function mod(n) {
  return ((n % P) + P) % P;
}

function modPow(base, exponent) {
  let result = 1n;
  for (; exponent > 0n; exponent >>= 1n) {
    if (exponent & 1n) result = mod(result * base);
    base = mod(base * base);
  }
  return result;
}

function leBigInt(bytes) {
  return bytes.reduceRight((n, byte) => (n << 8n) | BigInt(byte), 0n);
}

function bytesLE(value, length) {
  const bytes = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    bytes[i] = Number(value & 255n);
    value >>= 8n;
  }
  return bytes;
}

async function identity() {
  const pair = await webcrypto.subtle.generateKey(
    { name: "Ed25519" }, true, ["sign", "verify"],
  );
  const ed = new Uint8Array(await webcrypto.subtle.exportKey("raw", pair.publicKey));
  const signBit = ed[31] >>> 7;
  ed[31] &= 127;
  const y = leBigInt(ed);
  const u = mod((1n + y) * modPow(mod(1n - y), P - 2n));
  const encoded = btoa(String.fromCharCode(5, ...bytesLE(u, 32)));

  return {
    encoded,
    async sign(message) {
      const sig = new Uint8Array(await webcrypto.subtle.sign(
        { name: "Ed25519" }, pair.privateKey,
        new TextEncoder().encode(message),
      ));
      sig[63] |= signBit << 7;
      return btoa(String.fromCharCode(...sig));
    },
  };
}

function bundle(identityKey) {
  return {
    deviceId: 1,
    registrationId: 101,
    identityKey,
    signedPreKey: {
      keyId: 3,
      publicKey: identityKey,
      signature: btoa(String.fromCharCode(...new Uint8Array(64))),
    },
    preKey: { keyId: 4, publicKey: identityKey },
  };
}

async function post(directory, path, body) {
  const res = await directory.fetch(new Request(`https://directory.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }));
  return { status: res.status, body: await res.json() };
}

async function setup() {
  const storage = new Storage();
  const directory = new DirectoryStore({ storage }, {});
  const alice = await identity();
  const bob = await identity();
  for (const [nickname, id] of [["alice", alice], ["bob", bob]]) {
    const response = await post(directory, "/v1/register", {
      nickname, bundle: bundle(id.encoded),
    });
    assert.equal(response.status, 201);
  }
  return { storage, directory, alice, bob };
}

const baseProof = (nickname, challenge) => ({
  nickname, deviceId: 1, registrationId: 101, challenge,
});

async function issue(directory, nickname, purpose) {
  return post(directory, "/v1/guard/cases/challenge", {
    nickname, deviceId: 1, registrationId: 101, purpose,
  });
}

async function action(directory, nickname, id, purpose, options = {}) {
  const issued = await issue(directory, nickname, purpose);
  assert.equal(issued.status, 200);
  const fields = { ...baseProof(nickname, issued.body.challenge), ...options };
  const caseId = options.caseId || "";
  const message = JSON.stringify([
    "stellar-guard-case-v1", purpose,
    nickname, 1, 101, fields.challenge, caseId,
    purpose === "submit" ? fields.targetCode : "",
    purpose === "submit" ? fields.reason : "",
    purpose === "submit" ? fields.details : "",
    purpose === "submit" ? fields.idempotencyKey : "",
  ]);
  const signature = await id.sign(message);
  const route = purpose === "submit"
    ? "/v1/guard/cases"
    : `/v1/guard/cases/${caseId}/${purpose}`;
  return post(directory, route, { ...fields, signature });
}

function submission(targetCode, overrides = {}) {
  return {
    targetCode,
    reason: "harassment",
    details: "Repeated unwanted contact despite requests to stop.",
    idempotencyKey: randomUUID(),
    ...overrides,
  };
}

test("authenticated submission persists a pending case, without approving or deleting", async () => {
  const { directory, storage, alice, bob } = await setup();
  const bobCode = (await storage.get("user:bob")).guardCode;
  const response = await action(directory, "alice", alice, "submit", submission(bobCode));

  assert.equal(response.status, 200);
  assert.equal(response.body.status, "pending_review");
  assert.match(response.body.caseId, /^[0-9a-f-]{36}$/);
  assert.deepEqual(Object.keys(response.body).sort(), [
    "caseId", "createdAt", "status", "updatedAt",
  ]);

  const stored = await storage.get(`guard-case:${response.body.caseId}`);
  assert.equal(stored.requester, "alice");
  assert.equal(stored.targetNickname, "bob");
  assert.equal(stored.targetCode, bobCode);
  assert.equal((await storage.get("user:bob")).guardCode, bobCode);
  assert.equal((await storage.get("user:alice")).nickname, "alice");

  const status = await action(directory, "alice", alice, "status", {
    caseId: response.body.caseId,
  });
  assert.equal(status.status, 200);
  assert.deepEqual(status.body, response.body);

  // No public status, moderator approval or deletion API is introduced here.
  assert.equal((await directory.fetch(new Request(
    `https://directory.test/v1/guard/cases/${response.body.caseId}`,
  ))).status, 404);
  assert.equal((await directory.fetch(new Request(
    `https://directory.test/v1/guard/cases/${response.body.caseId}/approve`,
    { method: "POST" },
  ))).status, 404);
});

test("unknown codes get the same receipt and never expose account existence", async () => {
  const { directory, storage, alice } = await setup();
  const records = [];
  for (const targetCode of ["111111111", (await storage.get("user:bob")).guardCode]) {
    const result = await action(directory, "alice", alice, "submit", submission(targetCode));
    assert.equal(result.status, 200);
    assert.equal(result.body.status, "pending_review");
    assert.equal("targetNickname" in result.body, false);
    assert.equal("targetCode" in result.body, false);
    records.push(await storage.get(`guard-case:${result.body.caseId}`));
  }
  assert.equal(records[0].targetNickname, null);
  assert.equal(records[1].targetNickname, "bob");
});

test("invalid signatures and modified signed payloads cannot create cases", async () => {
  const { directory, storage, alice, bob } = await setup();
  const targetCode = (await storage.get("user:bob")).guardCode;
  const issued = await issue(directory, "alice", "submit");
  const fields = { ...baseProof("alice", issued.body.challenge), ...submission(targetCode) };

  const message = JSON.stringify([
    "stellar-guard-case-v1", "submit", "alice", 1, 101,
    fields.challenge, "", targetCode, fields.reason, fields.details, fields.idempotencyKey,
  ]);

  const wrongSignature = await bob.sign(message);
  assert.equal((await post(directory, "/v1/guard/cases", {
    ...fields, signature: wrongSignature,
  })).status, 401);

  // Consumed challenges cannot be replayed with a later genuine signature.
  assert.equal((await post(directory, "/v1/guard/cases", {
    ...fields, signature: await alice.sign(message),
  })).status, 401);

  const again = await issue(directory, "alice", "submit");
  const updated = { ...fields, challenge: again.body.challenge };
  const signed = await alice.sign(JSON.stringify([
    "stellar-guard-case-v1", "submit", "alice", 1, 101,
    updated.challenge, "", targetCode, updated.reason, updated.details, updated.idempotencyKey,
  ]));
  assert.equal((await post(directory, "/v1/guard/cases", {
    ...updated, reason: "scam", signature: signed,
  })).status, 401);
  assert.equal([...storage.items.keys()].filter((key) =>
    key.startsWith("guard-case:")).length, 0);
});

test("case status and cancellation require the original account", async () => {
  const { directory, storage, alice, bob } = await setup();
  const code = (await storage.get("user:bob")).guardCode;
  const created = await action(directory, "alice", alice, "submit", submission(code));
  const caseId = created.body.caseId;

  const foreignStatus = await action(directory, "bob", bob, "status", { caseId });
  assert.equal(foreignStatus.status, 404);
  const foreignCancel = await action(directory, "bob", bob, "cancel", { caseId });
  assert.equal(foreignCancel.status, 404);
  assert.equal((await storage.get(`guard-case:${caseId}`)).status, "pending_review");

  const cancellation = await action(directory, "alice", alice, "cancel", { caseId });
  assert.equal(cancellation.status, 200);
  assert.equal(cancellation.body.status, "cancelled");
  assert.equal(await storage.get(`guard-case-active:alice:${code}`), undefined);
  assert.equal((await storage.get(`guard-case:${caseId}`)).status, "cancelled");

  const again = await action(directory, "alice", alice, "cancel", { caseId });
  assert.equal(again.body.status, "cancelled");
  assert.equal((await action(directory, "alice", alice, "status", {
    caseId,
  })).body.status, "cancelled");
});

test("retries are idempotent and an active case cannot be duplicated", async () => {
  const { directory, storage, alice } = await setup();
  const targetCode = (await storage.get("user:bob")).guardCode;
  const form = submission(targetCode);
  const first = await action(directory, "alice", alice, "submit", form);
  assert.equal(first.status, 200);

  const replay = await action(directory, "alice", alice, "submit", form);
  assert.deepEqual(replay.body, first.body);
  const changed = await action(directory, "alice", alice, "submit", {
    ...form, details: "A different report description must not be accepted.",
  });
  assert.equal(changed.status, 409);

  const freshKey = await action(directory, "alice", alice, "submit", submission(targetCode));
  assert.deepEqual(freshKey.body, first.body);
  assert.equal((await storage.get("guard-case-submit-limit:alice")).count, 1);

  await action(directory, "alice", alice, "cancel", { caseId: first.body.caseId });
  const restarted = await action(directory, "alice", alice, "submit", submission(targetCode));
  assert.notEqual(restarted.body.caseId, first.body.caseId);
  assert.equal((await storage.get("guard-case-submit-limit:alice")).count, 2);
});

test("case challenges are purpose-specific, time-limited, and throttled", async () => {
  const { directory, storage, alice } = await setup();
  assert.equal((await post(directory, "/v1/guard/cases/challenge", {
    nickname: "alice", deviceId: 2, registrationId: 101, purpose: "submit",
  })).status, 404);
  assert.equal((await post(directory, "/v1/guard/cases/challenge", {
    nickname: "alice", deviceId: 1, registrationId: 101, purpose: "approve",
  })).status, 400);

  const issued = await issue(directory, "alice", "status");
  assert.equal(issued.status, 200);
  const fields = baseProof("alice", issued.body.challenge);
  const signature = await alice.sign(JSON.stringify([
    "stellar-guard-case-v1", "cancel", "alice", 1, 101,
    fields.challenge, randomUUID(), "", "", "", "",
  ]));
  assert.equal((await post(directory, "/v1/guard/cases", {
    ...fields, signature, ...submission("111111111"),
  })).status, 401);

  const expired = await issue(directory, "alice", "submit");
  await storage.put("guard-case-challenge:alice:1:101", {
    challenge: expired.body.challenge,
    purpose: "submit", expiresAt: Date.now() - 1,
  });
  const expiredForm = submission("111111111");
  const signedExpired = await alice.sign(JSON.stringify([
    "stellar-guard-case-v1", "submit", "alice", 1, 101,
    expired.body.challenge, "", expiredForm.targetCode,
    expiredForm.reason, expiredForm.details, expiredForm.idempotencyKey,
  ]));
  assert.equal((await post(directory, "/v1/guard/cases", {
    ...fields, challenge: expired.body.challenge,
    ...expiredForm, signature: signedExpired,
  })).status, 401);

  for (let i = 0; i < 18; i++) {
    assert.equal((await issue(directory, "alice", "status")).status, 200);
  }
  const throttled = await issue(directory, "alice", "status");
  assert.equal(throttled.status, 429);
  assert.ok(throttled.body.retryAfterSeconds > 0);
});

test("submission limit and strict validation prevent bulk or malformed cases", async () => {
  const { directory, storage, alice } = await setup();
  const ownCode = (await storage.get("user:alice")).guardCode;
  const self = await action(directory, "alice", alice, "submit", submission(ownCode));
  assert.equal(self.status, 400);

  const malformed = await action(directory, "alice", alice, "submit", {
    ...submission("12345678"),
  });
  assert.equal(malformed.status, 400);
  const wrongReason = await action(directory, "alice", alice, "submit", {
    ...submission("123456789", { reason: "delete_now" }),
  });
  assert.equal(wrongReason.status, 400);

  for (const code of ["111111111", "222222222", "333333333"]) {
    assert.equal((await action(directory, "alice", alice, "submit",
      submission(code))).status, 200);
  }
  const exhausted = await action(directory, "alice", alice, "submit", submission("444444444"));
  assert.equal(exhausted.status, 429);
  assert.ok(exhausted.body.retryAfterSeconds > 0);
  assert.equal((await storage.get("guard-case-submit-limit:alice")).count, 3);
});
