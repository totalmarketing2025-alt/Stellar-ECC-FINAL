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
