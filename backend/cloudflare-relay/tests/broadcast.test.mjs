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

  assert.match(source, /class ModerationRoom/);

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
  const broadcasts = new Map();
  const sessions = new Map([
    [
      "moderation-admin-session:admin-token",
      {
        role: "admin",
        username: "test-admin",
        expiresAt: Date.now() + 60_000,
      },
    ],
    [
      "moderation-session:user-token",
      {
        nickname: "test-user",
        deviceId: 1,
        registrationId: 1,
        expiresAt: Date.now() + 60_000,
      },
    ],
  ]);

  const attachments = new Map();

  const sql = {
    exec(statement, ...params) {
      const normalized = statement.replace(/\s+/g, " ").trim();

      if (/^CREATE TABLE IF NOT EXISTS /.test(normalized)) {
        return { toArray: () => [], one: () => null };
      }

      if (/^ALTER TABLE moderation_messages /.test(normalized)) {
        throw new Error("duplicate column name: attachment_mime_type");
      }

      if (/^INSERT INTO moderation_broadcasts /.test(normalized)) {
        const [
          broadcast_id,
          title,
          message,
          created_at,
          created_by,
          attachment_mime_type,
        ] = params;

        broadcasts.set(broadcast_id, {
          broadcast_id,
          title,
          message,
          created_at,
          created_by,
          attachment_mime_type,
          attachment_size: null,
        });

        return { toArray: () => [], one: () => null };
      }

      if (
        /^SELECT broadcast_id, attachment_mime_type, attachment_size FROM moderation_broadcasts WHERE broadcast_id = \?$/i
          .test(normalized)
      ) {
        const row = broadcasts.get(params[0]);
        return {
          one: () => row ?? null,
          toArray: () => (row ? [row] : []),
        };
      }

      if (
        /^SELECT broadcast_id, attachment_mime_type FROM moderation_broadcasts WHERE broadcast_id = \?$/i
          .test(normalized)
      ) {
        const row = broadcasts.get(params[0]);
        return {
          one: () => row
            ? {
                broadcast_id: row.broadcast_id,
                attachment_mime_type: row.attachment_mime_type,
              }
            : null,
          toArray: () => (row ? [row] : []),
        };
      }

      if (/^SELECT broadcast_id, title, message, created_at, created_by, attachment_mime_type, attachment_size FROM moderation_broadcasts ORDER BY created_at DESC LIMIT \? OFFSET \?$/i.test(normalized)) {
        const [limit, offset] = params;
        const rows = [...broadcasts.values()]
          .sort((a, b) => b.created_at - a.created_at)
          .slice(offset, offset + limit);

        return { toArray: () => rows, one: () => rows[0] ?? null };
      }

      if (/^UPDATE moderation_broadcasts SET attachment_size = \? WHERE broadcast_id = \?$/i.test(normalized)) {
        const [size, id] = params;
        const row = broadcasts.get(id);

        if (row) row.attachment_size = size;

        return { toArray: () => [], one: () => null };
      }

      throw new Error(`Unexpected SQL in test harness: ${normalized}`);
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

  const ctx = { storage };

  const env = {
    MODERATION_ATTACHMENTS: {
      async put(key, value, options) {
        attachments.set(key, {
          bytes: new Uint8Array(value),
          contentType: options?.httpMetadata?.contentType,
        });
      },
      async get(key) {
        const item = attachments.get(key);
        if (!item) return null;

        return {
          body: item.bytes,
          httpMetadata: { contentType: item.contentType },
        };
      },
    },
  };

  const ModerationRoom = loadModerationRoom();
  const room = new ModerationRoom(ctx, env);

  return { room, broadcasts, attachments };
}

function request(path, {
  method = "GET",
  token,
  headers = {},
  body,
} = {}) {
  const requestHeaders = new Headers(headers);

  if (token) {
    requestHeaders.set("Authorization", `Bearer ${token}`);
  }

  return new Request(`https://relay.test${path}`, {
    method,
    headers: requestHeaders,
    body,
  });
}

test("broadcast creation requires an admin session", async () => {
  const { room, broadcasts } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/broadcasts", {
      method: "POST",
      body: JSON.stringify({
        title: "Maintenance",
        message: "The service will be updated.",
      }),
      headers: { "Content-Type": "application/json" },
    }),
  );

  assert.equal(response.status, 401);
  assert.equal(broadcasts.size, 0);
});

