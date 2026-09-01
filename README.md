# DEEZ

**Drill, Evaluate, Encode, Zen.**

Deez is a terminal-first spaced-repetition system written in Zig. It uses FSRS for scheduling and keeps immutable review history as the source of truth so scheduler state can be rebuilt, compared, optimized, and migrated safely.

## Status

- Zig: **0.16.0** for development/builds
- Scheduler: **FSRS-7**
- MongoDB driver: **Bongo v0.6.0**, pinned to commit `1c7bdf9eb5b1c63236a432333a6b26d51d1a4ae5`
- Storage: **SQLite** or **MongoDB**
- FSRS-8: not implemented until a published specification/reference implementation exists

## Install on macOS

Tagged releases publish prebuilt Apple Silicon and Intel macOS binaries. End users do **not** need Zig installed.

Deez uses this repository as a Homebrew tap, so add it with the explicit repository URL and install the formula:

```bash
brew tap chrisbirster/deez https://github.com/chrisbirster/deez
brew install chrisbirster/deez/deez
```

Afterward:

```bash
deez --help
```

To upgrade later:

```bash
brew update
brew upgrade deez
```

## First-run storage setup

The first command that needs persistent storage asks which backend to use:

```text
Deez storage [sqlite/mongodb] (sqlite):
```

Press **Enter** for the default. Deez creates:

```text
~/.local/share/deez/deez.db
```

The selection is saved under:

```text
~/.config/deez/config
```

Choose `mongodb` to configure a MongoDB URI instead. Run this at any time to change the saved backend:

```bash
deez setup
```

Environment variables remain available for automation and temporary overrides:

```bash
# SQLite override
export DEEZ_STORAGE=sqlite
export DEEZ_DB="$HOME/.local/share/deez/deez.db"

# MongoDB override
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'
```

For MongoDB review writes, a replica set is preferred because Bongo can use transactions to append the immutable review and update derived scheduler state atomically. On standalone MongoDB, Deez writes the review first and treats scheduler state as rebuildable cache.

## How decks are organized

A **deck** is the top-level study container. Each card belongs to exactly one deck. Deez stores the deck and cards in whichever backend you selected; the user-facing commands are the same for SQLite and MongoDB.

```bash
deez deck add zig
deez card add 1 'What is BSON?' 'Binary JSON'
deez card add 1 'What is Zig?' 'A systems programming language'
deez decks
deez cards 1
deez study 1
```

And, because this project is called Deez:

```bash
deez nuts
```

`deez nuts` is a real alias of `deez decks`; it lists the same persisted deck records.

Study ratings are:

```text
1 Again
2 Hard
3 Good
4 Easy
```

Session policy can be configured without changing persisted review history:

```bash
deez study 1 --new-limit 10
deez study 1 --order reviews-first
deez study 1 --order new-first
deez study 1 --shuffle
```

## Shareable deck files

Deez supports two content-only deck formats: normal `.json` and native `.nut` files. Current exports use logical-note **version 2** for both formats. Legacy version 1 card-only files remain import-compatible. Both formats can be imported into either SQLite or MongoDB and intentionally exclude personal review history and FSRS state.

### JSON

A JSON deck is one document. Version 2 stores logical notes instead of generated cards:

```json
{
  "format": "deez.deck",
  "version": 2,
  "deck": {
    "name": "Zig Basics",
    "notes": [
      {
        "note_type": "basic",
        "fields": ["What is Zig?", "A systems programming language"],
        "tags_json": "[]"
      },
      {
        "note_type": "cloze",
        "fields": ["Zig uses {{c1::explicit allocators}}.", "Memory"],
        "tags_json": "[]"
      }
    ]
  }
}
```

Generated study cards are rebuilt from each note type during import, so the file does not become a second source of truth for rendered cards or scheduling state.

Export and import:

```bash
deez deck export 1 > zig-basics.json
deez deck import zig-basics.json
```

### `.nut`

`.nut` is Deez's native human-readable, line-oriented format. Version 2 is NDJSON: the first non-empty record is the deck header and each following record is one **logical note**.

```text
{"kind":"deck","format":"deez.nut","version":2,"name":"Zig Basics"}
{"kind":"note","note_type":"basic","fields":["What is Zig?","A systems programming language"],"tags_json":"[]"}
{"kind":"note","note_type":"cloze","fields":["Zig uses {{c1::explicit allocators}}.","Memory"],"tags_json":"[]"}
```

