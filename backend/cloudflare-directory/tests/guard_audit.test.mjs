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

const reviewSecret = "guard-review-only-key-longer-than-32-characters";
const migrationSecret = "another-migration-key-longer-than-32-characters";

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
    const keys = [...this.items.keys()].filter((key) =>
      key.startsWith(prefix) && (startAfter == null || key > startAfter))
      .sort().slice(0, limit);
    return new Map(await Promise.all(keys.map(async key => [key, await this.get(key)])));
  }
  async transaction(fn) {
    let release;
    const before = this.lock;
    this.lock = new Promise(resolve => { release = resolve; });
    await before;
    try { return await fn(this); } finally { release(); }
  }
}

const P = (1n << 255n) - 19n;
function mod(n) { return ((n % P) + P) % P; }
function pow(base, exp) {
  let result = 1n;
  for (; exp > 0n; exp >>= 1n) {
    if (exp & 1n) result = mod(result * base);
    base = mod(base * base);
  }
  return result;
}
function fromLE(bytes) {
  return bytes.reduceRight((n, byte) => (n << 8n) | BigInt(byte), 0n);
}
function toLE(value, size) {
  const bytes = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
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
  const y = fromLE(ed);
  const u = mod((1n + y) * pow(mod(1n - y), P - 2n));
  const encoded = btoa(String.fromCharCode(5, ...toLE(u, 32)));
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
    deviceId: 1, registrationId: 101, identityKey,
    signedPreKey: {
      keyId: 2, publicKey: identityKey,
      signature: btoa(String.fromCharCode(...new Uint8Array(64))),
    },
    preKey: { keyId: 3, publicKey: identityKey },
  };
}

async function http(directory, method, path, body, token) {
  const res = await directory.fetch(new Request(`https://directory.test${path}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }));
  return { status: res.status, body: await res.json() };
}

async function setup(overrides = {}) {
  const storage = new Storage();
  const directory = new DirectoryStore({ storage }, {
    GUARD_REVIEW_SECRET: reviewSecret,
    GUARD_MIGRATION_SECRET: migrationSecret,
    ...overrides,
  });
  const alice = await identity();
  const bob = await identity();
  for (const [nickname, user] of [["alice", alice], ["bob", bob]]) {
    assert.equal((await http(directory, "POST", "/v1/register", {
      nickname, bundle: bundle(user.encoded),
    })).status, 201);
  }
  return { directory, storage, alice, bob };
}

async function signedAction(directory, requester, identityKey, purpose, caseId = "", form = {}) {
  const issued = await http(directory, "POST", "/v1/guard/cases/challenge", {
    nickname: requester, deviceId: 1, registrationId: 101, purpose,
  });
  assert.equal(issued.status, 200);
  const challenge = issued.body.challenge;
  const fields = {
    nickname: requester,
    deviceId: 1,
    registrationId: 101,
    challenge,
    ...form,
  };
  const message = JSON.stringify([
    "stellar-guard-case-v1", purpose, requester, 1, 101, challenge, caseId,
    purpose === "submit" ? fields.targetCode : "",
    purpose === "submit" ? fields.reason : "",
    purpose === "submit" ? fields.details : "",
    purpose === "submit" ? fields.idempotencyKey : "",
  ]);
  const path = purpose === "submit"
    ? "/v1/guard/cases"
    : `/v1/guard/cases/${caseId}/${purpose}`;
  return http(directory, "POST", path, {
    ...fields, signature: await identityKey.sign(message),
  });
}

async function submit(directory, storage, alice, code) {
  const targetCode = code || (await storage.get("user:bob")).guardCode;
  return signedAction(directory, "alice", alice, "submit", "", {
    targetCode,
    reason: "harassment",
    details: "Persist a proper Guard case and its protected audit history.",
    idempotencyKey: randomUUID(),
  });
}

async function read(directory, path, secret = reviewSecret) {
  return http(directory, "GET", path, undefined, secret);
}

test("submission/cancellation append an ordered, hash-linked, verified audit", async () => {
  const { directory, storage, alice } = await setup();
  const created = await submit(directory, storage, alice);
  assert.equal(created.status, 200);
  const id = created.body.caseId;

  const first = await read(directory, `/v1/internal/guard-cases/${id}`);
  assert.equal(first.status, 200);
  assert.equal(first.body.auditStatus, "verified");
  assert.equal(first.body.events.length, 1);
  assert.equal(first.body.events[0].type, "case_submitted");
  assert.equal(first.body.events[0].sequence, 1);
  assert.equal(first.body.events[0].previousHash, "0".repeat(64));
  assert.equal(first.body.case.auditHeadHash, first.body.events[0].hash);
  assert.match(first.body.events[0].hash, /^[a-f0-9]{64}$/);

  assert.equal((await signedAction(directory, "alice", alice,
    "cancel", id)).status, 200);
  const afterCancel = await read(directory, `/v1/internal/guard-cases/${id}`);
  assert.equal(afterCancel.status, 200);
  assert.equal(afterCancel.body.auditStatus, "verified");
  assert.equal(afterCancel.body.events.length, 2);
  assert.equal(afterCancel.body.events[1].type, "case_cancelled");
  assert.equal(afterCancel.body.events[1].fromStatus, "pending_review");
  assert.equal(afterCancel.body.events[1].toStatus, "cancelled");
  assert.equal(afterCancel.body.events[1].previousHash, first.body.events[0].hash);
  assert.equal(afterCancel.body.case.auditHeadHash, afterCancel.body.events[1].hash);

  await signedAction(directory, "alice", alice, "cancel", id);
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`)).body.events.length, 2);
});

