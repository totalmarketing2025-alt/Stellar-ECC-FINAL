import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { webcrypto } from "node:crypto";

// Load the same Worker source with controllable entropy. This exercises real
// routes without leaking production secrets or requiring Cloudflare access.
const source = fs.readFileSync(
  new URL("../src/index.js", import.meta.url), "utf8",
).replace(/\nexport default[\s\S]*$/, "")
  .replace(/export class DirectoryStore/g, "class DirectoryStore");

function loadDirectory(samples = []) {
  const crypto = {
    subtle: webcrypto.subtle,
    getRandomValues(bytes) {
      if (bytes instanceof Uint32Array && samples.length) {
        bytes[0] = samples.shift();
        return bytes;
      }
      return webcrypto.getRandomValues(bytes);
    },
  };

  return new Function(
    "crypto", "btoa", "atob", "TextEncoder",
    `${source}\nreturn { DirectoryStore, newGuardCode };`,
  )(crypto, btoa, atob, TextEncoder);
}

class MemoryStorage {
  constructor() {
    this.records = new Map();
    this.pending = Promise.resolve();
  }

  async get(key) {
    return this.records.has(key)
      ? structuredClone(this.records.get(key))
      : undefined;
  }

  async put(key, value) {
    this.records.set(key, structuredClone(value));
  }

  async delete(key) {
    return this.records.delete(key);
  }

  async list({ prefix = "", startAfter, limit = Infinity } = {}) {
    const keys = [...this.records.keys()]
      .filter((key) => key.startsWith(prefix) &&
        (startAfter === undefined || key > startAfter))
      .sort()
      .slice(0, limit);
    return new Map(await Promise.all(keys.map(async (key) => [
      key, await this.get(key),
    ])));
  }

  async transaction(callback) {
    let release;
    const waitForThisTransaction = this.pending;
    this.pending = new Promise((resolve) => { release = resolve; });
    await waitForThisTransaction;
    try {
      return await callback(this);
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

function leToBigInt(bytes) {
  return bytes.reduceRight((result, byte) => (result << 8n) | BigInt(byte), 0n);
}

function bigIntToLE(value, length) {
  const result = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    result[i] = Number(value & 255n);
    value >>= 8n;
  }
  return result;
}

async function newSignalIdentity() {
  // Signal's encoded identity uses Montgomery u; signed GUARD proofs use
  // XEdDSA's Edwards public-key sign bit in the signature's final byte.
  const keyPair = await webcrypto.subtle.generateKey(
    { name: "Ed25519" }, true, ["sign", "verify"],
  );
  const ed = new Uint8Array(
    await webcrypto.subtle.exportKey("raw", keyPair.publicKey),
  );
  const signBit = ed[31] >>> 7;
  ed[31] &= 127;
  const y = leToBigInt(ed);
  const u = mod((1n + y) * modPow(mod(1n - y), P - 2n));
  const identityKey = btoa(String.fromCharCode(5, ...bigIntToLE(u, 32)));

  return {
    identityKey,
    async sign(message) {
      const bytes = new Uint8Array(await webcrypto.subtle.sign(
        { name: "Ed25519" }, keyPair.privateKey,
        new TextEncoder().encode(message),
      ));
      bytes[63] |= signBit << 7;
      return btoa(String.fromCharCode(...bytes));
    },
  };
}

function bundle(identityKey) {
  return {
    deviceId: 1,
    registrationId: 101,
    identityKey,
    signedPreKey: {
      keyId: 2,
      publicKey: identityKey,
      signature: btoa(String.fromCharCode(...new Uint8Array(64))),
    },
    preKey: { keyId: 3, publicKey: identityKey },
  };
}

async function request(directory, route, body, secret) {
  const response = await directory.fetch(new Request(
    `https://directory.test${route}`,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(secret ? { authorization: `Bearer ${secret}` } : {}),
      },
      body: JSON.stringify(body),
    },
  ));
  return { status: response.status, body: await response.json() };
}

async function register(directory, nickname, identity) {
  return request(directory, "/v1/register", {
    nickname,
    bundle: bundle(identity.identityKey),
  });
}

async function challenge(directory, nickname) {
  return request(directory, "/v1/guard/code/challenge", {
    nickname, deviceId: 1, registrationId: 101,
  });
}

async function prove(directory, nickname, identity, nonce, override = {}) {
  const message = JSON.stringify([
    "stellar-guard-identity-v1", nickname, 1, 101, nonce,
  ]);
  return request(directory, "/v1/guard/code", {
    nickname, deviceId: 1, registrationId: 101,
    challenge: nonce, signature: await identity.sign(message), ...override,
  });
}

