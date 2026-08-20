# Bongo v0.3.0 integration audit

Deez treats Bongo v0.3.0 as a frozen third-party dependency for the optional MongoDB storage backend. SQLite remains the default backend. MongoDB is selected only with `DEEZ_STORAGE=mongodb` and requires `DEEZ_MONGO_URI`.

## Frozen dependency

Deez is pinned through `build.zig.zon` to Bongo commit:

```text
631bb812777af587162daa650b53f48196960d55
```

The Bongo package at that commit declares version `0.3.0`. Deez must not follow Bongo `dev`, use a sibling `../bongo` package dependency, or depend on functionality added after this commit. The separate Bongo checkout used by MongoDB CI is fixture-only and is pinned to the same commit.

## Dependency path

```text
Deez
  -> storage.Store
  -> MongoStore
  -> Bongo RuntimeClient
  -> MongoDB
```

`storage.Store` is the Deez-owned persistence boundary. It exposes Deez operations such as creating cards, loading review history, querying due cards, and recording review + scheduler state. `MongoStore` is free to implement those operations with MongoDB-native collections, embedded scheduler state, BSON, and MongoDB query operators. The FSRS core does not issue MongoDB operations directly.

## Current Deez operations and Bongo usage

This table records the Bongo v0.3.0 APIs used by the current MongoStore. It is an audit of existing usage; no new Bongo API is introduced by this document.

| Deez operation | Bongo API | Required for Deez | Current test coverage |
|---|---|---:|---|
| connect | `RuntimeClient.connectUri()` | yes | live replica-set integration connects successfully |
| client lifetime | `RuntimeClient.deinit()` | yes | exercised by integration cleanup |
| database selection | `RuntimeClient.databaseName()` | yes | exercised by all MongoStore operations |
| create deck/card/group/parameter/review | `RuntimeClient.insertOne()` | yes | deck/card/review covered; group/parameter indirectly covered by scheduler setup |
| find deck/card/metadata/parameter | `RuntimeClient.findOne()` | yes | parameter/default lookup covered; direct deck/card reload not yet asserted in live test |
| list/query decks/cards/reviews | `RuntimeClient.find()` + runtime cursor `next()`/`deinit()` | yes | due-card and review-history queries covered |
| update deck/card/defaults/scheduler state | `RuntimeClient.updateOne()` | yes | scheduler-state update covered; other update paths mostly unit/compile coverage |
| delete deck/card/review cleanup | `RuntimeClient.deleteOne()` | yes | integration cleanup exercises deck/card/review deletes |
| allocate stable numeric IDs | `RuntimeClient.findOneAndUpdate()` | yes | exercised by every created deck/card/review |
| due-card query | `query.lte()` + `RuntimeClient.find()` | yes | live integration checks due-card result |
| update documents | `query.set()` | yes | live review/state path exercises it |
| increment counters | `query.inc()` | yes | live ID allocation exercises it |
| review history insert | `RuntimeClient.insertOne()` or transaction `insertOne()` | yes | live integration verifies stored history |
| scheduler state update | `RuntimeClient.updateOne()` or transaction `updateOne()` | yes | live integration verifies stored state |
| transaction capability | `RuntimeClient.supports_transactions` | yes | live replica-set test asserts transactions are supported |
| session capability | `RuntimeClient.supports_sessions` | yes for transaction-path validation | live replica-set test asserts sessions are supported |
| transaction start | `RuntimeClient.beginTransaction()` | yes when supported | live replica-set review path uses it |
| transaction review insert | `RuntimeTransaction.insertOne()` | yes when supported | live replica-set review path uses it |
| transaction state update | `RuntimeTransaction.updateOne()` | yes when supported | live replica-set review path uses it |
| transaction commit/lifetime | `RuntimeTransaction.commit()` / `deinit()` | yes when supported | live replica-set review path uses it |
| indexes | `RuntimeClient.createIndex()` | yes | `MongoStore.connect()` creates required indexes; index existence is not yet independently asserted |
| BSON field reads | `bson.Reader.get()` | yes | exercised throughout MongoStore parsing |
| BSON array reads | `bson.Reader.init()` / `next()` | yes | exercised when loading FSRS parameter weights |
| BSON value representation | `bson.Value` variants | yes | exercised by MongoStore parsing helpers |
| binary parameter IDs | `bson.Binary`, `bson.BinarySubtype.generic` | yes | unit test verifies 32-byte representation |

## Direct Bongo symbols Deez currently relies on

The current code directly names these Bongo v0.3.0 symbols:

