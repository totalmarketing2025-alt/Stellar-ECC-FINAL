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

  const groups = [
    {
      group_id: "group-a",
      group_name: "Alpha",
      created_by: "alice",
      created_at: now - 5000,
      updated_at: now - 4000,
    },
    {
      group_id: "group-b",
      group_name: "Beta",
      created_by: "bob",
      created_at: now - 4000,
      updated_at: now - 3000,
    },
    {
      group_id: "group-c",
      group_name: "Gamma",
      created_by: "alice",
      created_at: now - 3000,
      updated_at: now - 2000,
    },
  ];

  const messages = [
    {
      message_id: "a-1",
      sender: "alice",
      recipient: "group:group-a",
      chat_id: "group-a",
      created_at: now - 1000,
      expires_at: now + 60_000,
      content_type: "text",
      plaintext: "Hello group A",
      attachment_mime_type: null,
    },
    {
      message_id: "a-2",
      sender: "bob",
      recipient: "group:group-a",
      chat_id: "group-a",
      created_at: now - 2000,
      expires_at: now + 60_000,
      content_type: "image",
      plaintext: "",
      attachment_mime_type: "image/jpeg",
    },
    {
      message_id: "b-1",
      sender: "bob",
      recipient: "group:group-b",
      chat_id: "group-b",
      created_at: now - 3000,
      expires_at: now + 60_000,
      content_type: "text",
      plaintext: "Hello group B",
      attachment_mime_type: null,
    },
    {
      message_id: "expired",
      sender: "alice",
      recipient: "group:group-a",
      chat_id: "group-a",
      created_at: now - 5000,
      expires_at: now - 1000,
      content_type: "text",
      plaintext: "Expired message",
      attachment_mime_type: null,
    },
    {
      message_id: "legacy-1",
      sender: "charlie",
      recipient: "group:legacy-group",
      chat_id: "legacy-group",
      created_at: now - 500,
      expires_at: now + 60_000,
      content_type: "text",
      plaintext: "Legacy group message",
      attachment_mime_type: null,
    },
  ];

  const sessions = new Map([
    [
      "moderation-session:alice-token",
      {
        nickname: "alice",
        deviceId: 1,
        registrationId: 101,
        expiresAt: now + 60_000,
      },
    ],
    [
      "moderation-session:bob-token",
      {
        nickname: "bob",
        deviceId: 2,
        registrationId: 202,
        expiresAt: now + 60_000,
      },
    ],
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

      if (
        /^CREATE TABLE IF NOT EXISTS /i.test(normalized) ||
        /^CREATE INDEX IF NOT EXISTS /i.test(normalized)
      ) {
        return { toArray: () => [], one: () => null };
      }

      if (/^ALTER TABLE /i.test(normalized)) {
        throw new Error("duplicate column name: attachment_mime_type");
      }

      if (/^INSERT OR IGNORE INTO moderation_groups/i.test(normalized)) {
        const [groupId, groupName, creator, createdAt, updatedAt] = params;

        if (!groups.some((g) => g.group_id === groupId)) {
          groups.push({
            group_id: groupId,
            group_name: groupName,
            created_by: creator,
            created_at: createdAt,
            updated_at: updatedAt,
          });
        }

        return { toArray: () => [], one: () => null };
      }

      if (
        /^SELECT group_id, group_name, created_by, created_at, updated_at FROM moderation_groups WHERE group_id = \?/i
          .test(normalized)
      ) {
        const row = groups.find((g) => g.group_id === params[0]);

        return {
          toArray: () => row ? [{ ...row }] : [],
          one: () => row ? { ...row } : null,
        };
      }

      if (/^UPDATE moderation_groups SET group_name = \?, updated_at = \? WHERE group_id = \? AND lower\(created_by\) = lower\(\?\)/i.test(normalized)) {
        const [name, updatedAt, groupId, creator] = params;
        const row = groups.find((g) =>
          g.group_id === groupId &&
          g.created_by.toLowerCase() === creator.toLowerCase()
        );

        if (row) {
          row.group_name = name;
          row.updated_at = updatedAt;
        }

        return { toArray: () => [], one: () => null };
      }

      if (
        /^SELECT group_id, group_name, created_by, created_at, updated_at FROM moderation_groups ORDER BY updated_at DESC/i
          .test(normalized)
      ) {
        const rows = [...groups].sort(
          (a, b) => b.updated_at - a.updated_at,
        );

        return {
          toArray: () => rows.map((r) => ({ ...r })),
          one: () => rows[0] ? { ...rows[0] } : null,
        };
      }

      if (/^SELECT DISTINCT substr\(recipient, 7\) AS group_id FROM moderation_messages/i.test(normalized)) {
        const [cutoff] = params;
        const ids = [...new Set(
          messages
            .filter((m) =>
              m.expires_at > cutoff &&
              m.recipient.startsWith("group:") &&
              m.recipient.length > 6
            )
            .map((m) => m.recipient.slice(6)),
        )]
          .sort()
          .slice(0, 500)
          .map((group_id) => ({ group_id }));

        return {
          toArray: () => ids,
          one: () => ids[0] ?? null,
        };
      }

      if (/^SELECT COUNT\(\*\) AS message_count, MAX\(created_at\) AS last_message_at FROM moderation_messages/i.test(normalized)) {
        const [cutoff, groupId, recipient] = params;
        const matching = messages.filter((m) =>
          m.expires_at > cutoff &&
          (m.chat_id === groupId || m.recipient === recipient)
        );

        return {
          one: () => ({
            message_count: matching.length,
            last_message_at: matching.length
              ? Math.max(...matching.map((m) => m.created_at))
              : null,
          }),
          toArray: () => [],
        };
      }

      if (/^SELECT message_id, sender, recipient, chat_id, created_at,/i.test(normalized)) {
        const [cutoff, groupId, recipient, limit, offset] = params;
        const rows = messages
          .filter((m) =>
            m.expires_at > cutoff &&
            (m.chat_id === groupId || m.recipient === recipient)
          )
          .sort((a, b) => b.created_at - a.created_at)
          .slice(offset, offset + limit);

        return {
          toArray: () => rows.map((m) => ({ ...m })),
          one: () => rows[0] ? { ...rows[0] } : null,
        };
      }

      throw new Error(`Unexpected SQL in group-registry test: ${normalized}`);
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

  const ModerationRoom = loadModerationRoom();
  const room = new ModerationRoom({ storage }, {});

  return { room, groups, messages };
}

function request(
  path,
  { method = "GET", token, headers = {}, body } = {},
) {
  const requestHeaders = new Headers(headers);

  if (token) {
    requestHeaders.set("Authorization", `Bearer ${token}`);
  }

  if (body !== undefined) {
    requestHeaders.set("Content-Type", "application/json");
  }

  return new Request(`https://relay.test${path}`, {
    method,
    headers: requestHeaders,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
}

test("group registration rejects unauthenticated requests", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      body: { groupId: "group_123e4567-e89b-42d3-a456-426614174000", groupName: "New Group" },
    }),
  );

  assert.equal(response.status, 401);
});

