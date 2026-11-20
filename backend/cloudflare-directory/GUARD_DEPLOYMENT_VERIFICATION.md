# STELLAR Guard — Phases 01–04 deployment verification gate

**Status:** Staging configuration and live smoke test prepared. A green CI
run or `wrangler deploy --dry-run` is **not** a live deployment. Do not merge
the Guard stack into `main` until the manual staging run below succeeds.

## Environment separation

The existing default Worker stays `stellar-ecc-directory` and keeps its
current production Durable Object (`DIRECTORY` → `DirectoryStore`).

`wrangler deploy --env staging` uses a **separate** Worker,
`stellar-ecc-directory-staging`, with an independent `DirectoryStore`
namespace and its own `v1-staging` SQLite migration. There is deliberately
no `script_name` pointing at the production Worker. Never share production
credentials, Guard review secret, Guard migration secret, or user data with
staging. The production Worker is **not** modified by the staging command.

Staging address:

`https://stellar-ecc-directory-staging.totalmarketing2025.workers.dev`

## Staging prerequisites (operator)

1. Create the GitHub Environment `guard-staging`. Configure its required
   reviewers if available and protect access to the staging deployment job.
2. Add `CLOUDFLARE_STAGING_API_TOKEN` as an environment **secret**, with
   permissions restricted to deploy the staging Worker. Do not grant this
   token permission to replace or read production Worker secrets.
3. Generate a distinct random staging reviewer secret of at least 32
   characters. Store it in the `guard-staging` GitHub Environment as
   `GUARD_STAGING_REVIEW_SECRET`. The workflow installs this secret as
   `GUARD_REVIEW_SECRET` **only in the staging Worker** before smoke tests.
   Never print, log, or commit it.
4. Do not configure `GUARD_MIGRATION_SECRET` in staging unless a separate
   manual legacy-migration test is explicitly approved. No automatic Guard
   code migration or audit backfill is run by the smoke test.
5. Open the deployment-verification PR targeting `main`. Its
   **STELLAR Guard Staging Verification** job runs with the `guard-staging`
   GitHub Environment and should require environment-reviewer approval.
   The workflow fails **before** deployment if credentials are absent. It
   runs Node Guard tests, deploys **only** with `--env staging`, then runs
   the live smoke test against the exact staging hostname. Rerun failed
   jobs after credentials and reviewer approval are in place.

The workflow first creates or updates the staging Worker and then installs
its private review secret. Confirm the Worker name in CLI output; never run
`wrangler deploy` without `--env staging` for this task.

## What the live smoke test verifies

- Staging Directory GET health, isolated registration of two throwaway
  accounts, and absence of the Guard code in registration/public user data.
- Signal identity proof and per-owner nine-digit code retrieval (Phase 01).
- Signed purpose-bound case challenges, case submission, UUID idempotent
  retry, status, and cancellation (Phase 02).
- Unauthorized review is rejected; an authorized **read-only** private
  case audit has a verified one-event chain, then a verified two-event chain
  after cancellation (Phase 03).
- Canonical message formats match the tested Flutter client for Phase 04;
  Flutter `analyze`, unit and widget tests remain mandatory separately.

No deletion, account revocation, approval, production API mutation, or
backfill is performed. The smoke test creates isolated **staging-only**
records and does not erase them. It rejects any non-staging URL.

## Gate before merging

1. Latest `Directory Backend Test` and `Internal Audit` checks are green.
2. Latest staging verification workflow is green on the **exact commit**
   proposed for merge. Record the workflow link and test time.
3. Verify the target branch contains the complete Phase 01→02→03→04 stack
   without unrelated changes or merge conflicts.
4. Before merging, check that GitHub repository secrets used by the
   **production** Directory workflow exist, that backups/rollback steps
   are available, and that the operator intends to enable its automatic
   `main` deployment. A main push runs `wrangler deploy` against production.
5. Merge the verified **stack tip only once**. Do not independently merge
   the older stacked PRs again. After the protected `main` deploy finishes,
   check the deployment job result and perform read-only public health checks.
   Production internal Guard evidence must only be examined through an
   explicitly authorized operator session.
6. Keep moderation approval and all account deletion unavailable. Guard
   backfills and legacy code migration require separate manual authorization
   and recoverable backups; neither is triggered by deployment.

If staging credentials, a live test result, rollback capability, or
production deployment authorization is missing, **stop before merging**.

## Local preflight commands

From `backend/cloudflare-directory`:

```bash
node --test tests/guard_code.test.mjs tests/guard_case.test.mjs tests/guard_audit.test.mjs
node --test tests/guard_staging_safety.test.mjs
node tests/xeddsa_verify.test.mjs
npx wrangler@4.129.0 deploy --dry-run --env staging
# Only with a configured staging Worker and distinct review secret:
node tests/guard_staging_smoke.mjs
```

The last command expects the staging-only reviewer secret to be supplied
through an existing secure environment binding; do not type it into shell
history or expose it in CI output.
