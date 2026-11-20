# STELLAR Guard — Phase 03 case audit and review

Status: **draft implementation only**. Do not merge to `main`, deploy, run a production backfill or enable deletion without explicit approval and a staging review. The Guard screen remains disabled, and the Moderator app has no Guard approval control yet.

## Scope

Guard submissions from Phase 02 produce persistent `pending_review` cases. Phase 03 adds, in the **same Durable Object storage transaction** as a case change:

1. A SHA-256 digest of the stable case evidence (`caseId`, requester, nine-digit target code, resolved nickname if known, reason, details, original creation time).
2. An append-only event at `guard-case-audit:{caseId}:{sequence}` for each submission or cancellation. Events include event type, actor, timestamp, previous/new status, evidence digest, previous event hash and SHA-256 event hash.
3. The current event sequence and head hash on the case record.

Case status, evidence and the entire event chain are verified before an authenticated user can change an existing case, and when an authorized reviewer reads it. Missing/modified events or mismatched evidence fail closed with HTTP `409`; no automatic repair or rehash happens for corrupted records. Repeating an idempotent request or an already-completed cancellation does **not** add another event.

## Protected operator APIs

All requests use `Authorization: Bearer <GUARD_REVIEW_SECRET>` (TLS required). The secret must be at least 32 characters and different from `RELAY_SHARED_SECRET` and `GUARD_MIGRATION_SECRET`. When unset, these routes return `401`. There is no permission to approve, reject, delete, wipe or revoke any account.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/v1/internal/guard-cases?limit=25&after=<caseId>` | Sorted, paginated summaries (max 50). Excludes target codes and evidence details. |
| GET | `/v1/internal/guard-cases/{caseId}` | Full case, verification state and ordered audit events. |
| POST | `/v1/internal/guard-cases/backfill-audit` | Explicit, bounded audit migration for pre-Phase-03 cases. JSON body: `{ "limit": 25, "after": null }`; max 50 per call. |

List responses include `nextCursor` (or `null`) and `done`. Only `caseId`, requester, status, timestamps and `auditStatus` are exposed in summaries. A case detail has `auditStatus: "verified"` or `"legacy"` (not yet migrated). `409` means **stop**: do not attempt a workaround by manually changing hashes.

The list cursor is a lexicographic case ID, not a snapshot. During concurrent submissions, a newly inserted case with a smaller ID may not appear in the current pass. Operators should repeat a scan after migration to account for concurrent writes.

## Safe backfill procedure

1. Review the earlier Phase 01/02 changes and validate this change in staging first. Take a recoverable backup of the Directory Durable Object before changing pre-existing cases.
2. Configure `GUARD_REVIEW_SECRET` securely in the **staging** Directory Worker. Do not put it in a repository, browser client, mobile APK or URL.
3. Read the internal listing and individual case details. Any `corrupt` result must be investigated before proceeding.
4. Invoke `POST /v1/internal/guard-cases/backfill-audit` with a small page (`limit: 1` initially). Continue with `nextCursor` until `done: true` and re-scan. Repeating the same batch is idempotent.
5. Verify that legacy records now have exactly one `legacy_imported` event, that their original case creation timestamp remains unchanged, and that subsequent cancellations append a second event. A migration event records **when the case was imported**; it is not evidence of the original submission event.
6. Only after staged backup/restoration and integrity checks should a separate, explicit production rollout be considered.

No legacy case is changed automatically when the Worker starts or a case is listed. A user cancelling a still-pending legacy case will first append an accurately labeled `legacy_imported` event, followed by the cancellation event in one transaction.

## Security limitations and next phases

- This is application-level append-only storage with hash-chain integrity checks. It detects ordinary accidental edits and many partial modifications. **It is not cryptographically immutable against an operator who controls the Durable Object database or Worker code and can recompute the hashes.** External write-once evidence storage or independently anchored signed digests remain a production hardening requirement.
- Internal Bearer authorization is a temporary server-to-server boundary, **not** the Moderator user authentication flow. Phase 05 must verify moderator roles, use short-lived sessions, enforce least privilege and write reviewed decisions to this audit chain.
- Evidence details can be sensitive. Do not expose internal endpoints or secrets to clients; encrypt/export appropriately and set a retention policy before production.
- The Guard case API still only supports `pending_review` and `cancelled`. There is no approval, account removal, automatic deletion, or background execution.
- Phase 04: Flutter case submission/status UI. Phase 05: Moderator review/approval. Later phases: durable processing, account revocation, data removal, retries, backups and release tests.

## Verification

From `backend/cloudflare-directory`:

```bash
node --test tests/guard_code.test.mjs tests/guard_case.test.mjs tests/guard_audit.test.mjs
node tests/xeddsa_verify.test.mjs
```

GitHub's `Directory Backend Test` workflow also runs Wrangler `deploy --dry-run` on pull requests. Actual Directory deployment is gated to pushes on `main` and is not authorized as part of this phase.