```text
bongo.RuntimeClient
bongo.RuntimeClient.connectUri
RuntimeClient.deinit
RuntimeClient.databaseName
RuntimeClient.insertOne
RuntimeClient.findOne
RuntimeClient.find
RuntimeClient.updateOne
RuntimeClient.deleteOne
RuntimeClient.findOneAndUpdate
RuntimeClient.createIndex
RuntimeClient.beginTransaction
RuntimeClient.supports_sessions
RuntimeClient.supports_transactions

RuntimeCursor.next
RuntimeCursor.deinit
RuntimeTransaction.insertOne
RuntimeTransaction.updateOne
RuntimeTransaction.commit
RuntimeTransaction.deinit
OwnedDocument.bytes
OwnedDocument.deinit

bongo.query.set
bongo.query.inc
bongo.query.lte

bongo.bson.Reader.get
bongo.bson.Reader.init
bongo.bson.Reader.next
bongo.bson.Value
bongo.bson.Binary
bongo.bson.BinarySubtype.generic
```

One MongoStore update uses MongoDB operator field names directly in a BSON-shaped Zig struct:

```zig
.{
    .@"$unset" = .{ .scheduler_state = "" },
    .@"$set" = .{ .due_at_ms = created_at_ms },
}
```

That is MongoDB document syntax, not access to a Bongo internal module.

## Storage model

MongoStore intentionally does not mirror the SQLite schema one-for-one:

- scheduler state is embedded in each card document;
- `due_at_ms` is duplicated at the card top level so due queries can use a compound index;
- FSRS parameter weights are stored as one BSON array;
- immutable reviews are separate documents and remain the source of truth;
- counters allocate stable numeric Deez IDs.

The required MongoDB indexes created during `MongoStore.connect()` are:

```text
cards:   { deck_id: 1, due_at_ms: 1, _id: 1 }  name=deck_due_id
reviews: { card_id: 1, reviewed_at_ms: 1, _id: 1 }  name=card_history
```

## Review write semantics

When `RuntimeClient.supports_transactions` is true, Deez starts a Bongo transaction, inserts the immutable review, updates the card's derived scheduler state, and commits.

When transactions are unavailable (for example a standalone `mongod`), Deez deliberately uses this order:

1. insert the immutable review;
2. update the derived scheduler state.

The review log is the source of truth. If the second write fails, scheduler state may be stale but can be rebuilt from review history. Deez must never reverse this order or discard a successfully recorded review merely because the derived-state write failed.

## Failure behavior audit

### MongoDB unavailable during startup

`MongoStore.connect()` returns the Bongo connection error. `app.run()` propagates that error. Deez does not fall back to SQLite when `DEEZ_STORAGE=mongodb` was explicitly selected.

### Missing MongoDB URI

When `DEEZ_STORAGE=mongodb` is set without `DEEZ_MONGO_URI`, Deez returns `error.MissingMongoUri`. It does not open SQLite.

### Authentication failure

Authentication is performed by `RuntimeClient.connectUri()`. Deez currently propagates the Bongo error; it does not catch it or switch backends.

### TLS verification failure

TLS setup/verification is owned by `RuntimeClient.connectUri()`. Deez currently propagates the Bongo error; it does not catch it or switch backends.

### Temporary disconnect / operation failure

MongoStore propagates Bongo operation errors through `storage.Store`. Deez does not implement its own hidden reconnect/retry layer and does not reproduce Bongo internals.

### MongoDB unavailable during a review

- Transaction-capable server: a failure before commit leaves the transaction uncommitted/aborted by transaction cleanup.
- Standalone fallback: the immutable review is written before derived scheduler state. A failure on the second write can leave derived state stale, but the review remains available for deterministic state reconstruction.

Deez does not rely on complete retryable writes, complete transaction retry/error-label handling, or full SDAM behavior.

## Bongo v0.3.0 limitations Deez does not require

The current MongoStore does not require or work around these intentionally excluded v0.3.0 areas:

- full SDAM/background topology monitoring;
- complete retryable read/write semantics;
- complete transaction retry/error-label handling;
- all read-preference routing modes;
- MONGODB-X509/mTLS client certificates;
- OP_COMPRESSED;
- complete SASLprep.

If a future Deez requirement appears to need one of these, document the requirement first and address it upstream in Bongo rather than reaching into Bongo internals from Deez.

## Consumer-boundary policy

The normal Deez build must obtain Bongo only through `build.zig.zon`. `build.zig` imports `bongo_dependency.module("bongo")`; it does not reference a local Bongo source path.

A Bongo checkout may be used by CI only to launch MongoDB fixtures. Fixture checkout code must not be imported into Deez compilation.

## Current validation gaps to close after this audit

The existing live test proves the core transaction-capable study path, but it does not yet independently verify every requested integration behavior. Remaining validation gaps are:

- explicitly reload created decks and cards;
- independently verify required MongoDB indexes exist;
- reconnect and verify persisted Deez data;
- run the standalone/non-transaction review path;
- exercise startup connection, authentication, and TLS-verification failures;
- exercise an operation failure through `storage.Store` and confirm the error is propagated sanely.

Those tests should use the existing Deez/Bongo v0.3.0 boundary. If a missing Bongo capability is discovered, reduce it to a minimal reproducer and report it upstream rather than adding a Deez workaround.
