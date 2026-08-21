# Performance benchmarks

Deez ships an opt-in benchmark harness. Wall-clock measurements are not release CI pass/fail gates because shared-runner timing noise is too large; correctness remains a hard gate.

## Run CPU workloads

Use a release-optimized build when recording a baseline:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

The harness reports nanoseconds for:

- scheduling 100 times against a 1,000-review history;
- replaying a 1,000-review history 100 times;
- one optimizer epoch over 79 scoreable reviews;
- dry-running a 1,000-card interchange archive 100 times.

## Run MongoDB/Bongo workload

Use a dedicated disposable MongoDB database and set:

```bash
export DEEZ_MONGO_BENCH_URI='mongodb://localhost:27017/deez_benchmark'
zig build benchmark -Doptimize=ReleaseFast
```

The Mongo workload creates 1,000 cards and measures 25 deterministic due-queue reads through the same `storage.Store` → `MongoStore` → frozen Bongo v0.3.0 path used by Deez.

Do not point the benchmark at a real Deez study database.

## Baseline record

For every release baseline record:

```text
Deez commit:
Zig version:
Optimization mode:
OS:
CPU:
Memory:
MongoDB version:
Bongo package/commit:

schedule_100_long_history_ns=
replay_100x_1000_reviews_ns=
optimize_79_examples_1_epoch_ns=
archive_dry_run_100x_1000_cards_ns=
mongo_due_queue_25x_1000_cards_ns=
```

## Regression policy

Correctness regressions always fail release validation. Performance numbers are compared against the previous baseline using the same workload and comparable hardware.

Until enough stable baselines exist, a wall-clock slowdown is a review signal rather than an automatic CI failure. A future automated threshold should only be introduced for a workload whose repeated variance is small enough that the threshold is meaningfully larger than normal machine noise.
