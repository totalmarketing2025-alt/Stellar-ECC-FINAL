import http from 'node:http';
import express from 'express';
import { WebSocketServer } from 'ws';

const app = express();

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    service: 'stellar-relay',
  });
});

const server = http.createServer(app);

const wss = new WebSocketServer({
  server,
  path: '/v1/connect',
});

const clients = new Map();

wss.on('connection', (socket, request) => {
  const url = new URL(
    request.url,
    `http://${request.headers.host}`,
  );

  const peer = url.searchParams.get('peer');

  if (!peer) {
    socket.close(1008, 'peer required');
    return;
  }

  clients.set(peer, socket);

  socket.on('message', (data, isBinary) => {
    const raw = isBinary
      ? Buffer.from(data)
      : Buffer.from(data.toString());

    // Envelope format:
    // first line: recipient route
    // remaining bytes: opaque ciphertext/envelope.
    //
    // The relay does not inspect the cryptographic payload.

    const separator = raw.indexOf(0x0a);

    if (separator <= 0) {
      return;
    }

    const recipient = raw
      .subarray(0, separator)
      .toString('utf8');

    const payload = raw.subarray(separator + 1);

    const target = clients.get(recipient);

    if (!target || target.readyState !== 1) {
      return;
    }

    target.send(payload);
  });

  socket.on('close', () => {
    if (clients.get(peer) === socket) {
      clients.delete(peer);
    }
  });
});

const port = Number(
  process.env.PORT || 8787,
);

server.listen(
  port,
  '127.0.0.1',
  () => {
    console.log(
      `Stellar Relay listening on ${port}`,
    );
  },
);
