const users = new Map();

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
    },
  });
}

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "stellar-directory",
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/nickname/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(url.pathname.substring("/v1/nickname/".length)),
      );

      const user = users.get(nickname);

      if (!user) {
        return json({ available: true, nickname });
      }

      return json({
        available: false,
        nickname,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(url.pathname.substring("/v1/users/".length)),
      );

      const user = users.get(nickname);

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

      if (users.has(nickname)) {
        return json({ error: "Nickname already registered" }, 409);
      }

      const user = {
        nickname,
        bundle: body.bundle,
      };

      users.set(nickname, user);

      return json({
        ok: true,
        nickname,
      }, 201);
    }

    if (request.method === "GET" && url.pathname === "/v1/users") {
      return json({
        users: Array.from(users.values()).map((user) => user.nickname),
      });
    }

    return new Response("Not Found", { status: 404 });
  },
};
