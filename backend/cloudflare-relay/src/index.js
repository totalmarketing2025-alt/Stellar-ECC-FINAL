export class RelayRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response(
        JSON.stringify({
          ok: true,
          service: "stellar-relay",
        }),
        {
          headers: {
            "content-type": "application/json",
          },
        },
      );
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    this.ctx.acceptWebSocket(server);

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  async webSocketMessage(ws, message) {
    const peers = this.ctx.getWebSockets();

    for (const peer of peers) {
      if (peer !== ws) {
        try {
          peer.send(message);
        } catch (_) {
          // Ignore disconnected peers.
        }
      }
    }
  }

  async webSocketClose(ws) {
    try {
      ws.close();
    } catch (_) {}
  }

  async webSocketError(ws) {
    try {
      ws.close();
    } catch (_) {}
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        service: "stellar-relay",
      });
    }

    if (url.pathname !== "/v1/connect") {
      return new Response("Not Found", {
        status: 404,
      });
    }

    const room = url.searchParams.get("peer") || "default";

    const id = env.RELAY.idFromName(room);
    const stub = env.RELAY.get(id);

    return stub.fetch(request);
  },
};
