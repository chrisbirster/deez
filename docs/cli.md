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

## Local clients

Deez exposes two loopback-only local client entry points while the Zig process remains authoritative for data and domain behavior.

```text
deez serve [--port <1..65535>]
deez web [--port <1..65535>] [--no-open]
```

`deez serve` exposes the versioned local client API on `127.0.0.1` (default port `5882`). `deez web` serves the browser UI and its local API surface on loopback. Neither command turns the browser or another client into a second data authority.

See `docs/client-architecture.md` for the client/API boundary.

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
deez note add <deck-id> <note-type> <fields...>
deez note edit <deck-id> <note-id> <fields...>
deez card add <deck-id> <question> <answer>
deez card edit <card-id> <question> <answer>
deez card delete <card-id> --yes
```

A deck is the top-level content container. Cards belong to exactly one deck. `deez nuts` is intentionally an alias of `deez decks`; it does not introduce a second persisted entity. Destructive operations require explicit `--yes` intent.

### Shareable JSON decks

`deck export` writes a portable content-only JSON document. Import creates a new deck and generated study cards in the currently configured backend. The same JSON file can therefore be loaded into SQLite or MongoDB without changing the file.

### Native `.nut` decks

`.nut` is Deez's native human-readable shareable deck format. Version 2 is NDJSON: one complete JSON object per non-empty line, with logical notes rather than generated cards.

```text
{"kind":"deck","format":"deez.nut","version":2,"name":"Zig Basics"}
{"kind":"note","note_type":"basic","fields":["What is Zig?","A systems programming language"],"tags_json":"[]"}
{"kind":"note","note_type":"reverse","fields":["Capital of France","Paris"],"tags_json":"[]"}
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

Generated cards are rebuilt from the logical note type and templates during import. `.nut` files intentionally exclude personal review history, scheduler state, due dates, difficulty, stability, and parameter-set identity. A downloaded deck starts fresh for its importer. Use backup/restore for full-fidelity personal data migration.

See `docs/nut-format.md` for the `.nut` versioning, built-in note types, media references, and validation rules.

## Study

```text
deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
```

The default is deterministic due-timestamp order with no explicit new-card limit and no shuffle. Relearning cards can re-enter the same session when their scheduler timestamp becomes due.

## Stats and inspection

```text
deez stats [deck-id] [--json]
deez inspect <card-id> [--json]
deez scheduler list
```

`--json` is the stable machine-readable form for stats and card inspection.

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

`--recency` is opt-in and uses the documented current FSRS benchmark positional weighting. It is not a time half-life flag. See `docs/optimizer.md`.

## Help

```text
deez --help
deez help
deez help deck
deez help nut
deez help card
deez help study
deez help stats
deez help inspect
deez help fsrs
deez help scheduler
deez backup --help
deez restore --help
```

The declarative command tree and parser live in `src/cli_tree.zig` and use Thrawn for command resolution, options, argument validation, configurable help handling, and owned values that cross the handler boundary. `src/cli.zig` retains the Deez domain command union and stable help contract consumed by `src/app.zig`.

Backup/restore and rich media retain dedicated executors because of their streaming/file-oriented behavior. `deez web` and `deez serve` are application-owned local client entry points. Storage, scheduling, rendering, and client behavior remain behind Deez domain APIs rather than in the CLI framework.
