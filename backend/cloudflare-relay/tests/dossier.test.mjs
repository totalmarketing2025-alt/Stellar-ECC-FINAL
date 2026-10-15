import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";

const sourceUrl = new URL("../src/index.js", import.meta.url);
const originalSource = await readFile(sourceUrl, "utf8");

function loadModerationRoom() {
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
    `${source}\nreturn { ModerationRoom };`,
  );

  return factory(
    webcrypto,
    { log() {}, warn() {}, error() {} },
    TextEncoder,
    setTimeout,
    fetch,
    btoa,
    atob,
  ).ModerationRoom;
}

function createHarness() {
  const now = Date.now();

  const messages = [
    {
      message_id: "msg-1",
      sender: "alice",
      recipient: "bob",
      chat_id: "chat-1",
      created_at: now - 1000,
      expires_at: now + 60_000,
      content_type: "text",
      plaintext: "Hello Bob",
      attachment_mime_type: null,
    },
    {
      message_id: "msg-2",
      sender: "bob",
      recipient: "alice",
      chat_id: "chat-1",
      created_at: now - 2000,
      expires_at: now + 60_000,
      content_type: "image",
      plaintext: "",
      attachment_mime_type: "image/jpeg",
    },
    {
      message_id: "expired",
      sender: "alice",
      recipient: "bob",
      chat_id: "chat-1",
      created_at: now - 5000,
      expires_at: now - 1000,
      content_type: "text",
      plaintext: "Expired",
      attachment_mime_type: null,
    },
  ];

  const sessions = new Map([
    [
      "moderation-admin-session:admin-token",
      {
        role: "admin",
        username: "test-admin",
        expiresAt: now + 60_000,
      },
    ],
    [
      "moderation-admin-session:user-role-token",
      {
        role: "user",
        username: "not-admin",
        expiresAt: now + 60_000,
      },
    ],
  ]);

  const sql = {
    exec(statement, ...params) {
      const normalized = statement.replace(/\s+/g, " ").trim();

      if (/^CREATE TABLE IF NOT EXISTS /i.test(normalized) ||
          /^CREATE INDEX IF NOT EXISTS /i.test(normalized)) {
        return { toArray: () => [], one: () => null };
      }

      if (/^ALTER TABLE moderation_messages /i.test(normalized)) {
        throw new Error("duplicate column name: attachment_mime_type");
      }

      if (/^SELECT message_id, sender, recipient, chat_id, created_at,/i.test(normalized)) {
        const [cutoff, nickname1, nickname2] = params;
        const rows = messages
          .filter((m) =>
            m.expires_at > cutoff &&
            (m.sender.toLowerCase() === nickname1.toLowerCase() ||
             m.recipient.toLowerCase() === nickname2.toLowerCase()))
          .sort((a, b) => b.created_at - a.created_at)
          .slice(0, 100);

        return { toArray: () => rows, one: () => rows[0] ?? null };
      }

      if (/^SELECT COUNT\(\*\) AS messageCount,/i.test(normalized)) {
        const [cutoff, nickname1, nickname2] = params;
        const matching = messages.filter((m) =>
          m.expires_at > cutoff &&
          (m.sender.toLowerCase() === nickname1.toLowerCase() ||
           m.recipient.toLowerCase() === nickname2.toLowerCase()));

        return {
          one: () => ({
            messageCount: matching.length,
            lastMessageAt: matching.length
              ? Math.max(...matching.map((m) => m.created_at))
              : null,
          }),
          toArray: () => [],
        };
      }

      throw new Error(`Unexpected SQL in dossier test: ${normalized}`);
    },
  };

  const storage = {
    sql,
    async get(key) {
      return sessions.get(key) ?? null;
    },
    async delete(key) {
      sessions.delete(key);
    },
  };

  const env = {};
  const ctx = { storage };
  const ModerationRoom = loadModerationRoom();
  const room = new ModerationRoom(ctx, env);

  return { room };
}

function request(path, { method = "GET", token, headers = {} } = {}) {
  const requestHeaders = new Headers(headers);
  if (token) requestHeaders.set("Authorization", `Bearer ${token}`);

  return new Request(`https://relay.test${path}`, {
    method,
    headers: requestHeaders,
  });
}

test("dossier rejects unauthenticated requests", async () => {
  const { room } = createHarness();
  const response = await room.fetch(
    request("/v1/moderation/admin/users/alice/dossier"),
  );

  assert.equal(response.status, 401);
});

test("dossier rejects sessions without admin role", async () => {
  const { room } = createHarness();
  const response = await room.fetch(
    request("/v1/moderation/admin/users/alice/dossier", {
      token: "user-role-token",
    }),
  );

  assert.equal(response.status, 401);
});

test("dossier rejects invalid nicknames", async () => {
  const { room } = createHarness();
  const response = await room.fetch(
    request("/v1/moderation/admin/users/%2F/dossier", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 400);
});

test("admin dossier returns active messages in Flutter field format", async () => {
  const { room } = createHarness();
  const response = await room.fetch(
    request("/v1/moderation/admin/users/alice/dossier", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");

  const data = await response.json();
  assert.equal(data.nickname, "alice");
  assert.equal(data.stats.messageCount, 2);
  assert.equal(typeof data.stats.lastMessageAt, "number");
  assert.equal(data.messages.length, 2);
  assert.equal(data.messagesLimit, 100);

  assert.equal(data.messages[0].id, "msg-1");
  assert.equal(data.messages[0].text, "Hello Bob");
  assert.equal(data.messages[0].createdAt > 0, true);
  assert.equal(data.messages[0].expiresAt > Date.now(), true);
  assert.equal(data.messages[0].chatId, "chat-1");
  assert.equal(data.messages[0].contentType, "text");
  assert.equal(data.messages[0].attachmentMimeType, null);

  assert.equal(data.messages[1].id, "msg-2");
  assert.equal(data.messages[1].attachmentMimeType, "image/jpeg");
  assert.equal(data.messages.some((m) => m.id === "expired"), false);
});

test("dossier room does not expose POST as a successful request", async () => {
  const { room } = createHarness();
  const response = await room.fetch(
    request("/v1/moderation/admin/users/alice/dossier", {
      method: "POST",
      token: "admin-token",
    }),
  );

  assert.notEqual(response.status, 200);
});