test("group registration validates required fields", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      token: "alice-token",
      body: { groupId: "", groupName: "New Group" },
    }),
  );

  assert.equal(response.status, 400);
});

test("group registration rejects IDs outside the group_UUID format", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      token: "alice-token",
      body: { groupId: "not-a-group-uuid", groupName: "Invalid ID" },
    }),
  );

  assert.equal(response.status, 400);
});

test("creator can register and rename a group", async () => {
  const { room, groups } = createHarness();

  const first = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      token: "alice-token",
      body: { groupId: "group_123e4567-e89b-42d3-a456-426614174000", groupName: "First Name" },
    }),
  );

  assert.equal(first.status, 200);

  const firstData = await first.json();
  assert.equal(firstData.ok, true);
  assert.equal(firstData.group.group_id, "group_123e4567-e89b-42d3-a456-426614174000");
  assert.equal(firstData.group.group_name, "First Name");
  assert.equal(firstData.group.created_by, "alice");

  const second = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      token: "alice-token",
      body: { groupId: "group_123e4567-e89b-42d3-a456-426614174000", groupName: "Updated Name" },
    }),
  );

  assert.equal(second.status, 200);

  const secondData = await second.json();
  assert.equal(secondData.group.group_name, "Updated Name");
  assert.equal(
    groups.filter((g) => g.group_id === "group_123e4567-e89b-42d3-a456-426614174000").length,
    1,
  );
});

