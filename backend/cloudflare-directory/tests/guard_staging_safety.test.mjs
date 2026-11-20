import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const script = new URL('./guard_staging_smoke.mjs', import.meta.url);
const dummyReviewSecret = 'staging-test-only-000000000000000000000000';

for (const target of [
  'https://stellar-ecc-directory.totalmarketing2025.workers.dev',
  'http://stellar-ecc-directory-staging.totalmarketing2025.workers.dev',
  'https://untrusted-worker-staging.example.test',
  'https://stellar-ecc-directory-staging.totalmarketing2025.workers.dev/path',
]) {
  test('staging smoke refuses unsafe destination: ' + target, () => {
    const result = spawnSync(process.execPath, [script.pathname], {
      env: {
        ...process.env,
        GUARD_STAGING_URL: target,
        GUARD_STAGING_REVIEW_SECRET: dummyReviewSecret,
      },
      encoding: 'utf8',
      timeout: 5000,
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Refusing non-staging or non-HTTPS Guard URL/);
  });
}
