import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8')
  .replace(/\bexport class RelayRoom\b/, 'class RelayRoom')
  .replace(/\bexport class ModerationRoom\b/, 'class ModerationRoom')
  .replace(/\bexport default\s*\{/, 'const worker = {');
const Room = new Function(`${source}\nreturn RelayRoom;`)();

function setup() {
  const queries = [];
  const tombstones = new Map();
  const sockets = [
    { nickname: 'bob', closed: false },
    { nickname: 'alice', closed: false },
  ].map((entry) => ({
    entry,
    deserializeAttachment: () => ({ peer: entry.nickname }),
    close: () => { entry.closed = true; },
  }));
  const receiver = {
    env: { GUARD_MODERATOR_ACTION_SECRET: 'm'.repeat(40),
      RELAY_SHARED_SECRET: 'r'.repeat(40) },
    ctx: {
      storage: {
        sql: { exec(...args) { queries.push(args); } },
        async put(key, value) { tombstones.set(key, value); },
        async get(key) { return tombstones.get(key); },
      },
      getWebSockets() { return sockets; },
    },
  };
  const send = (secret) => Room.prototype.fetch.call(receiver,
    new Request('https://relay.internal/v1/internal/guard-revoke', {
      method: 'POST',
      headers: { Authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
      body: JSON.stringify({ nickname: 'bob' }),
    }));
  return { receiver, send, sockets, queries, tombstones };
}

test('relay revocation is internal-only and leaves other clients connected', async () => {
  const { send, sockets, queries, tombstones } = setup();
  assert.equal((await send('wrong')).status, 401);
  assert.equal(queries.length, 0);
  assert.equal((await send('m'.repeat(40))).status, 200);
  assert.ok(tombstones.has('relay-revoked:bob'));
  assert.equal(sockets[0].entry.closed, true);
  assert.equal(sockets[1].entry.closed, false);
  assert.equal(queries.length, 3);
  for (const query of queries) {
    assert.match(query[0], /^DELETE FROM relay_/);
    assert.deepEqual(query.slice(1), ['bob', 'bob']);
  }
  await assert.rejects(
    () => Room.prototype.queueEnvelope.call(
      { ctx: { storage: { async get() { return true; } } } },
      'bob', 'alice', new Uint8Array(6)),
    /Recipient account revoked/,
  );
  assert.equal((await send('m'.repeat(40))).status, 200);
});
