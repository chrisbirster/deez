# Deez `.nut` deck format

`.nut` is the native shareable deck format for Deez.

It is **NDJSON** (newline-delimited JSON): every non-empty line is one complete JSON object. The `.nut` extension identifies the file as a Deez deck, but each record remains ordinary JSON so the format is easy to inspect, generate, diff, and stream.

## Version 1

The first non-empty record must describe the deck:

```json
{"kind":"deck","format":"deez.nut","version":1,"name":"Zig Basics"}
```

Every following record is a card:

```json
{"kind":"card","question":"What is Zig?","answer":"A systems programming language"}
{"kind":"card","question":"What is comptime?","answer":"Compile-time execution"}
```

A complete file therefore looks like:

```text
{"kind":"deck","format":"deez.nut","version":1,"name":"Zig Basics"}
{"kind":"card","question":"What is Zig?","answer":"A systems programming language"}
{"kind":"card","question":"What is comptime?","answer":"Compile-time execution"}
```

Blank lines are ignored. Comments are not supported because every non-empty line must remain valid JSON.

## Commands

List stored decks using the intentionally ridiculous alias:

```bash
deez nuts
```

Export one stored deck as `.nut`:

```bash
deez nut export 1 > zig-basics.nut
```

Import a `.nut` deck:

```bash
deez nut import zig-basics.nut
```

The general deck importer also recognizes the `.nut` extension:

```bash
deez deck import zig-basics.nut
```

`deez nuts` and `deez decks` list the same persisted decks. A nut is not a second database entity; `.nut` is the portable file representation of a deck.

## Data-safety boundary

`.nut` files are intentionally **content-only**. They contain the deck name and cards, but not personal review history, due dates, stability, difficulty, scheduler cache, or FSRS parameter state.

This means a deck downloaded from someone else starts with fresh study history after import. Use Deez backup/restore when the goal is to migrate your own complete database and immutable review history.

## Compatibility rules

- `format` must be `deez.nut`.
- `version` must currently be `1`.
- The deck record must appear before any card records.
- A file may contain exactly one deck record.
- Unknown record kinds are rejected rather than silently ignored.
- Empty deck names, questions, and answers are rejected.

The line-oriented layout leaves room for future record kinds without requiring one giant JSON document or loading the entire logical deck structure into memory at once.
