# Deez CLI

Deez is terminal-first. Command parsing is separate from storage/scheduler behavior so the same domain rules apply to SQLite and MongoDB.

## Storage setup

The first storage-backed command prompts for a backend when no saved configuration or explicit environment override exists:

```text
Deez storage [sqlite/mongodb] (sqlite):
```

An empty response selects SQLite and creates the database at:

```text
~/.local/share/deez/deez.db
```

The selected backend is persisted in `~/.config/deez/config`. Re-run the setup prompt at any time with:

```text
deez setup
```

Environment variables override saved configuration:

```bash
export DEEZ_STORAGE=sqlite
export DEEZ_DB="$HOME/.local/share/deez/deez.db"
```

or:

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'
```

Help output does not require or initialize a database.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully, including help output. |
| `2` | CLI usage error such as an unknown command, invalid arguments, invalid IDs/numbers, or a missing required `--yes` confirmation. |
| nonzero other than `2` | Runtime/storage/scheduler failure propagated by the executable. |

Examples:

```sh
deez --help
printf '%s\n' "$?"   # 0

deez wat
printf '%s\n' "$?"   # 2
```

## Deck and card commands

```text
deez decks
deez nuts
deez cards <deck-id>
deez deck add <name>
deez deck rename <deck-id> <name>
deez deck delete <deck-id> --yes
deez deck export <deck-id> > deck.json
deez deck import <deck.json|deck.nut>
deez nut export <deck-id> > deck.nut
deez nut import <deck.nut>
deez card add <deck-id> <question> <answer>
deez card edit <card-id> <question> <answer>
deez card delete <card-id> --yes
```

A deck is the top-level content container. Cards belong to exactly one deck. `deez nuts` is intentionally an alias of `deez decks`; it does not introduce a second persisted entity. Destructive operations require explicit `--yes` intent.

## Guided note authoring

For normal terminal authoring, use the guided flow:

```text
deez add
deez add <deck-id>
deez note add
deez note add <deck-id>
```

The flow selects a deck, asks for a note type, collects type-specific fields, previews the generated cards, and asks for confirmation before saving. It works through the same `storage.Store` abstraction for SQLite and MongoDB.

Current authorable built-in note types are:

```text
basic
reverse
cloze
type-answer
multiple-choice
multiple-select
ordering
image-occlusion
```

Cloze text is entered using the native syntax directly:

```text
A replica set has one {{c1::primary}}, multiple {{c1::secondary}} members,
and may contain an {{c2::arbiter}}.
```

Matching cloze numbers hide together on the same card. Different numbers create separate cards.

Multiple-choice and multiple-select authoring prompts for readable `A`, `B`, `C` choices and stores the structured choice data internally. Ordering prompts for items in canonical order. Image occlusion currently accepts an existing Deez media reference plus masks JSON.

The deterministic scripting form is still available:

```text
deez note add <deck-id> <note-type> <fields...>
```

`optional-reverse` is retained only as a legacy stored-data/interchange note type. New Deez clients do not author it, and stable note-type ID `3` is reserved for backward compatibility.

## Guided note editing

Use the guided editor for generated cards:

```text
deez edit
deez edit <deck-id>
deez edit <deck-id> <note-id>
deez note edit
deez note edit <deck-id>
deez note edit <deck-id> <note-id>
```

The flow is deck -> logical note -> fields -> generated-card preview -> confirmation -> save. Existing values are shown before each prompt. Press Enter to keep a value; for optional text fields, enter `-` to clear it.

Guided saves use Deez's lifecycle-safe note mutation path, so generated variants that disappear after an edit are retired rather than having their immutable review history discarded.

The deterministic scripting form remains:

```text
deez note edit <deck-id> <note-id> <fields...>
```

For cards created directly with `deez card add`, use `deez card edit`. For cards generated from logical notes, edit the note rather than the physical generated card.

### Shareable JSON decks

`deck export` writes a portable content-only JSON document. Current version 2 stores logical notes; version 1 card-only files remain importable.

Example round trip:

```bash
deez deck export 1 > zig-basics.json
deez deck import zig-basics.json
```

Import creates a new deck in the currently configured backend. The same JSON file can therefore be loaded into SQLite or MongoDB without changing the file.

### Native `.nut` decks

`.nut` is Deez's native shareable deck format. Version 2 is NDJSON: one deck header followed by logical-note records.

```text
{"kind":"deck","format":"deez.nut","version":2,"name":"Zig Basics"}
{"kind":"note","note_type":"basic","fields":["What is Zig?","A systems programming language"],"tags_json":"[]"}
{"kind":"note","note_type":"cloze","fields":["Zig uses {{c1::explicit allocators}}.","Memory"],"tags_json":"[]"}
```

Export and import with:

```bash
deez nut export 1 > zig-basics.nut
deez nut import zig-basics.nut
```

The general deck importer also recognizes `.nut` by extension:

```bash
deez deck import zig-basics.nut
```

Version 1 card-only `.nut` files remain importable. Version 2 files containing the historical `optional-reverse` note type also remain readable; that compatibility does not expose the type for new authoring.

JSON deck files and `.nut` files intentionally exclude personal review history, scheduler state, due dates, difficulty, stability, and parameter-set identity. A downloaded deck starts fresh for its importer. Use backup/restore for full-fidelity personal data migration.

See `docs/nut-format.md` for the `.nut` versioning and validation rules.

## Study

```text
deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
```

The default is deterministic due-timestamp order with no explicit new-card limit and no shuffle. `--new-limit` applies to that invocation/session; it is not a persisted daily cap. Relearning cards can re-enter the same session when their scheduler timestamp becomes due.

## Stats and inspection

```text
deez stats [deck-id] [--period all|today|week|month|year] [--json]
deez inspect <card-id> [--json]
deez scheduler list
```

Historical periods use UTC day boundaries. The stats output retains the existing deck/card/due/review totals and adds review-history metrics for the selected period:

- review count
- unique cards reviewed
- new cards introduced
- Again / Hard / Good / Easy counts
- observed recall rate
- days studied
- current streak
- longest streak

The history calculation consumes Deez's immutable review-history contract and therefore has the same semantics for SQLite and MongoDB. SQLite and MongoDB both maintain a time-first review analytics index in addition to the existing card-first history index used for scheduler replay.

`--json` is the machine-readable form for stats and card inspection.

## Backup and restore

The existing logical archive is separate from shareable JSON and `.nut` decks. It is intended to preserve a user's complete study data and scheduler metadata.

MongoDB backups are pipe-friendly:

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'

deez backup > deez.backup
deez backup 42 > deck-42.backup

deez restore --dry-run < deez.backup
deez restore --yes < deez.backup
```