test("registration atomically reserves nine-digit string IDs and retries collisions", async () => {
  const { DirectoryStore } = loadDirectory([17, 17, 22, 0xffffffff, 24]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {});
  const identity = await newSignalIdentity();

  assert.deepEqual(await register(directory, "alice", identity), {
    status: 201, body: { ok: true, nickname: "alice" },
  });
  assert.equal((await register(directory, "alice", identity)).status, 409);
  assert.equal((await register(directory, "bob", identity)).status, 201);
  assert.equal((await register(directory, "carol", identity)).status, 201);

  assert.equal((await storage.get("user:alice")).guardCode, "000000017");
  assert.equal((await storage.get("user:bob")).guardCode, "000000022");
  assert.equal((await storage.get("user:carol")).guardCode, "000000024");
  assert.equal(await storage.get("guard-code:000000017"), "alice");
  assert.equal(await storage.get("guard-code:000000022"), "bob");
  assert.equal(await storage.get("guard-code:000000024"), "carol");

  const publicUser = await directory.fetch(new Request(
    "https://directory.test/v1/users/alice",
  ));
  assert.equal(publicUser.status, 200);
  assert.equal("guardCode" in await publicUser.json(), false);
  assert.equal((await directory.fetch(new Request(
    "https://directory.test/v1/guard/code/000000017",
  ))).status, 404);

  const usersResponse = await directory.fetch(new Request(
    "https://directory.test/v1/users",
  ));
  assert.equal(JSON.stringify(await usersResponse.json()).includes("000000017"), false);
});

test("own code requires an XEdDSA signature and one-time challenge", async () => {
  const { DirectoryStore } = loadDirectory([9]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {});
  const alice = await newSignalIdentity();
  const attacker = await newSignalIdentity();
  await register(directory, "alice", alice);

  const issued = await challenge(directory, "alice");
  assert.equal(issued.status, 200);
  assert.ok(issued.body.challenge.length >= 32);
  assert.equal("guardCode" in issued.body, false);

  const forged = await prove(directory, "alice", attacker, issued.body.challenge);
  assert.equal(forged.status, 401);
  assert.equal((await prove(directory, "alice", alice, issued.body.challenge)).status, 401);

  const second = await challenge(directory, "alice");
  const valid = await prove(directory, "alice", alice, second.body.challenge);
  assert.deepEqual(valid, { status: 200, body: { guardCode: "000000009" } });
  assert.equal((await prove(directory, "alice", alice, second.body.challenge)).status, 401);

  const third = await challenge(directory, "alice");
  const repeat = await prove(directory, "alice", alice, third.body.challenge);
  assert.equal(repeat.body.guardCode, "000000009");
  assert.equal((await storage.get("user:alice")).guardCode, "000000009");
});

test("GUARD challenges are limited per account and bound to the registered device", async () => {
  const { DirectoryStore } = loadDirectory();
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {});
  const identity = await newSignalIdentity();
  await register(directory, "alice", identity);

  assert.equal((await request(directory, "/v1/guard/code/challenge", {
    nickname: "alice", deviceId: 2, registrationId: 101,
  })).status, 404);
  assert.equal((await request(directory, "/v1/guard/code/challenge", {
    nickname: "alice", deviceId: 1, registrationId: 1.5,
  })).status, 400);

  for (let i = 0; i < 6; i++) {
    assert.equal((await challenge(directory, "alice")).status, 200);
  }
  const throttled = await challenge(directory, "alice");
  assert.equal(throttled.status, 429);
  assert.ok(throttled.body.retryAfterSeconds > 0);

  await storage.put("guard-challenge-limit:alice", {
    count: 6, expiresAt: Date.now() - 1,
  });
  assert.equal((await challenge(directory, "alice")).status, 200);
});

test("legacy owners can claim a code without an operator migration", async () => {
  const { DirectoryStore } = loadDirectory([101]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {});
  const identity = await newSignalIdentity();
  await storage.put("user:alice", {
    nickname: "alice", bundle: bundle(identity.identityKey),
  });

  const firstChallenge = await challenge(directory, "alice");
  assert.equal(firstChallenge.status, 200);
  assert.equal((await storage.get("user:alice")).guardCode, undefined);

  const proof = await prove(directory, "alice", identity, firstChallenge.body.challenge);
  assert.deepEqual(proof, {
    status: 200, body: { guardCode: "000000101" },
  });
  assert.equal(await storage.get("guard-code:000000101"), "alice");

  const staleChallenge = await challenge(directory, "alice");
  const replacedChallenge = await challenge(directory, "alice");
  assert.equal((await prove(directory, "alice", identity,
    staleChallenge.body.challenge)).status, 401);
  assert.equal((await prove(directory, "alice", identity,
    replacedChallenge.body.challenge)).status, 200);
});

