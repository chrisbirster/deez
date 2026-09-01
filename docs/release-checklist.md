# Deez v0.2.0-rc.4.2 release gate

Do not publish `v0.2.0-rc.4.2` until every required item below is satisfied on the exact release commit.

## Scheduler correctness

- [ ] `zig build test` passes on Zig 0.16.0.
- [ ] FSRS-7 parity fixtures pass against the pinned reference vectors.
- [ ] FSRS-7 optimizer objective and positional recency-weighting tests pass.
- [ ] Time-series evaluation tests pass without future leakage.
- [ ] Simulation, forecast, and retention regression tests pass.
- [ ] Multi-engine fixture tests pass while the production registry exposes only published engines.
- [ ] Property/fuzz smoke coverage has no panic, NaN, infinity, negative interval, or invalid transition regression.

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

## Content, clients, and hosted boundary

- [ ] JSON v2 export/import round trips logical notes and keeps JSON v1 import compatibility.
- [ ] `.nut` v2 export/import round trips logical notes and keeps `.nut` v1 import compatibility.
- [ ] Built-in note generation remains stable for basic, reverse, cloze, type-answer, multiple-choice, multiple-select, ordering, and image-occlusion.
- [ ] `.sack` media hashes are verified and content-addressed media survives export/import.
- [ ] `deez web` local browser serving and media delivery smoke tests pass.
- [ ] `deez serve` local API remains loopback-first and its API smoke coverage passes.
- [ ] Hosted auth/session/ownership tests pass without changing the account-free local mode.
- [ ] The packaged macOS archives contain the Deez binary and pinned Deez Web assets.

## Data safety

- [ ] Existing deck scheduler majors do not silently change.
- [ ] Unsupported engines fail explicitly.
- [ ] Parameter activation is explicit and previous parameter sets remain available.
- [ ] Scheduler migration preview is side-effect free.
- [ ] Failed migrations/restores leave source history unchanged.
- [ ] Generated-card retirement preserves immutable review history when note edits remove variants.
- [ ] Backup/restore and recovery documentation matches tested behavior.

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
- [ ] `deez fsrs optimize --recency` matches current positional recency behavior.
- [ ] Help output matches supported CLI syntax.
- [ ] Stats/inspect human and JSON output work.
- [ ] Backup/recovery/migration docs are discoverable.

## Exact-SHA GitHub release matrix

The release candidate SHA must have successful runs for all three push workflows:

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

Do not promote a branch merely because an earlier PR head was green. Re-run/verify these workflows after the release changes have landed on `dev`, and use that exact successful `dev` commit as the commit promoted to `main`.

## Required local-equivalent commands

The GitHub matrix is authoritative for services and runner-specific checks. The equivalent core commands are:

```bash
zig fmt --check build.zig src test
zig build
zig build test
zig build benchmark -Doptimize=ReleaseFast
zig build mongo-integration-test
```

The Mongo integration command requires the documented Mongo fixtures/CI environment.

## Publication and Homebrew consumption

After the exact green release SHA is fast-forwarded from `dev` to `main`:

- [ ] `VERSION` is exactly `0.2.0-rc.4.2`.
- [ ] The release workflow creates annotated tag `v0.2.0-rc.4.2` on that exact SHA.
- [ ] Apple Silicon and Intel macOS archives are published with `SHA256SUMS`.
- [ ] The Homebrew formula on `main` is updated to the published tag and checksums.
- [ ] A clean macOS runner taps this repository and installs Deez through Homebrew.
- [ ] The Homebrew-installed binary completes a real SQLite deck → note → study → process restart → study persistence smoke test.

## Compatibility notes for release notes

Release notes must state:

- Deez version: v0.2.0-rc.4.2;
- supported Zig version: 0.16.0 for source builds;
- supported scheduler major(s): FSRS-7;
- MongoDB driver: Bongo v0.6.0 at commit `1c7bdf9eb5b1c63236a432333a6b26d51d1a4ae5`;
- current JSON and `.nut` exports use logical-note version 2 while version 1 imports remain supported;
- MongoDB is the production validation backend while SQLite remains the default local backend;
- review history is immutable source of truth;
- existing deck scheduler major is pinned and never silently migrated;
- FSRS-8 is not claimed until a published implementation passes the full engine definition of done.

## Tagging

Only after this checklist is satisfied:

1. land the release preparation on `dev`;
2. verify the full GitHub release matrix on the exact resulting `dev` SHA;
3. fast-forward `main` to that exact SHA;
4. allow `.github/workflows/release.yml` to create tag `v0.2.0-rc.4.2`, publish the macOS archives/checksums, and update the Homebrew formula;
5. require the Homebrew consumption smoke to pass before calling the release complete.
