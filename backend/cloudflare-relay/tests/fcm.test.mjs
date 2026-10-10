import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto, generateKeyPairSync } from "node:crypto";

const sourceUrl = new URL("../src/index.js", import.meta.url);
const originalSource = await readFile(sourceUrl, "utf8");

function loadRelay(fetchMock) {
  const source = originalSource
    .replace(
      /\bexport class RelayRoom\b/,
      "class RelayRoom",
    )
    .replace(
      /\bexport class ModerationRoom\b/,
      "class ModerationRoom",
    )
    .replace(
      /\bexport default\s*\{/,
      "const worker = {",
    );

  assert.match(source, /class RelayRoom/);
  assert.match(source, /const worker = \{/);

  const quietConsole = {
    log() {},
    warn() {},
    error() {},
  };

  const immediateTimeout = (callback) => {
    callback();
    return 0;
  };

  const factory = new Function(
    "crypto",
    "fetch",
    "setTimeout",
    "console",
    "TextEncoder",
    "btoa",
    "atob",
    `${source}\nreturn { RelayRoom };`,
  );

  return factory(
    webcrypto,
    fetchMock,
    immediateTimeout,
    quietConsole,
    TextEncoder,
    btoa,
    atob,
  ).RelayRoom;
}

function createRoom(fetchMock, overrides = {}) {
  const RelayRoom = loadRelay(fetchMock);
  const room = Object.create(RelayRoom.prototype);

  room.env = {
    DIRECTORY_URL: "https://directory.test",
    RELAY_SHARED_SECRET: "test-relay-secret",
    FCM_PROJECT_ID: "stellar-test-project",
    FCM_CLIENT_EMAIL: "stellar-test@example.invalid",
    FCM_PRIVATE_KEY: "DEV_PLACEHOLDER",
    ...overrides,
  };

  return room;
}

function jsonResponse(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...headers,
    },
  });
}

function generateTestPrivateKey() {
  const { privateKey } = generateKeyPairSync("rsa", {
    modulusLength: 2048,
    privateKeyEncoding: {
      type: "pkcs8",
      format: "pem",
    },
    publicKeyEncoding: {
      type: "spki",
      format: "pem",
    },
  });

  return privateKey;
}

const testPrivateKey = generateTestPrivateKey();

function configuredRoom(fetchMock) {
  return createRoom(fetchMock, {
    FCM_PRIVATE_KEY: testPrivateKey,
  });
}

test("missing FCM configuration makes no network requests", async () => {
  let requests = 0;

  const room = createRoom(async () => {
    requests++;
    throw new Error("Unexpected network request");
  });

  await room.sendPushWake("alice");

  assert.equal(requests, 0);
});