test("admin can create a broadcast and authenticated users can retrieve it", async () => {
  const { room, broadcasts } = createHarness();

  const createResponse = await room.fetch(
    request("/v1/moderation/admin/broadcasts", {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "Maintenance",
        message: "The service will be updated.",
      }),
    }),
  );

  assert.equal(createResponse.status, 201);

  const created = await createResponse.json();

  assert.equal(created.ok, true);
  assert.equal(created.broadcast.title, "Maintenance");
  assert.equal(created.broadcast.message, "The service will be updated.");
  assert.equal(created.broadcast.created_by, "test-admin");
  assert.equal(broadcasts.size, 1);

  const listResponse = await room.fetch(
    request("/v1/moderation/broadcasts", {
      token: "user-token",
    }),
  );

  assert.equal(listResponse.status, 200);

  const listed = await listResponse.json();

  assert.equal(listed.broadcasts.length, 1);
  assert.equal(
    listed.broadcasts[0].broadcast_id,
    created.broadcast.broadcast_id,
  );
});

test("unauthenticated users cannot list broadcasts", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/broadcasts"),
  );

  assert.equal(response.status, 401);
});

test("broadcast creation validates required fields", async () => {
  const { room, broadcasts } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/broadcasts", {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "   ",
        message: "A message",
      }),
    }),
  );

  assert.equal(response.status, 400);
  assert.equal(broadcasts.size, 0);
});

test("broadcast attachment upload and download preserve bytes and MIME type", async () => {
  const { room, broadcasts, attachments } = createHarness();

  const createResponse = await room.fetch(
    request("/v1/moderation/admin/broadcasts", {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "Document",
        message: "Please read the attachment.",
        attachmentMimeType: "text/plain",
      }),
    }),
  );

  assert.equal(createResponse.status, 201);

  const { broadcast } = await createResponse.json();
  const id = broadcast.broadcast_id;
  const bytes = new TextEncoder().encode("Broadcast attachment");

  const uploadResponse = await room.fetch(
    request(`/v1/moderation/admin/broadcasts/${id}/attachment`, {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "text/plain" },
      body: bytes,
    }),
  );

  assert.equal(uploadResponse.status, 201);
  assert.equal((await uploadResponse.json()).size, bytes.byteLength);
  assert.equal(attachments.size, 1);
  assert.equal(broadcasts.get(id).attachment_size, bytes.byteLength);

  const downloadResponse = await room.fetch(
    request(`/v1/moderation/broadcasts/${id}/attachment`, {
      token: "user-token",
    }),
  );

  assert.equal(downloadResponse.status, 200);
  assert.equal(downloadResponse.headers.get("Content-Type"), "text/plain");
  assert.equal(downloadResponse.headers.get("Cache-Control"), "no-store");
  assert.equal(
    new TextDecoder().decode(await downloadResponse.arrayBuffer()),
    "Broadcast attachment",
  );
});

test("broadcast attachment cannot be downloaded without authentication", async () => {
  const { room } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/broadcasts/123e4567-e89b-12d3-a456-426614174000/attachment"),
  );

  assert.equal(response.status, 401);
});


test("broadcast attachment rejects mismatched MIME type", async () => {
  const { room, attachments } = createHarness();

  const created = await room.fetch(request(
    "/v1/moderation/admin/broadcasts",
    {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "MIME test",
        message: "Testing attachment MIME validation",
        attachmentMimeType: "text/plain",
      }),
    },
  ));

  assert.equal(created.status, 201);
  const { broadcast } = await created.json();

  const uploaded = await room.fetch(request(
    `/v1/moderation/admin/broadcasts/${broadcast.broadcast_id}/attachment`,
    {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/octet-stream" },
      body: "test bytes",
    },
  ));

  assert.equal(uploaded.status, 400);
  assert.equal(attachments.size, 0);
});

test("broadcast attachment upload rejects a nonexistent broadcast", async () => {
  const { room, attachments } = createHarness();

  const response = await room.fetch(request(
    "/v1/moderation/admin/broadcasts/123e4567-e89b-12d3-a456-426614174000/attachment",
    {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "text/plain" },
      body: "attachment",
    },
  ));

  assert.equal(response.status, 404);
  assert.equal(attachments.size, 0);
});

