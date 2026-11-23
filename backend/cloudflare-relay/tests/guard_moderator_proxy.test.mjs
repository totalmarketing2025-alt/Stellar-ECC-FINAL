import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { webcrypto } from 'node:crypto';

const source = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8')
  .replace(/\bexport class RelayRoom\b/, 'class RelayRoom')
  .replace(/\bexport class ModerationRoom\b/, 'class ModerationRoom')
  .replace(/\bexport default\s*\{/, 'const worker = {');

function harness() {
  const calls = [];
  const cleanupCalls = [];
  const forwarded = async (url, options) => {
    calls.push({ url, options });
    return Response.json(options.method === 'POST' ? {
      caseId, status: 'approved', profileDeleted: true,
      targetNickname: 'bob',
    } : { cases: [], done: true });
  };
  const factory = new Function('crypto', 'TextEncoder', 'setTimeout', 'fetch',
    'btoa', 'atob', 'console', `${source}\nreturn ModerationRoom;`);
  const Room = factory(webcrypto, TextEncoder, setTimeout, forwarded, btoa, atob,
    { log() {}, error() {}, warn() {} });
  const sessions = new Map([
    ['moderation-admin-session:valid', { role: 'admin', expiresAt: Date.now() + 60000 }],
    ['moderation-admin-session:user', { role: 'user', expiresAt: Date.now() + 60000 }],
  ]);
  const room = new Room({ storage: {
    sql: { exec() { return { one() {}, toArray() { return []; } }; } },
    async get(key) { return sessions.get(key); },
    async delete(key) { sessions.delete(key); },
  } }, {
    DIRECTORY_URL: 'https://directory.test',
    GUARD_REVIEW_SECRET: 'r'.repeat(40),
    GUARD_MODERATOR_ACTION_SECRET: 'm'.repeat(40),
    RELAY_SHARED_SECRET: 's'.repeat(40),
    RELAY: {
      idFromName(name) { return name; },
      get() { return { async fetch(req) {
        cleanupCalls.push({ authorization: req.headers.get('Authorization'),
          body: await req.json() });
        return Response.json({ ok: true });
      } }; },
    },
  });
  return { room, calls, cleanupCalls };
}

function request(path, token, { method = 'GET', body } = {}) {
  return new Request(`https://relay.test${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

const root = '/v1/moderation/admin/guard-cases';
const caseId = '11111111-2222-3333-4444-555555555555';

test('Guard review requires admin token and is read-only', async () => {
  const { room, calls } = harness();
  assert.equal((await room.fetch(request(root, 'invalid'))).status, 401);
  assert.equal((await room.fetch(request(root, 'user'))).status, 401);
  assert.equal((await room.fetch(request(root, 'valid', { method: 'POST',
    body: { decision: 'approve', note: 'Any reason' },
  }))).status, 405);
  assert.equal(calls.length, 0);
  assert.equal((await room.fetch(request(`${root}?limit=20`, 'valid'))).status, 200);
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /guard-cases\?limit=20$/);
  assert.equal(calls[0].options.headers.Authorization, `Bearer ${'r'.repeat(40)}`);
});

test('Guard decision binds a case, action and reason, never forwards admin token', async () => {
  const { room, calls, cleanupCalls } = harness();
  const path = `${root}/${caseId}/decision`;
  assert.equal((await room.fetch(request(path, 'invalid', { method: 'POST',
    body: { decision: 'approve', note: 'Evidence checked' },
  }))).status, 401);
  assert.equal((await room.fetch(request(path, 'valid', { method: 'POST',
    body: { decision: 'delete', note: 'Evidence checked' },
  }))).status, 400);
  assert.equal((await room.fetch(request(path, 'valid', { method: 'POST',
    body: { decision: 'approve', note: 'x' },
  }))).status, 400);
  assert.equal(calls.length, 0);
  assert.equal((await room.fetch(request(path, 'valid', { method: 'POST',
    body: { decision: 'approve', note: 'Evidence checked' },
  }))).status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://directory.test/v1/internal/guard-cases/${caseId}/decision`);
  assert.equal(calls[0].options.headers.Authorization, `Bearer ${'m'.repeat(40)}`);
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    decision: 'approve', note: 'Evidence checked',
  });
  assert.deepEqual(cleanupCalls, [{
    authorization: `Bearer ${'m'.repeat(40)}`, body: { nickname: 'bob' },
  }]);
});
