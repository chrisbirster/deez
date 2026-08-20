# Deez CLI

Deez returns stable process exit codes so shell scripts can distinguish usage problems from successful commands.

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

CLI parsing lives in `src/cli.zig`; storage and scheduling behavior live behind the application/domain APIs rather than in the parser.