test("incoming call sends the expected high-priority FCM payload", async () => {
  const requests = [];
  const registrations = [
    { token: "android-test-token", platform: "android" },
    { token: "ios-test-token", platform: "ios" },
    { token: "unsupported-token", platform: "web" },
    { token: "", platform: "android" },
  ];

  const room = configuredRoom(async (url, options = {}) => {
    const parsedUrl = new URL(url);
    const method = options.method ?? "GET";

    requests.push({
      url: parsedUrl.href,
      method,
      options,
    });

    if (
      parsedUrl.hostname === "directory.test" &&
      method === "GET"
    ) {
      return jsonResponse({ pushRegistrations: registrations });
    }

    if (parsedUrl.hostname === "oauth2.googleapis.com") {
      return jsonResponse({ access_token: "mock-access-token" });
    }

    if (parsedUrl.hostname === "fcm.googleapis.com") {
      return jsonResponse({ name: "mock-message-id" });
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  });

  await room.sendPushWake("alice", {
    callId: "call-123",
    from: "bob",
    kind: "video",
    chatId: "direct_bob",
  });

  const fcmRequests = requests.filter(
    (request) =>
      new URL(request.url).hostname === "fcm.googleapis.com",
  );

  assert.equal(fcmRequests.length, 2);

  for (const request of fcmRequests) {
    const body = JSON.parse(request.options.body);
    const message = body.message;

    assert.equal(message.data.wake, "1");
    assert.equal(message.data.type, "call");
    assert.equal(message.data.callId, "call-123");
    assert.equal(message.data.from, "bob");
    assert.equal(message.data.kind, "video");
    assert.equal(message.data.chatId, "direct_bob");
    assert.equal(message.android.priority, "high");
    assert.equal(
      request.options.headers.Authorization,
      "Bearer mock-access-token",
    );
  }

  assert.deepEqual(
    fcmRequests.map((request) =>
      JSON.parse(request.options.body).message.token,
    ).sort(),
    ["android-test-token", "ios-test-token"],
  );
});

test("UNREGISTERED token is removed from Directory", async () => {
  const requests = [];

  const room = configuredRoom(async (url, options = {}) => {
    const parsedUrl = new URL(url);
    const method = options.method ?? "GET";

    requests.push({
      url: parsedUrl.href,
      method,
      options,
    });

    if (parsedUrl.hostname === "directory.test" && method === "GET") {
      return jsonResponse({
        pushRegistrations: [
          { token: "expired-token", platform: "android" },
        ],
      });
    }

    if (parsedUrl.hostname === "oauth2.googleapis.com") {
      return jsonResponse({ access_token: "mock-access-token" });
    }

    if (parsedUrl.hostname === "fcm.googleapis.com") {
      return jsonResponse(
        {
          error: {
            details: [
              {
                "@type":
                  "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                errorCode: "UNREGISTERED",
              },
            ],
          },
        },
        404,
      );
    }

    if (
      parsedUrl.hostname === "directory.test" &&
      method === "DELETE"
    ) {
      return new Response(null, { status: 204 });
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  });

  await room.sendPushWake("alice");

  const deleteRequests = requests.filter(
    (request) => request.method === "DELETE",
  );

  assert.equal(deleteRequests.length, 1);
  assert.match(
    deleteRequests[0].url,
    /\/v1\/users\/alice\/push-token$/,
  );
  assert.equal(
    deleteRequests[0].options.headers.Authorization,
    "Bearer test-relay-secret",
  );
  assert.deepEqual(
    JSON.parse(deleteRequests[0].options.body),
    { token: "expired-token" },
  );
});

test("transient FCM error is retried and then succeeds", async () => {
  let fcmAttempts = 0;

  const room = configuredRoom(async (url) => {
    const parsedUrl = new URL(url);

    if (
      parsedUrl.hostname === "directory.test"
    ) {
      return jsonResponse({
        pushRegistrations: [
          { token: "retry-test-token", platform: "android" },
        ],
      });
    }

    if (parsedUrl.hostname === "oauth2.googleapis.com") {
      return jsonResponse({ access_token: "mock-access-token" });
    }

    if (parsedUrl.hostname === "fcm.googleapis.com") {
      fcmAttempts++;

      if (fcmAttempts === 1) {
        return jsonResponse(
          { error: { message: "Temporary test failure" } },
          503,
        );
      }

      return jsonResponse({ name: "mock-message-id" });
    }

    throw new Error(`Unexpected request: ${url}`);
  });

  await room.sendPushWake("alice");

  assert.equal(fcmAttempts, 2);
});

test("INVALID_ARGUMENT does not remove the registered token", async () => {
  const requests = [];

  const room = configuredRoom(async (url, options = {}) => {
    const parsedUrl = new URL(url);
    const method = options.method ?? "GET";

    requests.push({ url: parsedUrl.href, method, options });

    if (parsedUrl.hostname === "directory.test" && method === "GET") {
      return jsonResponse({
        pushRegistrations: [
          { token: "keep-this-token", platform: "android" },
        ],
      });
    }

    if (parsedUrl.hostname === "oauth2.googleapis.com") {
      return jsonResponse({ access_token: "mock-access-token" });
    }

    if (parsedUrl.hostname === "fcm.googleapis.com") {
      return jsonResponse({
        error: {
          status: "INVALID_ARGUMENT",
          message: "Invalid message payload",
        },
      }, 400);
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  });

  await room.sendPushWake("alice");

  assert.equal(
    requests.filter((request) => request.method === "DELETE").length,
    0,
    "INVALID_ARGUMENT must not trigger token removal",
  );
});

test("persistent transient FCM failure stops after three attempts", async () => {
  let fcmAttempts = 0;

  const room = configuredRoom(async (url) => {
    const parsedUrl = new URL(url);

    if (parsedUrl.hostname === "directory.test") {
      return jsonResponse({
        pushRegistrations: [
          { token: "retry-limit-token", platform: "android" },
        ],
      });
    }

    if (parsedUrl.hostname === "oauth2.googleapis.com") {
      return jsonResponse({ access_token: "mock-access-token" });
    }

    if (parsedUrl.hostname === "fcm.googleapis.com") {
      fcmAttempts++;

      return jsonResponse({
        error: { message: "Temporary test failure" },
      }, 503);
    }

    throw new Error(`Unexpected request: ${url}`);
  });

  await room.sendPushWake("alice");

  assert.equal(fcmAttempts, 3);
});

test("ordinary wake uses normal priority and no call metadata", async () => {
  const fcmMessages = [];

  const room = configuredRoom(async (url, options = {}) => {
    const parsedUrl = new URL(url);

    if (parsedUrl.hostname === "directory.test") {
      return jsonResponse({
        pushRegistrations: [
          { token: "ordinary-wake-token", platform: "android" },
        ],
      });
    }

    if (parsedUrl.hostname === "oauth2.googleapis.com") {
      return jsonResponse({ access_token: "mock-access-token" });
    }

    if (parsedUrl.hostname === "fcm.googleapis.com") {
      fcmMessages.push(JSON.parse(options.body).message);
      return jsonResponse({ name: "mock-message-id" });
    }

    throw new Error(`Unexpected request: ${url}`);
  });

  await room.sendPushWake("alice");

  assert.equal(fcmMessages.length, 1);
  assert.deepEqual(fcmMessages[0].data, { wake: "1" });
  assert.equal(fcmMessages[0].android.priority, "normal");
});
