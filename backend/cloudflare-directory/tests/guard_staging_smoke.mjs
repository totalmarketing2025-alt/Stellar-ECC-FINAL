// Live, authenticated Guard Phase 01–03 smoke verification; Phase 04's Flutter
// client signs the same canonical messages and is separately covered by tests.
//
// IMPORTANT: This script intentionally refuses every production hostname.
// It creates two disposable test identities and reports in isolated staging
// storage only. Never use production credentials or URLs here.
import assert from 'node:assert/strict';
import { randomBytes, randomUUID, webcrypto } from 'node:crypto';

const expectedHost = 'stellar-ecc-directory-staging.totalmarketing2025.workers.dev';
const base = new URL(process.env.GUARD_STAGING_URL || `https://${expectedHost}`);
if (base.protocol !== 'https:' || base.hostname !== expectedHost ||
    base.port || base.pathname !== '/' || base.search || base.hash ||
    base.username || base.password) {
  throw new Error('Refusing non-staging or non-HTTPS Guard URL');
}

const reviewSecret = process.env.GUARD_STAGING_REVIEW_SECRET;
if (!reviewSecret || reviewSecret.length < 32) {
  throw new Error('GUARD_STAGING_REVIEW_SECRET is required for full Phase 03 verification');
}

async function api(path, { method = 'GET', body, secret } = {}) {
  const response = await fetch(new URL(path, base), {
    method,
    headers: {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(secret ? { authorization: `Bearer ${secret}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  const data = await response.json().catch(() => ({}));
  return { status: response.status, data };
}

function ok(result, status, context) {
  assert.equal(result.status, status,
    `${context}: expected HTTP ${status}, got ${result.status}: ${result.data.error || 'unknown response'}`);
  return result.data;
}

const P = (1n << 255n) - 19n;
const mod = n => ((n % P) + P) % P;
function pow(baseValue, exponent) {
  let answer = 1n;
  for (; exponent > 0n; exponent >>= 1n) {
    if (exponent & 1n) answer = mod(answer * baseValue);
    baseValue = mod(baseValue * baseValue);
  }
  return answer;
}
function leBigInt(bytes) {
  return bytes.reduceRight((value, byte) => (value << 8n) | BigInt(byte), 0n);
}
function littleEndian(number, length) {
  const bytes = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    bytes[i] = Number(number & 255n);
    number >>= 8n;
  }
  return bytes;
}

async function newIdentity() {
  const pair = await webcrypto.subtle.generateKey(
    { name: 'Ed25519' }, true, ['sign', 'verify'],
  );
  const publicKey = new Uint8Array(
    await webcrypto.subtle.exportKey('raw', pair.publicKey),
  );
  const signBit = publicKey[31] >>> 7;
  publicKey[31] &= 127;
  const y = leBigInt(publicKey);
  const u = mod((1n + y) * pow(mod(1n - y), P - 2n));
  const encoded = Buffer.from([5, ...littleEndian(u, 32)]).toString('base64');
  return {
    encoded,
    async sign(message) {
      const sig = new Uint8Array(await webcrypto.subtle.sign(
        { name: 'Ed25519' }, pair.privateKey,
        new TextEncoder().encode(message),
      ));
      sig[63] |= signBit << 7;
      return Buffer.from(sig).toString('base64');
    },
  };
}

function bundle(identityKey) {
  return {
    deviceId: 1,
    registrationId: 101,
    identityKey,
    signedPreKey: {
      keyId: 2,
      publicKey: identityKey,
      signature: Buffer.alloc(64).toString('base64'),
    },
    preKey: { keyId: 3, publicKey: identityKey },
  };
}

async function ownCode(nickname, identity) {
  const challenge = ok(await api('/v1/guard/code/challenge', {
    method: 'POST', body: { nickname, deviceId: 1, registrationId: 101 },
  }), 200, 'Guard code challenge').challenge;
  assert.ok(typeof challenge === 'string' && challenge.length >= 20);
  const signature = await identity.sign(JSON.stringify([
    'stellar-guard-identity-v1', nickname, 1, 101, challenge,
  ]));
  const response = ok(await api('/v1/guard/code', {
    method: 'POST',
    body: { nickname, deviceId: 1, registrationId: 101, challenge, signature },
  }), 200, 'Guard own code');
  assert.match(response.guardCode, /^[0-9]{9}$/);
  return response.guardCode;
}

async function signedAction(nickname, identity, action, {
  caseId = '', targetCode = '', reason = '', details = '', idempotencyKey = '',
} = {}) {
  const challenge = ok(await api('/v1/guard/cases/challenge', {
    method: 'POST',
    body: { nickname, deviceId: 1, registrationId: 101, purpose: action },
  }), 200, `Guard ${action} challenge`).challenge;
  const signature = await identity.sign(JSON.stringify([
    'stellar-guard-case-v1', action, nickname, 1, 101, challenge, caseId,
    action === 'submit' ? targetCode : '',
    action === 'submit' ? reason : '',
    action === 'submit' ? details : '',
    action === 'submit' ? idempotencyKey : '',
  ]));
  const path = action === 'submit'
    ? '/v1/guard/cases'
    : `/v1/guard/cases/${caseId}/${action}`;
  return api(path, {
    method: 'POST',
    body: {
      nickname, deviceId: 1, registrationId: 101, challenge, signature,
      ...(action === 'submit' ? {
        targetCode, reason, details, idempotencyKey,
      } : {}),
    },
  });
}

async function main() {
  const nonce = randomBytes(6).toString('hex');
  const alice = `gst_a_${nonce}`;
  const bob = `gst_b_${nonce}`;
  const [aliceKey, bobKey] = await Promise.all([newIdentity(), newIdentity()]);

  ok(await api(`/v1/nickname?nickname=${alice}`), 200, 'Directory health');

  for (const [nickname, identity] of [[alice, aliceKey], [bob, bobKey]]) {
    const registered = ok(await api('/v1/register', {
      method: 'POST', body: { nickname, bundle: bundle(identity.encoded) },
    }), 201, 'Account registration');
    assert.equal(registered.guardCode, undefined, 'Code leaked at registration');
    const publicUser = ok(await api(`/v1/users/${nickname}`), 200,
      'Public account lookup');
    assert.equal(publicUser.guardCode, undefined, 'Code leaked publicly');
  }

  const [aliceCode, bobCode] = await Promise.all([
    ownCode(alice, aliceKey), ownCode(bob, bobKey),
  ]);
  assert.notEqual(aliceCode, bobCode, 'Guard codes collided');
  const idempotencyKey = randomUUID();
  const details = `Staging verification ${nonce}: automated test evidence only.`;
  const payload = {
    targetCode: bobCode,
    reason: 'other',
    details,
    idempotencyKey,
  };

  const submitted = ok(await signedAction(alice, aliceKey, 'submit', payload),
    200, 'Case submission');
  assert.match(submitted.caseId, /^[a-f0-9-]{36}$/i);
  assert.equal(submitted.status, 'pending_review');
  assert.equal(submitted.targetNickname, undefined,
    'Case response leaked target identity');
  const caseId = submitted.caseId;

  const retried = ok(await signedAction(alice, aliceKey, 'submit', payload),
    200, 'Idempotent retry');
  assert.equal(retried.caseId, caseId);

  const status = ok(await signedAction(alice, aliceKey, 'status', { caseId }),
    200, 'Case status');
  assert.equal(status.status, 'pending_review');

  ok(await api('/v1/internal/guard-cases', {}), 401,
    'Unauthorized private review must be denied');
  const privateCase = ok(await api(`/v1/internal/guard-cases/${caseId}`, {
    secret: reviewSecret,
  }), 200, 'Private audit review');
  assert.equal(privateCase.auditStatus, 'verified');
  assert.deepEqual(privateCase.events.map(e => e.type), ['case_submitted']);

  const cancelled = ok(await signedAction(alice, aliceKey, 'cancel', { caseId }),
    200, 'Case cancellation');
  assert.equal(cancelled.status, 'cancelled');
  const finalCase = ok(await api(`/v1/internal/guard-cases/${caseId}`, {
    secret: reviewSecret,
  }), 200, 'Final audit review');
  assert.equal(finalCase.auditStatus, 'verified');
  assert.deepEqual(finalCase.events.map(e => e.type), [
    'case_submitted', 'case_cancelled',
  ]);
  const finalStatus = ok(await signedAction(alice, aliceKey, 'status', { caseId }),
    200, 'Cancelled case status');
  assert.equal(finalStatus.status, 'cancelled');

  console.log('PASS: isolated staging registration, Guard codes, signed cases, '
    + 'idempotency, status, cancellation, and verified private audit.');
  console.log('No production endpoints, moderator approvals, or deletions used.');
}

main().catch(error => {
  console.error(`Guard staging smoke FAILED: ${error.message}`);
  process.exitCode = 1;
});
