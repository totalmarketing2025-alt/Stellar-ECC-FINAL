function normalizeNickname(value) {
  return String(value || "").trim().toLowerCase();
}

function validNickname(nickname) {
  return /^[a-z0-9_]{3,32}$/.test(nickname);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

export class DirectoryStore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/nickname") {
      const nickname = normalizeNickname(
        url.searchParams.get("nickname"),
      );

      if (!validNickname(nickname)) {
        return json({
          available: false,
          error: "Invalid nickname",
        }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      return json({
        available: !user,
        nickname,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/nickname/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/nickname/".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({
          available: false,
          error: "Invalid nickname",
        }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      return json({
        available: !user,
        nickname,
      });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/bundle")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/users/".length, url.pathname.length - "/bundle".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      if (!body.bundle || typeof body.bundle !== "object") {
        return json({ error: "Invalid bundle" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (existingBundle?.identityKey !== body.bundle.identityKey ||
          existingBundle?.registrationId !== body.bundle.registrationId ||
          existingBundle?.deviceId !== body.bundle.deviceId) {
        return json({ error: "Identity mismatch" }, 409);
      }

      const user = {
        ...existing,
        bundle: body.bundle,
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
        updated: true,
      });
    }


    if (request.method === "POST" &&
        url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token/challenge")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token/challenge".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const challengeKey = `push-challenge:${nickname}`;
      const now = Date.now();
      const stored = await this.ctx.storage.get(challengeKey);

      if (stored &&
          typeof stored.challenge === "string" &&
          typeof stored.expiresAt === "number" &&
          stored.expiresAt > now) {
        return json({
          nickname,
          challenge: stored.challenge,
          expiresAt: stored.expiresAt,
        });
      }

      const challenge = createPushChallenge();
      const expiresAt = now + PUSH_CHALLENGE_TTL_MS;

      await this.ctx.storage.put(
        challengeKey,
        {
          challenge,
          expiresAt,
        },
      );

      return json({
        nickname,
        challenge,
        expiresAt,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const auth = request.headers.get("authorization") || "";
      const expected = this.env.RELAY_SHARED_SECRET || "";
      if (!expected || auth !== `Bearer ${expected}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );
      if (!validNickname(nickname)) return json({ error: "Invalid nickname" }, 400);

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);
      if (!existing) return json({ error: "User not found" }, 404);

      return json({
        nickname,
        push: existing.push ?? null,
      });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const token =
        typeof body.token === "string"
          ? body.token.trim()
          : "";

      const platform =
        typeof body.platform === "string"
          ? body.platform.trim().toLowerCase()
          : "";

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge.trim()
          : "";

      const signature =
        typeof body.signature === "string"
          ? body.signature.trim()
          : "";

      if (!token ||
          token.length > 4096 ||
          !["android", "ios"].includes(platform) ||
          !challenge ||
          challenge.length > 512 ||
          !signature) {
        return json({ error: "Invalid push authorization" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (!existingBundle ||
          typeof existingBundle.identityKey !== "string" ||
          typeof existingBundle.registrationId !== "number" ||
          typeof existingBundle.deviceId !== "number") {
        return json({
          error: "Push authorization unavailable",
        }, 409);
      }

      const challengeKey = `push-challenge:${nickname}`;
      const storedChallenge =
        await this.ctx.storage.get(challengeKey);

      const now = Date.now();

      if (!storedChallenge ||
          storedChallenge.challenge !== challenge ||
          typeof storedChallenge.expiresAt !== "number" ||
          storedChallenge.expiresAt <= now) {
        if (storedChallenge) {
          await this.ctx.storage.delete(challengeKey);
        }

        return json({
          error: "Invalid or expired push challenge",
        }, 401);
      }

      const authMessage = buildPushAuthMessage({
        nickname,
        deviceId: existingBundle.deviceId,
        registrationId: existingBundle.registrationId,
        platform,
        token,
        challenge,
      });

      const validSignature =
        await verifySignalIdentitySignature({
          identityKey: existingBundle.identityKey,
          message: authMessage,
          signature,
        });

      if (!validSignature) {
        return json({
          error: "Invalid push authorization",
        }, 401);
      }

      await this.ctx.storage.delete(challengeKey);

      const user = {
        ...existing,
        push: {
          token,
          platform,
          updatedAt: now,
        },
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
        registered: true,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/users/".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      if (!user) {
        return json({ error: "User not found" }, 404);
      }

      return json(user);
    }

    if (request.method === "POST" && url.pathname === "/v1/register") {
      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body.nickname);

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      if (!body.bundle || typeof body.bundle !== "object") {
        return json({ error: "Invalid bundle" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (existing) {
        return json({
          error: "Nickname already registered",
        }, 409);
      }

      const user = {
        nickname,
        bundle: body.bundle,
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
      }, 201);
    }

    if (request.method === "GET" && url.pathname === "/v1/users") {
      const result = await this.ctx.storage.list({
        prefix: "user:",
      });

      const users = [];

      for (const value of result.values()) {
        if (value && typeof value.nickname === "string") {
          users.push(value.nickname);
        }
      }

      users.sort();

      return json({ users });
    }

    return new Response("Not Found", { status: 404 });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "stellar-directory",
      });
    }

    if (
      !url.pathname.startsWith("/v1/")
    ) {
      return new Response("Not Found", {
        status: 404,
      });
    }

    const id = env.DIRECTORY.idFromName("global");
    const stub = env.DIRECTORY.get(id);

    return stub.fetch(request);
  },
};
