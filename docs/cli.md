# Deez CLI

Deez is terminal-first. Command parsing is separate from storage/scheduler behavior so the same domain rules apply to MongoDB and other supported backends.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully, including help output. |
| `2` | CLI usage error such as an unknown command, invalid arguments, invalid IDs/numbers, or a missing required `--yes` confirmation. |
| nonzero other than `2` | Runtime/storage/scheduler failure propagated by the executable. |

Examples:

```sh
./zig-out/bin/deez --help
printf '%s\n' "$?"   # 0

./zig-out/bin/deez wat
printf '%s\n' "$?"   # 2
```

## Deck and card commands

```text
deez decks
deez cards <deck-id>
deez deck add <name>
deez deck rename <deck-id> <name>
deez deck delete <deck-id> --yes
deez card add <deck-id> <question> <answer>
deez card edit <card-id> <question> <answer>
deez card delete <card-id> --yes
```

Destructive operations require explicit `--yes` intent.

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

## FSRS

```text
deez fsrs optimize [deck-id] [--recency]
deez fsrs evaluate [deck-id]
deez fsrs simulate [--retention <0..1>]
deez fsrs retention
```

`--recency` is opt-in and uses the documented current FSRS benchmark positional weighting. It is not a time half-life flag. See `docs/optimizer.md`.

## MongoDB environment

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'
```

When MongoDB is explicitly selected, startup/operation errors are surfaced rather than silently switching storage backends.

## Help

```text
deez help
deez help deck
deez help card
deez help study
deez help stats
deez help inspect
deez help fsrs
deez help scheduler
```

CLI parsing lives in `src/cli.zig`; storage and scheduling behavior live behind the application/domain APIs rather than in the parser.
