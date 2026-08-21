# DEEZ

**Drill, Evaluate, Encode, Zen.**

Deez is a terminal-first spaced-repetition system written in Zig. It uses FSRS for scheduling and keeps immutable review history as the source of truth so scheduler state can be rebuilt, compared, optimized, and migrated safely.

## Status

- Zig: **0.16.0**
- Scheduler: **FSRS-7**
- MongoDB driver: **Bongo v0.3.0**, pinned and frozen
- Primary persistence path for production validation: **MongoDB**
- FSRS-8: not implemented until a published specification/reference implementation exists

## Build

```bash
zig build
zig build test
```

The binary is written to:

```text
./zig-out/bin/deez
```

## MongoDB setup

Deez selects MongoDB with `DEEZ_STORAGE=mongodb` and requires a MongoDB URI in `DEEZ_MONGO_URI`.

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'

./zig-out/bin/deez decks
```

For review writes, a replica set is preferred because Bongo can use MongoDB transactions to append the immutable review and update derived scheduler state atomically. On standalone MongoDB, Deez writes the review first and treats scheduler state as rebuildable cache.

## First deck

```bash
./zig-out/bin/deez deck add zig
./zig-out/bin/deez card add 1 'What is BSON?' 'Binary JSON'
./zig-out/bin/deez card add 1 'What is Zig?' 'A systems programming language'
./zig-out/bin/deez cards 1
./zig-out/bin/deez study 1
```

Study ratings are:

```text
1 Again
2 Hard
3 Good
4 Easy
```

Session policy can be configured without changing the persisted review history:

```bash
./zig-out/bin/deez study 1 --new-limit 10
./zig-out/bin/deez study 1 --order reviews-first
./zig-out/bin/deez study 1 --order new-first
./zig-out/bin/deez study 1 --shuffle
```

## Inspect and stats

```bash
./zig-out/bin/deez stats
./zig-out/bin/deez stats --json
./zig-out/bin/deez inspect 1
./zig-out/bin/deez inspect 1 --json
./zig-out/bin/deez scheduler list
```

## FSRS-7

Deez pins each deck to an explicit scheduler major and parameter set. Existing decks do not silently move to a different scheduler major when Deez is upgraded.

FSRS-7 scheduling parity is checked against the Open Spaced Repetition reference implementation. The current model uses 35 parameters.

Optimization consumes immutable review history. Standard fitting is unweighted. Recency-weighted fitting follows the current srs-benchmark positional weighting:

```text
x = linspace(0, 1, N)
weight = 0.25 + 0.75 * x^3
```

The newest training examples therefore receive more weight, while the oldest receive 0.25. See `docs/optimizer.md`.

## Data model and safety

The core rule is:

> Deez owns the review history. Scheduler versions are replaceable engines that interpret that history.

Review events are append-only source data. Stability, difficulty, due time, and other scheduler state are derived data. Deez can rebuild derived state by replaying immutable history.

MongoDB collections include decks, cards, reviews, parameter sets, scheduler defaults/groups, and counters. Review documents retain the scheduler major, implementation version, and exact parameter-set identity used for that review.

## Backup and restore

The MongoDB Deez archive is a logical application-level backup. It preserves:

- deck/card IDs and content
- immutable review timestamps/order/ratings
- review scheduler stamps
- FSRS parameter identities and weights
- scheduler defaults and deck/group pins
- ID counters

Restore validates the archive before mutation, requires an empty Mongo destination, writes source-of-truth records transactionally when transactions are available, and rebuilds derived scheduler state afterward.

See `docs/interchange.md` and `docs/mongodb.md`.

## Anki migration

Anki collection files are SQLite databases, so SQLite is used only to read the Anki source file. The destination importer writes through Deez's `storage.Store`, which allows imported decks and review history to go directly into MongoDB/Bongo. FSRS state is reconstructed from the imported review sequence instead of copying incompatible Anki scheduler state.

## Development validation

Normal validation:

```bash
zig fmt --check build.zig src test
zig build
zig build test
```

MongoDB/Bongo acceptance:

```bash
zig build mongo-integration-test
```

The GitHub Mongo workflow starts replica-set, standalone, and TLS fixtures and tests against the exact frozen Bongo v0.3.0 package.

Long fuzz campaigns can be run separately from the deterministic CI tier:

```bash
zig build test --fuzz
```

## Documentation

- `docs/cli.md` — CLI reference
- `docs/fsrs-7-parity.md` — FSRS-7 reference/parity policy
- `docs/optimizer.md` — optimization and evaluation methodology
- `docs/interchange.md` — interchange format and migration safety
- `docs/mongodb.md` — MongoDB/Bongo persistence and recovery
- `docs/fsrs-8-checklist.md` — requirements for a future published FSRS-8
- `CONTRIBUTING.md` — contributor architecture and testing rules

## License

See the repository license file if present. No license terms are implied by this README.