test("expired challenge never allocates or reveals a legacy account code", async () => {
  const { DirectoryStore } = loadDirectory([71]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {});
  const identity = await newSignalIdentity();
  await storage.put("user:alice", {
    nickname: "alice", bundle: bundle(identity.identityKey),
  });
  const issued = await challenge(directory, "alice");
  await storage.put("guard-challenge:alice:1:101", {
    challenge: issued.body.challenge, expiresAt: Date.now() - 1,
  });

  const expired = await prove(directory, "alice", identity, issued.body.challenge);
  assert.equal(expired.status, 401);
  assert.equal((await storage.get("user:alice")).guardCode, undefined);
  assert.equal(await storage.get("guard-code:000000071"), undefined);
});

test("a concurrently registered second user cannot claim the first code", async () => {
  const { DirectoryStore } = loadDirectory([41, 41, 42]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {});
  const identity = await newSignalIdentity();

  const [first, second] = await Promise.all([
    register(directory, "alice", identity),
    register(directory, "bob", identity),
  ]);
  assert.equal(first.status, 201);
  assert.equal(second.status, 201);
  assert.notEqual(
    (await storage.get("user:alice")).guardCode,
    (await storage.get("user:bob")).guardCode,
  );
  assert.equal(await storage.get("guard-code:000000041"), "alice");
  assert.equal(await storage.get("guard-code:000000042"), "bob");
});

test("legacy migration requires separate secret, pages safely, and is idempotent", async () => {
  const { DirectoryStore } = loadDirectory([1, 2, 3, 4]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {
    GUARD_MIGRATION_SECRET: "operator-only-secret",
  });
  const identity = await newSignalIdentity();

  for (const nickname of ["alice", "bob", "carol", "dave"]) {
    await storage.put(`user:${nickname}`, {
      nickname, bundle: bundle(identity.identityKey),
    });
  }

  const path = "/v1/internal/guard-codes/migrate";
  assert.equal((await request(directory, path, { limit: 2 })).status, 401);
  assert.equal((await request(directory, path, { limit: 51 }, "operator-only-secret")).status, 400);
  assert.equal((await request(directory, path, { after: "../x" }, "operator-only-secret")).status, 400);

  const first = await request(directory, path, { limit: 2 }, "operator-only-secret");
  assert.deepEqual(first, {
    status: 200,
    body: {
      processed: 2, created: 2, alreadyAssigned: 0,
      nextCursor: "bob", done: false,
    },
  });

  const second = await request(directory, path, {
    after: first.body.nextCursor, limit: 2,
  }, "operator-only-secret");
  assert.equal(second.status, 200);
  assert.equal(second.body.processed, 2);
  assert.equal(second.body.created, 2);
  assert.equal(second.body.nextCursor, null);
  assert.equal(second.body.done, true);

  const before = (await storage.get("user:alice")).guardCode;
  const again = await request(directory, path, { limit: 4 }, "operator-only-secret");
  assert.equal(again.body.created, 0);
  assert.equal(again.body.alreadyAssigned, 4);
  assert.equal((await storage.get("user:alice")).guardCode, before);
  assert.equal(await storage.get(`guard-code:${before}`), "alice");

  const ownChallenge = await challenge(directory, "alice");
  const ownCode = await prove(directory, "alice", identity, ownChallenge.body.challenge);
  assert.equal(ownCode.body.guardCode, before);
});

test("conflicting legacy codes fail closed, never reassign an identity", async () => {
  const { DirectoryStore } = loadDirectory([87]);
  const storage = new MemoryStorage();
  const directory = new DirectoryStore({ storage }, {
    GUARD_MIGRATION_SECRET: "operator-only-secret",
  });
  const identity = await newSignalIdentity();
  await storage.put("user:alice", {
    nickname: "alice", bundle: bundle(identity.identityKey),
    guardCode: "000000012",
  });
  await storage.put("guard-code:000000012", "bob");

  await assert.rejects(
    () => request(directory, "/v1/internal/guard-codes/migrate", {
      limit: 1,
    }, "operator-only-secret"),
    /conflicting owner/,
  );
  assert.equal((await storage.get("user:alice")).guardCode, "000000012");
  assert.equal(await storage.get("guard-code:000000012"), "bob");
});

test("migration endpoint is disabled when its secret is not configured", async () => {
  const { DirectoryStore } = loadDirectory();
  const directory = new DirectoryStore({ storage: new MemoryStorage() }, {});
  const response = await request(directory, "/v1/internal/guard-codes/migrate", {
    limit: 1,
  }, "anything");
  assert.equal(response.status, 401);
});