`backup` without a deck ID exports all Deez data. Supplying a deck ID exports that deck and its cards/reviews together with the scheduler metadata required to interpret them.

`restore --dry-run` validates and reports archive counts without connecting to MongoDB or mutating persistent data. Actual restore requires `--yes`, requires the MongoDB backend, and refuses a non-empty destination rather than silently merging or overwriting existing Deez data. Source-of-truth records are restored transactionally on a replica set and derived scheduler state is rebuilt from immutable review history after the transaction commits.

Archive input is limited to 256 MiB per invocation so malformed or accidentally redirected unbounded input cannot consume arbitrary memory.

## FSRS

```text
deez fsrs optimize [deck-id] [--recency]
deez fsrs evaluate [deck-id]
deez fsrs simulate [--retention <0..1>]
deez fsrs retention
```

The evaluator exposes scheduler-neutral metric types (log loss, Brier score, RMSE, predicted/observed recall, and calibration) so future scheduler majors can be compared against the same immutable history contract without changing stored reviews.

`--recency` is opt-in and uses the documented current FSRS benchmark positional weighting. It is not a time half-life flag. See `docs/optimizer.md`.

## Help

```text
deez --help
deez help
deez help deck
deez help nut
deez help note
deez help card
deez help study
deez help stats
deez help inspect
deez help fsrs
deez help scheduler
deez backup --help
deez restore --help
```

The declarative scripted command tree lives in `src/cli_tree.zig` and uses Thrawn for command resolution, options, and argument validation. The short interactive authoring/editing and historical-stats entry points are routed before that tree because they own terminal interaction rather than deterministic command parsing. `src/cli.zig` retains the Deez domain command union and stable help contract consumed by `src/app.zig`. Storage and scheduling behavior remain behind Deez domain APIs rather than in the CLI framework.