test("a tampered case or event fails closed for both requester and reviewer", async () => {
  const { directory, storage, alice } = await setup();
  const created = await submit(directory, storage, alice);
  const id = created.body.caseId;

  const record = await storage.get(`guard-case:${id}`);
  record.details = "Altered evidence must be detected before further action.";
  await storage.put(`guard-case:${id}`, record);
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`)).status, 409);
  assert.equal((await signedAction(directory,
    "alice", alice, "cancel", id)).status, 409);
  assert.equal((await storage.get(`guard-case:${id}`)).status, "pending_review");

  // Restore the case and corrupt its append-only event instead.
  await storage.put(`guard-case:${id}`, {
    ...record, details: "Persist a proper Guard case and its protected audit history.",
  });
  const key = `guard-case-audit:${id}:000001`;
  const event = await storage.get(key);
  event.type = "forged_approval";
  await storage.put(key, event);
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`)).status, 409);
  assert.equal((await read(directory,
    "/v1/internal/guard-cases")).status, 409);
});

test("missing or extra events and unauthorized status edits are detected", async () => {
  const { directory, storage, alice } = await setup();
  const created = await submit(directory, storage, alice);
  const id = created.body.caseId;
  const key = `guard-case-audit:${id}:000001`;
  const original = await storage.get(key);

  await storage.delete(key);
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`)).status, 409);
  await storage.put(key, original);

  const record = await storage.get(`guard-case:${id}`);
  record.status = "approved";
  await storage.put(`guard-case:${id}`, record);
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`)).status, 409);
  record.status = "pending_review";
  await storage.put(`guard-case:${id}`, record);

  await storage.put(`guard-case-audit:${id}:000002`, {
    ...original, sequence: 2,
  });
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`)).status, 409);
});

test("internal review is read-only, fail-closed, and exposes minimal list fields", async () => {
  const { directory, storage, alice } = await setup();
  const created = await submit(directory, storage, alice);
  const id = created.body.caseId;

  assert.equal((await read(directory, "/v1/internal/guard-cases", null)).status, 401);
  assert.equal((await read(directory,
    `/v1/internal/guard-cases/${id}`, "wrong-secret")).status, 401);

  const listing = await read(directory, "/v1/internal/guard-cases?limit=1");
  assert.equal(listing.status, 200);
  assert.equal(listing.body.cases.length, 1);
  assert.equal(listing.body.cases[0].auditStatus, "verified");
  assert.equal("details" in listing.body.cases[0], false);
  assert.equal("targetCode" in listing.body.cases[0], false);
  assert.equal(listing.body.done, true);

  assert.equal((await read(directory,
    "/v1/internal/guard-cases?limit=51")).status, 400);
  assert.equal((await read(directory,
    "/v1/internal/guard-cases?after=not-a-uuid")).status, 400);
  assert.equal((await directory.fetch(new Request(
    `https://directory.test/v1/internal/guard-cases/${id}/approve`,
    { method: "POST", headers: { authorization: `Bearer ${reviewSecret}` } },
  ))).status, 404);
});

