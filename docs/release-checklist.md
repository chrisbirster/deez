# Deez v0.2.0-rc.5 release gate

Do not publish `v0.2.0-rc.5` until every required item below is satisfied on the exact release commit.

## Scheduler correctness

- [ ] `zig build test` passes on Zig 0.16.0.
- [ ] FSRS-7 parity fixtures pass against the pinned reference vectors.
- [ ] FSRS-7 optimizer objective and positional recency-weighting tests pass.
- [ ] Time-series evaluation tests pass without future leakage.
- [ ] Simulation, forecast, and retention regression tests pass.
- [ ] Property/fuzz smoke coverage has no panic, NaN, infinity, negative interval, or invalid transition regression.
- [ ] `deez-scheduler.wasm` builds from the same Zig FSRS-7 implementation used by native Deez.
- [ ] The native WASM-boundary test produces the same scheduling candidates as the direct FSRS engine.

## MongoDB / Bongo

- [ ] Deez uses Bongo v0.6.0 at commit `1c7bdf9eb5b1c63236a432333a6b26d51d1a4ae5` with the pinned package hash.
- [ ] Live replica-set integration suite passes.
- [ ] Standalone fallback integration suite passes.
- [ ] TLS/authentication/error propagation coverage passes.
- [ ] Transactional review append/state update passes.
- [ ] Reconnect persistence passes.
- [ ] Scheduler pinning and immutable parameter-set tests pass.
- [ ] Global/group/deck parameter precedence passes.
- [ ] Logical archive dry-run/restore passes.
- [ ] Recovery rebuild preserves immutable review history.
- [ ] Required MongoDB indexes are verified independently.
- [ ] Rich-media `.sack` import/export passes against MongoDB.

## Local-first sync and data safety

- [ ] CLI sync state is scoped to the authenticated cloud origin and user ID.
- [ ] Legacy unscoped sync mappings are adopted only when their mapped remote decks belong to the authenticated account.
- [ ] Interrupted sync-scope migration cannot silently fall back to an unscoped mapping file.
- [ ] Clean deck and note deletions propagate local → cloud and cloud → local.
- [ ] Delete-vs-edit divergence is rejected as a conflict before either side is destructively mutated.
- [ ] Stale mappings are removed after converged deletion.
- [ ] Two independent SQLite devices converge through the hosted MongoDB server.
- [ ] Immutable review history converges byte-for-byte/logically across both devices.
- [ ] A second unchanged sync reports zero pushed and zero pulled decks, notes, and reviews.
- [ ] Existing deck scheduler majors do not silently change.
- [ ] Unsupported engines fail explicitly.
- [ ] Parameter activation is explicit and previous parameter sets remain available.
- [ ] Failed migrations/restores leave source history unchanged.
- [ ] Generated-card retirement preserves immutable review history when note edits remove variants.

## Content, clients, and hosted boundary

- [ ] JSON v2 export/import round trips logical notes and keeps JSON v1 import compatibility.
- [ ] `.nut` v2 export/import round trips logical notes and keeps `.nut` v1 import compatibility.
- [ ] Built-in note generation remains stable for basic, reverse, cloze, type-answer, multiple-choice, multiple-select, ordering, and image-occlusion.
- [ ] `.sack` media hashes are verified and content-addressed media survives export/import.
- [ ] `deez web` local browser serving and media delivery smoke tests pass.
- [ ] `deez serve` local API remains loopback-first and its API smoke coverage passes.
- [ ] Hosted auth/session/ownership tests pass without changing the account-free local mode.
- [ ] Production hosted auth and email endpoints remain HTTPS-only by default.
- [ ] The explicit insecure-hosted development override accepts only loopback HTTP hosts.
- [ ] Study preview exposes the exact resolved FSRS-7 parameter set required by offline WASM scheduling.
- [ ] The packaged macOS archives contain the Deez binary and pinned compiled Deez Web bundle.
- [ ] The vendored Deez Web bundle reconstructs to SHA-256 `148ecaca204ffc0633447c6fba5c01f896b863a2f1cd0a19af15d8bbc47a75ea` and matches `release/deez-web-dist/manifest.txt` provenance.

## deez.run airplane-mode acceptance

Before calling rc.5 plane-ready, the corresponding `deez-run` production build must:

- [ ] pin an immutable Deez core commit containing the rc.5 functionality.
- [ ] package `/app/web/deez-scheduler.wasm` in the production image.
- [ ] instantiate the compiled WASM artifact and execute initial + subsequent offline scheduling in CI.
- [ ] precache `/deez-scheduler.wasm` with the PWA application shell.
- [ ] keep IndexedDB as the browser source of truth with a durable mutation outbox.
- [ ] permit repeated offline reviews/relearning without requiring a network round trip after the first pending review.
- [ ] preserve each queued review's original timestamp and expected history index.
- [ ] replay multiple queued reviews in history order after reconnect.
- [ ] avoid overwriting locally divergent pending/conflicted review state during snapshot pull.
- [ ] pass the production Docker/Mongo/API/PWA/WASM smoke gate on the exact hosted-app commit that is deployed.
- [ ] serve a valid WebAssembly artifact from production and a service worker that references it.

