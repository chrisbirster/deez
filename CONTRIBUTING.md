# Contributing to Deez

## Core invariant

Deez owns immutable review history. Scheduler engines interpret that history; they do not own it.

A change is not acceptable if it requires rewriting historical reviews just to fit a scheduler implementation.

## Architecture

- `src/fsrs/` — version-independent scheduler interfaces, registry, comparison, migration
- `src/fsrs/v7/` — FSRS-7 model, scheduler, optimizer, evaluator, simulation, forecasting, retention
- `src/storage/` — operation-oriented persistence boundary
- `src/storage/mongodb.zig` — Mongo-native persistence through Bongo
- `src/study.zig` — study/replay/session orchestration
- `src/interchange_mongodb.zig` — Mongo logical backup/restore
- `src/import/` — external-history importers
- `src/cli.zig` / `src/app.zig` — terminal interface

Storage APIs are operation-oriented. Do not add a fake generic SQL/Mongo query layer merely to make the backends look identical.

## MongoDB/Bongo

Bongo v0.4.0 is the pinned external MongoDB dependency. Deez currently pins commit `8184b6266bab78fd3eb7fd8d2318f79f90e51937` and must use Bongo's public APIs rather than reaching into Bongo internals.

New persistence behavior should be exercised against the MongoDB integration fixture when it affects production data. Replica-set transaction behavior and standalone fallback behavior are intentionally different and must remain explicit.

Do not track an unreleased Bongo branch from Deez. A Bongo upgrade should be a deliberate dependency change with a consumer-boundary test run and a documented pin/hash.

## FSRS parity

Changes to FSRS equations, defaults, interval behavior, optimizer loss, evaluator semantics, or retention methodology require an authoritative upstream reference and regression fixtures.

Do not copy stability/difficulty directly across scheduler major versions. Reconstruct target state by replaying immutable history under the target engine.

## Adding a scheduler major

A new scheduler major must:

1. have a published authoritative specification/reference implementation;
2. implement the version-independent engine interface;
3. be registered by algorithm family/major;
4. coexist with FSRS-7 in the same build/database;
5. replay immutable Deez history;
6. provide compatibility/parity fixtures;
7. define optimizer/evaluator/simulator support or report unsupported capabilities explicitly;
8. provide explicit migration preview/activation behavior.

The test-only fixture engine is only proof that dispatch is genuinely multi-engine. It is not a published FSRS version and must never be exposed as FSRS-8.

## Tests

Before submitting changes:

```bash
zig fmt --check build.zig src test
zig build
zig build test
```

For Mongo/storage changes also run the Mongo fixture suite:

```bash
zig build mongo-integration-test
```

Property/fuzz regressions should retain a deterministic seed or fixed regression case. Longer fuzz campaigns may be run with:

```bash
zig build test --fuzz
```

Performance-sensitive changes should record the benchmark harness before and after on comparable hardware:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

Set `DEEZ_MONGO_BENCH_URI` when the change can affect Mongo due-queue performance.

## Pull requests

Keep changes scoped to a coherent requirement. Describe the behavior and validation performed. Do not weaken correctness checks to satisfy performance targets.