test("another user cannot take ownership of a registered group", async () => {
  const { room } = createHarness();

  const first = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      token: "alice-token",
      body: { groupId: "group_123e4567-e89b-42d3-a456-426614174000", groupName: "Original Name" },
    }),
  );
  assert.equal(first.status, 200);

  const response = await room.fetch(
    request("/v1/moderation/groups/register", {
      method: "POST",
      token: "bob-token",
      body: { groupId: "group_123e4567-e89b-42d3-a456-426614174000", groupName: "Hijacked Name" },
    }),
  );

  assert.equal(response.status, 409);

  const data = await response.json();
  assert.match(data.error, /another creator/i);
});

test("ordinary user cannot list admin groups", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups", {
      token: "user-role-token",
    }),
  );

  assert.equal(response.status, 401);
});

test("admin group list includes registered and discovered groups", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups?limit=100&offset=0", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 200);

  const data = await response.json();
  assert.ok(Array.isArray(data.groups));
  assert.equal(data.total, 4);

  const registered = data.groups.find((g) => g.group_id === "group-a");
  assert.ok(registered);
  assert.equal(registered.group_name, "Alpha");
  assert.equal(registered.created_by, "alice");
  assert.equal(registered.registered, true);
  assert.equal(registered.message_count, 2);

  const discovered = data.groups.find((g) => g.group_id === "legacy-group");
  assert.ok(discovered);
  assert.equal(discovered.registered, false);
  assert.equal(discovered.created_by, "Unknown creator");
});

test("admin group list validates pagination", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups?limit=0", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 400);
});

test("admin group list applies limit and offset", async () => {
  const { room } = createHarness();

  const fullResponse = await room.fetch(
    request("/v1/moderation/admin/groups?limit=100", {
      token: "admin-token",
    }),
  );

  assert.equal(fullResponse.status, 200);
  const fullData = await fullResponse.json();

  const pageResponse = await room.fetch(
    request("/v1/moderation/admin/groups?limit=1&offset=1", {
      token: "admin-token",
    }),
  );

  assert.equal(pageResponse.status, 200);
  const pageData = await pageResponse.json();

  assert.equal(pageData.total, fullData.total);
  assert.equal(pageData.groups.length, 1);
  assert.equal(
    pageData.groups[0].group_id,
    fullData.groups[1].group_id,
  );
});

test("admin group history returns active messages with attachment metadata", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups/group-a/messages?limit=100", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 200);

  const data = await response.json();
  assert.equal(data.groupId, "group-a");
  assert.equal(data.messages.length, 2);

  assert.equal(data.messages[0].message_id, "a-1");
  assert.equal(data.messages[0].sender, "alice");
  assert.equal(data.messages[0].recipient, "group:group-a");
  assert.equal(data.messages[0].plaintext, "Hello group A");

  assert.equal(data.messages[1].message_id, "a-2");
  assert.equal(data.messages[1].content_type, "image");
  assert.equal(data.messages[1].attachment_mime_type, "image/jpeg");

  assert.equal(
    data.messages.some((m) => m.message_id === "expired"),
    false,
  );
});

test("admin group history rejects non-admin sessions", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups/group-a/messages", {
      token: "user-role-token",
    }),
  );

  assert.equal(response.status, 401);
});

test("admin group history validates pagination", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups/group-a/messages?limit=101", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 400);
});

test("admin group history supports message pagination", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/groups/group-a/messages?limit=1&offset=1", {
      token: "admin-token",
    }),
  );

  assert.equal(response.status, 200);

  const data = await response.json();
  assert.equal(data.messages.length, 1);
  assert.equal(data.messages[0].message_id, "a-2");
});