## Performance

- [ ] `zig build benchmark -Doptimize=ReleaseFast` completes successfully.
- [ ] Scheduling benchmark recorded.
- [ ] Long-history replay benchmark recorded.
- [ ] Mongo due-queue benchmark recorded.
- [ ] Optimization benchmark recorded.
- [ ] Representative archive/import benchmark recorded.
- [ ] Baseline hardware, dataset size, Zig mode, Mongo version, and Bongo version are recorded.
- [ ] Five measured runs after warm-up are recorded and medians calculated.
- [ ] No comparable-hardware median exceeds 2.0× the previous accepted baseline without an explicit explanation in release notes.

## User experience

- [ ] README installation/build instructions match the current release.
- [ ] README and `docs/nut-format.md` document `.nut` v2 logical-note records rather than the historical v1 card format.
- [ ] MongoDB environment examples work.
- [ ] First deck/note/study workflow works with SQLite.
- [ ] `deez login`, `deez whoami`, `deez sync`, and `deez logout` help/output match supported behavior.
- [ ] `deez fsrs optimize --recency` matches current positional recency behavior.
- [ ] Stats/inspect human and JSON output work.
- [ ] Backup/recovery/migration docs are discoverable.

## Exact-SHA GitHub release matrix

The release candidate SHA must have successful runs for all five required workflows:

- [ ] `ci`
  - formatting
  - normal build and tests
  - local Web/API/media smoke
  - first-run and JSON/`.nut`/`.sack` smoke
  - benchmark warm-up plus five measured runs
  - Apple Silicon macOS release smoke
  - Intel macOS release smoke
- [ ] `Zig 0.16 + Bongo`
  - `zig build test` against the pinned Bongo v0.6.0 dependency
- [ ] `MongoDB backend`
  - replica-set, standalone, and TLS fixtures
  - `zig build mongo-integration-test`
  - required indexes
  - backup/restore
  - rich-media `.sack`
  - Mongo benchmark warm-up plus five measured runs
- [ ] `Release web bundle`
  - reconstruct the vendored compiled Deez Web artifact
  - verify exact byte size and SHA-256
  - verify the ZIP and required `index.html` / `assets` contents
- [ ] `Two-device sync convergence`
  - independent SQLite device A and device B
  - hosted MongoDB replica set
  - authenticated account-scoped sync
  - content/review convergence
  - deletion propagation and delete-vs-edit protection
  - second-sync zero-mutation invariant

Do not promote a branch merely because an earlier PR head was green. Re-run/verify these workflows after release preparation has landed on `dev`, and use that exact successful `dev` commit as the commit promoted to `main`.

## Required local-equivalent commands

```bash
zig fmt --check build.zig src test
zig build
zig build test
zig build wasm-scheduler
zig build benchmark -Doptimize=ReleaseFast
zig build mongo-integration-test
```

The Mongo integration and two-device convergence gates require their documented CI fixtures. The release web-bundle gate additionally reconstructs and checksum-verifies the vendored compiled artifact.

## Publication and Homebrew consumption

After the exact green release SHA is fast-forwarded from `dev` to `main`:

- [ ] `VERSION` is exactly `0.2.0-rc.5`.
- [ ] The release workflow creates annotated tag `v0.2.0-rc.5` on that exact SHA.
- [ ] Apple Silicon and Intel macOS archives are published with `SHA256SUMS`.
- [ ] The Homebrew formula on `main` is updated to the published tag and checksums.
- [ ] A clean macOS runner taps this repository and installs Deez through Homebrew.
- [ ] The Homebrew-installed binary completes a real SQLite deck → note → study → process restart → study persistence smoke test.

## Compatibility notes for release notes

Release notes must state:

- Deez version: v0.2.0-rc.5;
- supported Zig version: 0.16.0 for source builds;
- supported scheduler major(s): FSRS-7;
- MongoDB driver: Bongo v0.6.0 at commit `1c7bdf9eb5b1c63236a432333a6b26d51d1a4ae5`;
- current JSON and `.nut` exports use logical-note version 2 while version 1 imports remain supported;
- SQLite remains the default local backend while MongoDB is the production hosted validation backend;
- review history is immutable source of truth;
- cloud sync state is account scoped and deletion conflicts fail closed;
- `deez.run` local-first offline study uses the shared Zig/FSRS WebAssembly scheduler rather than a separate JavaScript scheduler implementation;
- existing deck scheduler major is pinned and never silently migrated;
- FSRS-8 is not claimed until a published implementation passes the full engine definition of done.

## Tagging

Only after this checklist is satisfied:

1. land release preparation on `dev`;
2. verify the full GitHub release matrix on the exact resulting `dev` SHA;
3. fast-forward `main` to that exact SHA;
4. allow `.github/workflows/release.yml` to create tag `v0.2.0-rc.5`, publish macOS archives/checksums, and update the Homebrew formula;
5. require the Homebrew consumption smoke to pass before calling the release complete.
