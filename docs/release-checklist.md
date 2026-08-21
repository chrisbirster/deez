# First release gate

Do not create the first Deez release tag until every required item below is checked on the final release commit.

## Scheduler correctness

- [ ] `zig build test` passes on Zig 0.16.0.
- [ ] FSRS-7 parity fixtures pass against the pinned reference vectors.
- [ ] FSRS-7 optimizer objective and recency weighting tests pass.
- [ ] Time-series evaluation tests pass without future leakage.
- [ ] Multi-engine fixture tests pass while production registry exposes only published engines.
- [ ] Property/fuzz smoke tests pass with no panic, NaN, infinity, negative interval, or invalid transition regression.

## MongoDB / Bongo

- [ ] Deez uses the frozen Bongo v0.3.0 package hash.
- [ ] Live replica-set integration suite passes.
- [ ] Standalone fallback integration suite passes.
- [ ] TLS/authentication/error propagation coverage passes.
- [ ] Transactional review append/state update passes.
- [ ] Reconnect persistence passes.
- [ ] Scheduler pinning and immutable parameter-set tests pass.
- [ ] Logical archive dry-run/restore passes.
- [ ] Recovery rebuild preserves immutable review history.
- [ ] Anki-to-Store migration is validated with MongoDB as destination.

## Data safety

- [ ] Existing deck scheduler majors do not silently change.
- [ ] Unsupported engines fail explicitly.
- [ ] Parameter activation is explicit and previous parameter sets remain available.
- [ ] Failed migrations/restores leave source history unchanged.
- [ ] Backup/restore documentation matches tested behavior.

## Performance

- [ ] Scheduling benchmark recorded.
- [ ] Long-history replay benchmark recorded.
- [ ] Mongo due-queue benchmark recorded.
- [ ] Optimization benchmark recorded.
- [ ] Representative import/restore benchmark recorded.
- [ ] Baseline hardware, dataset size, Zig mode, Mongo version, and Bongo version are recorded.
- [ ] Any CI regression thresholds are deterministic enough not to be runner-noise gates.

## User experience

- [ ] README installation/build instructions work from a clean checkout.
- [ ] MongoDB environment examples work.
- [ ] First deck/card/study workflow works.
- [ ] Help output matches supported CLI syntax.
- [ ] Stats/inspect human and JSON output work.
- [ ] Backup/recovery/migration docs are discoverable.

## Compatibility notes for release notes

Release notes must state:

- supported Zig version: 0.16.0;
- supported scheduler major(s): FSRS-7;
- Bongo dependency: frozen v0.3.0 package;
- review history is immutable source of truth;
- existing deck scheduler major is pinned and never silently migrated;
- FSRS-8 is not claimed until a published implementation passes the full engine definition of done.

## Tagging

Only after this checklist is satisfied:

1. merge the release PR;
2. verify the exact merge commit with the final validation commands;
3. create the first semantic version tag on that commit;
4. publish release notes containing the compatibility guarantees above.
