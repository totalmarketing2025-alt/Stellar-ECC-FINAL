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

    // Stellar Envelope v1 binary format:
    // u16 version
    // u32 relay TTL
    // u16 delivery-token length + token
    // u16 recipient-route length + route
    // u32 ciphertext length + ciphertext
    //
    // The relay reads only the routing metadata.
    // The ciphertext remains opaque.

    if (raw.length < 8) {
      return;
    }

    let offset = 0;

    const version = raw.readUInt16BE(offset);
    offset += 2;

    const relayTtlSeconds = raw.readUInt32BE(offset);
    offset += 4;

    const tokenLength = raw.readUInt16BE(offset);
    offset += 2;

    if (offset + tokenLength + 2 > raw.length) {
      return;
    }

    offset += tokenLength;

    const routeLength = raw.readUInt16BE(offset);
    offset += 2;

    if (routeLength <= 0 ||
        offset + routeLength + 4 > raw.length) {
      return;
    }

    const recipient = raw
      .subarray(offset, offset + routeLength)
      .toString('utf8');

    offset += routeLength;

    const ciphertextLength = raw.readUInt32BE(offset);
    offset += 4;

    if (offset + ciphertextLength > raw.length) {
      return;
    }

    const payload = raw.subarray(
      offset,
      offset + ciphertextLength,
    );

    if (version !== 1 || relayTtlSeconds <= 0) {
      return;
    }

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