A reverse note is likewise stored once as a logical note even though it generates two study cards:

```text
{"kind":"note","note_type":"basic-reverse","fields":["Capital of France","Paris"],"tags_json":"[]"}
```

Generated cards are recreated from the note type and templates during import. Stable generated-card semantics therefore survive round trips without embedding another user's due dates, stability, difficulty, review history, or scheduler cache.

Export and import:

```bash
deez nut export 1 > zig-basics.nut
deez nut import zig-basics.nut
```

The normal deck importer also recognizes the `.nut` extension:

```bash
deez deck import zig-basics.nut
```

Version 2 supports Deez's built-in logical note types, including basic, reverse, cloze, type-answer, multiple-choice, multiple-select, ordering, and image-occlusion. Version 1 card-based `.nut` files remain import-compatible.

Import always creates a new deck in the currently configured database, whether that database is SQLite or MongoDB.

Shared deck files are intentionally **content-only**. They do not contain the previous user's review history, due dates, stability, difficulty, or other personal FSRS state. A downloaded deck therefore starts fresh for the person importing it.

Use Deez backup/restore—not JSON or `.nut`—when you need a full-fidelity copy of your own study data and scheduler history.

See `docs/nut-format.md` for the `.nut` format contract and `docs/interactions.md` for the structured interactive note fields.

## Inspect and stats

```bash
deez stats
deez stats --json
deez inspect 1
deez inspect 1 --json
deez scheduler list
```

## FSRS-7

Deez pins each deck to an explicit scheduler major and parameter set. Existing decks do not silently move to a different scheduler major when Deez is upgraded.

FSRS-7 scheduling parity is checked against the Open Spaced Repetition reference implementation. The current model uses 35 parameters.

Optimization consumes immutable review history. Standard fitting is unweighted. Recency-weighted fitting follows the current srs-benchmark positional weighting:

```text
x = linspace(0, 1, N)
weight = 0.25 + 0.75 * x^3
```

Enable it explicitly with:

```bash
deez fsrs optimize --recency
```

See `docs/optimizer.md`.

## Data model and safety

The core rule is:

> Deez owns the review history. Scheduler versions are replaceable engines that interpret that history.

Review events are append-only source data. Stability, difficulty, due time, and other scheduler state are derived data. Deez can rebuild derived state by replaying immutable history.

MongoDB collections include decks, cards, reviews, parameter sets, scheduler defaults/groups, and counters. Review documents retain the scheduler major, implementation version, and exact parameter-set identity used for that review.

## Backup and restore

The Deez logical archive preserves full personal study state, including:

- deck/card IDs and content
- immutable review timestamps/order/ratings
- review scheduler stamps
- FSRS parameter identities and weights
- scheduler defaults and deck/group pins
- ID counters

This is deliberately different from shareable deck files. JSON and `.nut` are for sharing deck content; backup/restore is for preserving a user's database and review history.

See `docs/interchange.md` and `docs/mongodb.md`.

## Anki migration

Anki collection files are SQLite databases, so SQLite is used to read the Anki source file. The destination importer writes through Deez's `storage.Store`, allowing imported data to target the configured persistence implementation while FSRS state is reconstructed from review history rather than copied blindly.

## Development

Zig is required only when developing or building Deez from source:

```bash
zig build
zig build test
```

The binary is written to:

```text
./zig-out/bin/deez
```

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

Long fuzz campaigns:

```bash
zig build test --fuzz
```

Performance baselines:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

Set `DEEZ_MONGO_BENCH_URI` to include the Mongo due-queue workload. See `docs/benchmarks.md`.

## Documentation

- `docs/cli.md` — CLI reference
- `docs/nut-format.md` — native `.nut` NDJSON deck format
- `docs/interactions.md` — structured interactive note/card contract
- `docs/fsrs-7-parity.md` — FSRS-7 reference/parity policy
- `docs/optimizer.md` — optimization and evaluation methodology
- `docs/interchange.md` — full-fidelity interchange format and migration safety
- `docs/mongodb.md` — MongoDB/Bongo persistence and recovery
- `docs/benchmarks.md` — benchmark workloads and regression policy
- `docs/fsrs-8-checklist.md` — requirements for a future published FSRS-8
- `docs/release-checklist.md` — release gate
- `CONTRIBUTING.md` — contributor architecture and testing rules

## License

MIT. See `LICENSE`.