test("legacy case backfill is explicit, resumable and idempotent", async () => {
  const { directory, storage, alice } = await setup();
  const legacyId = randomUUID();
  const legacy = {
    caseId: legacyId,
    requester: "alice",
    targetCode: "987654321",
    targetNickname: null,
    reason: "scam",
    details: "Legacy data that existed before audit support was added.",
    status: "pending_review",
    createdAt: Date.now() - 1000,
    updatedAt: Date.now() - 1000,
  };
  await storage.put(`guard-case:${legacyId}`, legacy);

  const before = await read(directory, `/v1/internal/guard-cases/${legacyId}`);
  assert.equal(before.status, 200);
  assert.equal(before.body.auditStatus, "legacy");
  assert.deepEqual(before.body.events, []);

  const backfill = "/v1/internal/guard-cases/backfill-audit";
  const denied = await http(directory, "POST", backfill, { limit: 1 });
  assert.equal(denied.status, 401);
  const invalid = await http(directory, "POST", backfill, { limit: 100 }, reviewSecret);
  assert.equal(invalid.status, 400);

  const migrated = await http(directory, "POST", backfill, {
    limit: 1,
  }, reviewSecret);
  assert.equal(migrated.status, 200);
  assert.equal(migrated.body.migrated, 1);

  const verified = await read(directory, `/v1/internal/guard-cases/${legacyId}`);
  assert.equal(verified.body.auditStatus, "verified");
  assert.equal(verified.body.events.length, 1);
  assert.equal(verified.body.events[0].type, "legacy_imported");
  assert.equal(verified.body.events[0].at >= legacy.createdAt, true);

  const repeated = await http(directory, "POST", backfill, {
    limit: 1,
  }, reviewSecret);
  assert.equal(repeated.body.migrated, 0);

  const cancelled = await signedAction(directory, "alice", alice, "cancel", legacyId);
  assert.equal(cancelled.status, 200);
  const last = await read(directory, `/v1/internal/guard-cases/${legacyId}`);
  assert.equal(last.body.events.length, 2);
  assert.equal(last.body.events[1].type, "case_cancelled");
});

test("backfill stops on a broken preexisting audit instead of rewriting it", async () => {
  const { directory, storage, alice } = await setup();
  const created = await submit(directory, storage, alice);
  const id = created.body.caseId;
  await storage.delete(`guard-case-audit:${id}:000001`);

  const result = await http(directory, "POST",
    "/v1/internal/guard-cases/backfill-audit", { limit: 1 }, reviewSecret);
  assert.equal(result.status, 409);
  assert.equal(result.body.migrated, 0);
  assert.equal(await storage.get(`guard-case-audit:${id}:000001`), undefined);
});

test("review secrets must be distinct, configured and sufficiently long", async () => {
  for (const env of [
    { GUARD_REVIEW_SECRET: "" },
    { GUARD_REVIEW_SECRET: "short" },
    { GUARD_REVIEW_SECRET: "same-as-relay-and-longer-than-32-characters",
      RELAY_SHARED_SECRET: "same-as-relay-and-longer-than-32-characters" },
    { GUARD_REVIEW_SECRET: migrationSecret },
  ]) {
    const { directory } = await setup(env);
    const result = await read(directory, "/v1/internal/guard-cases",
      env.GUARD_REVIEW_SECRET || reviewSecret);
    assert.equal(result.status, 401);
  }
});

test("review listing paginates without disclosing case details", async () => {
  const { directory, storage, alice } = await setup();
  for (const code of ["111111111", "222222222", "333333333"]) {
    assert.equal((await submit(directory, storage, alice, code)).status, 200);
  }

  let after = null;
  const ids = new Set();
  do {
    const route = `/v1/internal/guard-cases?limit=1${after ? `&after=${after}` : ""}`;
    const listing = await read(directory, route);
    assert.equal(listing.status, 200);
    listing.body.cases.forEach(c => ids.add(c.caseId));
    after = listing.body.nextCursor;
  } while (after);
  assert.equal(ids.size, 3);
});