test("broadcast attachment download returns 404 when the attachment is missing", async () => {
  const { room } = createHarness();

  const created = await room.fetch(request(
    "/v1/moderation/admin/broadcasts",
    {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "Missing attachment",
        message: "The attachment has not been uploaded",
        attachmentMimeType: "text/plain",
      }),
    },
  ));

  assert.equal(created.status, 201);
  const { broadcast } = await created.json();

  const response = await room.fetch(request(
    `/v1/moderation/broadcasts/${broadcast.broadcast_id}/attachment`,
    { token: "user-token" },
  ));

  assert.equal(response.status, 404);
});

test("oversized broadcast attachment is rejected without Content-Length", async () => {
  const { room, attachments } = createHarness();

  const created = await room.fetch(request(
    "/v1/moderation/admin/broadcasts",
    {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "Large attachment",
        message: "Testing the 8 MiB limit",
        attachmentMimeType: "application/octet-stream",
      }),
    },
  ));

  assert.equal(created.status, 201);
  const { broadcast } = await created.json();

  const body = new Uint8Array(8 * 1024 * 1024 + 1);
  const uploadRequest = request(
    `/v1/moderation/admin/broadcasts/${broadcast.broadcast_id}/attachment`,
    {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/octet-stream" },
      body,
    },
  );

  assert.equal(uploadRequest.headers.has("Content-Length"), false);

  const response = await room.fetch(uploadRequest);

  assert.equal(response.status, 413);
  assert.equal(attachments.size, 0);
});

test("ordinary user cannot create a broadcast", async () => {
  const { room, broadcasts } = createHarness();

  const response = await room.fetch(
    request("/v1/moderation/admin/broadcasts", {
      method: "POST",
      token: "user-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "Unauthorized",
        message: "This must not be created.",
      }),
    }),
  );

  assert.equal(response.status, 401);
  assert.equal(broadcasts.size, 0);
});

test("ordinary user cannot upload a broadcast attachment", async () => {
  const { room, attachments } = createHarness();

  const created = await room.fetch(
    request("/v1/moderation/admin/broadcasts", {
      method: "POST",
      token: "admin-token",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "Permission test",
        message: "Only admins may upload attachments.",
        attachmentMimeType: "text/plain",
      }),
    }),
  );

  assert.equal(created.status, 201);
  const { broadcast } = await created.json();

  const response = await room.fetch(
    request(
      `/v1/moderation/admin/broadcasts/${broadcast.broadcast_id}/attachment`,
      {
        method: "POST",
        token: "user-token",
        headers: { "Content-Type": "text/plain" },
        body: "unauthorized attachment",
      },
    ),
  );

  assert.equal(response.status, 401);
  assert.equal(attachments.size, 0);
});

test("broadcast listing rejects invalid pagination", async () => {
  const { room } = createHarness();

  for (const query of [
    "?limit=0",
    "?limit=101",
    "?limit=abc",
    "?offset=-1",
    "?offset=1.5",
  ]) {
    const response = await room.fetch(
      request(`/v1/moderation/broadcasts${query}`, {
        token: "user-token",
      }),
    );

    assert.equal(response.status, 400, `Expected 400 for ${query}`);
  }
});

test("broadcast listing returns newest broadcasts first", async () => {
  const { room } = createHarness();

  async function createBroadcast(title) {
    const response = await room.fetch(
      request("/v1/moderation/admin/broadcasts", {
        method: "POST",
        token: "admin-token",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          title,
          message: `Message for ${title}`,
        }),
      }),
    );

    assert.equal(response.status, 201);
    return (await response.json()).broadcast;
  }

  const older = await createBroadcast("Older broadcast");
  await new Promise((resolve) => setTimeout(resolve, 5));
  const newer = await createBroadcast("Newer broadcast");

  const response = await room.fetch(
    request("/v1/moderation/broadcasts", {
      token: "user-token",
    }),
  );

  assert.equal(response.status, 200);
  const { broadcasts } = await response.json();

  assert.ok(broadcasts.length >= 2);
  assert.equal(broadcasts[0].broadcast_id, newer.broadcast_id);
  assert.equal(broadcasts[1].broadcast_id, older.broadcast_id);
});
