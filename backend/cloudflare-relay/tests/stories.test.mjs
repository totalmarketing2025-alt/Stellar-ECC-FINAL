import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";

const source = await readFile(new URL("../src/index.js", import.meta.url), "utf8");
const storyId = "7c41504f-8fa0-4c73-84e9-cb719a18f413";

function loadModerationRoom() {
  const sourceText = source
    .replace(/\bexport class RelayRoom\b/, "class RelayRoom")
    .replace(/\bexport class ModerationRoom\b/, "class ModerationRoom")
    .replace(/\bexport default\s*\{/, "const worker = {");
  const factory = new Function(
    "crypto", "console", "TextEncoder", "TextDecoder", "setTimeout", "fetch", "btoa", "atob",
    `${sourceText}\nreturn { ModerationRoom };`,
  );
  return factory(webcrypto, { log() {}, warn() {}, error() {} }, TextEncoder,
    TextDecoder, setTimeout, fetch, btoa, atob).ModerationRoom;
}

function createHarness() {
  const stories = new Map();
  const audiences = new Map();
  const reactions = new Map();
  const objects = new Map();
  const sessions = new Map([
    ["moderation-session:alice-token", { nickname: "alice", deviceId: 1, registrationId: 1, expiresAt: Date.now() + 60_000 }],
    ["moderation-session:bob-token", { nickname: "bob", deviceId: 1, registrationId: 1, expiresAt: Date.now() + 60_000 }],
    ["moderation-session:mallory-token", { nickname: "mallory", deviceId: 1, registrationId: 1, expiresAt: Date.now() + 60_000 }],
  ]);
  const sql = {
    exec(statement, ...params) {
      const sqlText = statement.replace(/\s+/g, " ").trim();
      if (sqlText.startsWith("CREATE TABLE IF NOT EXISTS ")) return { toArray: () => [], one: () => null };
      if (sqlText.startsWith("ALTER TABLE moderation_messages")) throw new Error("duplicate column name: attachment_mime_type");
      if (sqlText.startsWith("ALTER TABLE stellar_stories")) throw new Error("duplicate column name: owner_recovery_envelope");
      if (sqlText.startsWith("SELECT COUNT(*) AS count FROM stellar_stories")) {
        const count = [...stories.values()].filter((row) => row.owner === params[0] && row.expires_at > params[1]).length;
        return { one: () => ({ count }), toArray: () => [{ count }] };
      }
      if (sqlText.startsWith("INSERT INTO stellar_stories")) {
        const [id, owner, type, extension, duration, created, expires, size, recoveryEnvelope] = params;
        stories.set(id, { story_id: id, owner, media_type: type, video_extension: extension,
          duration_ms: duration, created_at: created, expires_at: expires, media_size: size,
          media_uploaded: 0, owner_recovery_envelope: recoveryEnvelope });
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("INSERT INTO stellar_story_audience")) {
        const [id, nickname, wrappedKey] = params;
        audiences.set(`${id}:${nickname}`, { story_id: id, nickname, wrapped_key: wrappedKey });
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("UPDATE stellar_stories SET media_uploaded = 1")) {
        const row = stories.get(params[0]);
        if (row?.owner === params[1]) row.media_uploaded = 1;
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("SELECT s.story_id, s.owner")) {
        const [nickname, now] = params;
        const rows = [...stories.values()].filter((row) => row.expires_at > now &&
          (row.owner === nickname || audiences.has(`${row.story_id}:${nickname}`)))
          .sort((a, b) => b.created_at - a.created_at)
          .map((row) => ({ ...row,
            owner_recovery_envelope: row.owner === nickname ? row.owner_recovery_envelope : undefined,
            wrapped_key: audiences.get(`${row.story_id}:${nickname}`)?.wrapped_key ?? null }));
        return { toArray: () => rows, one: () => rows[0] ?? null };
      }
      if (sqlText.startsWith("SELECT emoji, COUNT(*) AS count FROM stellar_story_reactions")) {
        const rows = [...reactions.values()].filter((item) => item.story_id === params[0]);
        const counts = new Map();
        for (const row of rows) counts.set(row.emoji, (counts.get(row.emoji) ?? 0) + 1);
        const result = [...counts].map(([emoji, count]) => ({ emoji, count }));
        return { toArray: () => result, one: () => result[0] ?? null };
      }
      if (sqlText.startsWith("SELECT media_size FROM stellar_stories")) {
        const [id, owner, now] = params;
        const row = stories.get(id);
        const result = row?.owner === owner && row.expires_at > now ? { media_size: row.media_size } : null;
        return { one: () => result, toArray: () => result ? [result] : [] };
      }
      if (sqlText.startsWith("SELECT story_id FROM stellar_stories WHERE story_id = ? AND owner = ? AND expires_at > ?")) {
        const [id, owner, now] = params;
        const row = stories.get(id);
        const allowed = row?.owner === owner && row.expires_at > now && row.media_uploaded === 1;
        return { one: () => allowed ? { story_id: id } : null, toArray: () => allowed ? [{ story_id: id }] : [] };
      }
      if (sqlText.startsWith("UPDATE stellar_stories SET owner_recovery_envelope = ?")) {
        const [envelope, id, owner] = params;
        const row = stories.get(id);
        if (row?.owner === owner) row.owner_recovery_envelope = envelope;
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("SELECT owner FROM stellar_stories")) {
        const [id, now] = params;
        const row = stories.get(id);
        const result = row && row.expires_at > now ? { owner: row.owner } : null;
        return { one: () => result, toArray: () => result ? [result] : [] };
      }
      if (sqlText.startsWith("SELECT story_id FROM stellar_story_audience")) {
        const row = audiences.get(`${params[0]}:${params[1]}`);
        return { one: () => row ? { story_id: row.story_id } : null, toArray: () => row ? [row] : [] };
      }
      if (sqlText.startsWith("SELECT story_id FROM stellar_stories WHERE expires_at <= ?")) {
        const rows = [...stories.values()].filter((row) => row.expires_at <= params[0])
          .map((row) => ({ story_id: row.story_id }));
        return { toArray: () => rows, one: () => rows[0] ?? null };
      }
      if (sqlText.startsWith("SELECT message_id FROM moderation_messages WHERE expires_at <= ?")) {
        return { toArray: () => [], one: () => null };
      }
      if (sqlText.startsWith("DELETE FROM moderation_messages WHERE expires_at <= ?")) {
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("INSERT INTO stellar_story_reactions")) {
        const [id, nickname, emoji, updated] = params;
        reactions.set(`${id}:${nickname}`, { story_id: id, nickname, emoji, updated_at: updated });
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("SELECT story_id FROM stellar_stories WHERE story_id = ? AND owner = ?")) {
        const row = stories.get(params[0]);
        const result = row?.owner === params[1] ? { story_id: row.story_id } : null;
        return { one: () => result, toArray: () => result ? [result] : [] };
      }
      if (sqlText.startsWith("DELETE FROM stellar_story_audience WHERE story_id = ?")) {
        for (const [key, row] of audiences) if (row.story_id === params[0]) audiences.delete(key);
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("DELETE FROM stellar_story_reactions WHERE story_id = ?")) {
        for (const [key, row] of reactions) if (row.story_id === params[0]) reactions.delete(key);
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("DELETE FROM stellar_story_audience WHERE story_id IN")) {
        const expired = new Set([...stories.values()].filter((row) => row.expires_at <= params[0])
          .map((row) => row.story_id));
        for (const [key, row] of audiences) if (expired.has(row.story_id)) audiences.delete(key);
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("DELETE FROM stellar_story_reactions WHERE story_id IN")) {
        const expired = new Set([...stories.values()].filter((row) => row.expires_at <= params[0])
          .map((row) => row.story_id));
        for (const [key, row] of reactions) if (expired.has(row.story_id)) reactions.delete(key);
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("DELETE FROM stellar_stories WHERE expires_at <= ?")) {
        for (const [id, row] of stories) if (row.expires_at <= params[0]) stories.delete(id);
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("DELETE FROM stellar_stories WHERE story_id = ?")) {
        stories.delete(params[0]);
        return { one: () => null, toArray: () => [] };
      }
      if (sqlText.startsWith("SELECT MIN(expires_at) AS next_expires_at")) {
        return { one: () => ({ next_expires_at: null }), toArray: () => [] };
      }
      throw new Error(`Unexpected SQL in Story test: ${sqlText}`);
    },
  };
  const storage = {
    sql,
    get: async (key) => sessions.get(key),
    delete: async () => {},
    getAlarm: async () => null,
    setAlarm: async () => {},
  };
  const room = new (loadModerationRoom())({ storage, waitUntil() {} }, {
    MODERATION_ATTACHMENTS: {
      put: async (key, value) => objects.set(key, new Uint8Array(value)),
      get: async (key) => objects.has(key) ? { body: objects.get(key) } : null,
      delete: async (key) => objects.delete(key),
    },
  });
  return { room, stories, audiences, reactions, objects };
}

function request(path, { method = "GET", token, body, headers = {} } = {}) {
  return new Request(`https://moderation.test${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    ...(body == null ? {} : { body }),
  });
}

function metadata(overrides = {}) {
  return {
    storyId,
    mediaType: "video",
    videoExtension: "mp4",
    durationMs: 15000,
    mediaSize: 4,
    audience: [{ nickname: "bob", wrappedKey: JSON.stringify({ type: 3, ciphertext: "AQID" }) }],
    ...overrides,
  };
}

test("Stories enforce the 15-second limit and reject invalid key envelopes", async () => {
  const { room, stories } = createHarness();
  const tooLong = await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token", body: JSON.stringify(metadata({ durationMs: 15001 })),
  }));
  assert.equal(tooLong.status, 400);
  assert.equal(stories.size, 0);
  const invalidKey = await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token",
    body: JSON.stringify(metadata({ audience: [{ nickname: "bob", wrappedKey: "not-an-envelope" }] })),
  }));
  assert.equal(invalidKey.status, 400);
});

test("Stories reject malformed owner recovery envelopes", async () => {
  const { room, stories } = createHarness();
  const response = await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token",
    body: JSON.stringify(metadata({ ownerRecoveryEnvelope: JSON.stringify({ version: 1, nonce: "bad" }) })),
  }));
  assert.equal(response.status, 400);
  assert.equal(stories.size, 0);
});

test("Stories require authentication and reject media size mismatches", async () => {
  const { room, stories } = createHarness();
  const unauthorized = await room.fetch(request("/v1/stories", {
    method: "POST", body: JSON.stringify(metadata()),
  }));
  assert.equal(unauthorized.status, 401);
  assert.equal(stories.size, 0);

  await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token", body: JSON.stringify(metadata()),
  }));
  const mismatch = await room.fetch(request(`/v1/stories/${storyId}/media`, {
    method: "POST", token: "alice-token", body: new Uint8Array([1, 2, 3]),
  }));
  assert.equal(mismatch.status, 400);
  assert.equal(stories.get(storyId).media_uploaded, 0);
});

test("Stories expose encrypted media only to audience, accept reactions, and return no viewer list", async () => {
  const { room, stories, objects } = createHarness();
  const created = await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token", body: JSON.stringify(metadata()),
  }));
  assert.equal(created.status, 201);
  const upload = await room.fetch(request(`/v1/stories/${storyId}/media`, {
    method: "POST", token: "alice-token", headers: { "Content-Type": "application/octet-stream" },
    body: new Uint8Array([1, 2, 3, 4]),
  }));
  assert.equal(upload.status, 201);
  assert.equal(objects.size, 1);

  const denied = await room.fetch(request(`/v1/stories/${storyId}/media`, { token: "mallory-token" }));
  assert.equal(denied.status, 403);
  const allowed = await room.fetch(request(`/v1/stories/${storyId}/media`, { token: "bob-token" }));
  assert.equal(allowed.status, 200);

  const reaction = await room.fetch(request(`/v1/stories/${storyId}/reactions`, {
    method: "POST", token: "bob-token", body: JSON.stringify({ emoji: "❤️" }),
  }));
  assert.equal(reaction.status, 200);
  const ownerList = await room.fetch(request("/v1/stories", { token: "alice-token" }));
  const ownerPayload = await ownerList.json();
  assert.equal(ownerPayload.stories[0].reaction_counts[0].count, 1);
  assert.equal("viewers" in ownerPayload.stories[0], false);
  assert.equal("viewer_count" in ownerPayload.stories[0], false);

  const viewerList = await room.fetch(request("/v1/stories", { token: "bob-token" }));
  const viewerPayload = await viewerList.json();
  assert.equal(viewerPayload.stories[0].wrapped_key.includes("ciphertext"), true);
  assert.deepEqual(viewerPayload.stories[0].reaction_counts, []);
  assert.equal("viewers" in viewerPayload.stories[0], false);
  assert.equal(stories.size, 1);
});

test("only the author receives the encrypted Story recovery envelope", async () => {
  const envelope = JSON.stringify({
    version: 1,
    nonce: "AAAAAAAAAAAAAAAA",
    ciphertext: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    mac: "AAAAAAAAAAAAAAAAAAAAAA==",
  });
  const { room } = createHarness();
  await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token",
    body: JSON.stringify(metadata({ ownerRecoveryEnvelope: envelope })),
  }));
  await room.fetch(request(`/v1/stories/${storyId}/media`, {
    method: "POST", token: "alice-token", body: new Uint8Array([1, 2, 3, 4]),
  }));
  const owner = await (await room.fetch(request("/v1/stories", { token: "alice-token" }))).json();
  const recipient = await (await room.fetch(request("/v1/stories", { token: "bob-token" }))).json();
  assert.equal(owner.stories[0].owner_recovery_envelope, envelope);
  assert.equal("owner_recovery_envelope" in recipient.stories[0], false);
});

test("authors can add Story recovery envelopes later, but other users cannot", async () => {
  const envelope = JSON.stringify({
    version: 1,
    nonce: "AAAAAAAAAAAAAAAA",
    ciphertext: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    mac: "AAAAAAAAAAAAAAAAAAAAAA==",
  });
  const { room } = createHarness();
  await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token", body: JSON.stringify(metadata()),
  }));
  await room.fetch(request(`/v1/stories/${storyId}/media`, {
    method: "POST", token: "alice-token", body: new Uint8Array([1, 2, 3, 4]),
  }));

  const denied = await room.fetch(request(`/v1/stories/${storyId}/recovery`, {
    method: "PUT", token: "bob-token", body: JSON.stringify({ ownerRecoveryEnvelope: envelope }),
  }));
  assert.equal(denied.status, 404);
  const saved = await room.fetch(request(`/v1/stories/${storyId}/recovery`, {
    method: "PUT", token: "alice-token", body: JSON.stringify({ ownerRecoveryEnvelope: envelope }),
  }));
  assert.equal(saved.status, 200);
  const listed = await room.fetch(request("/v1/stories", { token: "alice-token" }));
  assert.equal((await listed.json()).stories[0].owner_recovery_envelope, envelope);
});

test("Only the author can delete a Story and deletion removes media and metadata", async () => {
  const { room, stories, audiences, objects } = createHarness();
  await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token", body: JSON.stringify(metadata()),
  }));
  await room.fetch(request(`/v1/stories/${storyId}/media`, {
    method: "POST", token: "alice-token", body: new Uint8Array([1, 2, 3, 4]),
  }));

  const denied = await room.fetch(request(`/v1/stories/${storyId}`, {
    method: "DELETE", token: "bob-token",
  }));
  assert.equal(denied.status, 404);
  assert.equal(stories.size, 1);

  const deleted = await room.fetch(request(`/v1/stories/${storyId}`, {
    method: "DELETE", token: "alice-token",
  }));
  assert.equal(deleted.status, 200);
  assert.equal(stories.size, 0);
  assert.equal(audiences.size, 0);
  assert.equal(objects.size, 0);
});

test("expired Stories and their media, audience keys and reactions are removed", async () => {
  const { room, stories, audiences, reactions, objects } = createHarness();
  await room.fetch(request("/v1/stories", {
    method: "POST", token: "alice-token", body: JSON.stringify(metadata()),
  }));
  await room.fetch(request(`/v1/stories/${storyId}/media`, {
    method: "POST", token: "alice-token", body: new Uint8Array([1, 2, 3, 4]),
  }));
  await room.fetch(request(`/v1/stories/${storyId}/reactions`, {
    method: "POST", token: "bob-token", body: JSON.stringify({ emoji: "❤️" }),
  }));
  stories.get(storyId).expires_at = Date.now() - 1;

  await room.alarm();

  assert.equal(stories.size, 0);
  assert.equal(audiences.size, 0);
  assert.equal(reactions.size, 0);
  assert.equal(objects.size, 0);
});
