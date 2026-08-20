# Bongo v0.3.0 integration audit

Deez treats Bongo v0.3.0 as a frozen third-party dependency for the optional MongoDB storage backend. SQLite remains the default backend. MongoDB is selected only with `DEEZ_STORAGE=mongodb` and requires `DEEZ_MONGO_URI`.

## Frozen dependency

Deez is pinned through `build.zig.zon` to Bongo commit:

```text
631bb812777af587162daa650b53f48196960d55
```

The Bongo package at that commit declares version `0.3.0`. Deez must not follow Bongo `dev`, use a sibling `../bongo` package dependency, or depend on functionality added after this commit.

The separate Bongo checkout used by MongoDB CI is fixture-only, is pinned to the same commit, and is used only to start MongoDB fixture containers. Deez compilation still fetches Bongo through `build.zig.zon`.

## Dependency path

```text
Deez
  -> storage.Store
  -> MongoStore
  -> Bongo RuntimeClient
  -> MongoDB
```

`storage.Store` is the Deez-owned persistence boundary. It exposes Deez operations such as creating cards, loading review history, querying due cards, and recording review + scheduler state. `MongoStore` implements those operations with MongoDB-native collections, embedded scheduler state, BSON, and MongoDB query operators. The FSRS core does not issue MongoDB operations directly.

## Deez operations and Bongo usage

| Deez operation | Bongo API | Required for Deez | Validation |
|---|---|---:|---|
| connect | `RuntimeClient.connectUri()` | yes | replica-set and standalone connections pass; unreachable/auth/TLS failures propagate |
| client lifetime | `RuntimeClient.deinit()` | yes | exercised by normal cleanup and reconnect |
| database selection | `RuntimeClient.databaseName()` | yes | exercised by all MongoStore operations |
| create deck/card/group/parameter/review | `RuntimeClient.insertOne()` | yes | deck/card/review and scheduler parameter setup exercised |
| find deck/card/metadata/parameter | `RuntimeClient.findOne()` | yes | deck/card reload, scheduler/default and parameter lookup exercised |
| list/query decks/cards/reviews | `RuntimeClient.find()` + cursor `next()`/`deinit()` | yes | due-card, review-history, stats, cleanup paths exercised |
| update deck/card/defaults/scheduler state | `RuntimeClient.updateOne()` | yes | scheduler state, defaults, state clear/rebuild paths exercised |
| delete deck/card/review cleanup | `RuntimeClient.deleteOne()` | yes | integration cleanup exercises deletion paths |
| allocate stable numeric IDs | `RuntimeClient.findOneAndUpdate()` | yes | exercised by created decks/cards/reviews |
| due-card query | `query.lte()` + `RuntimeClient.find()` | yes | live due-card query passes |
| update documents | `query.set()` | yes | live review/state paths exercise it |
| increment counters | `query.inc()` | yes | live ID allocation exercises it |
| review history insert | `RuntimeClient.insertOne()` or transaction `insertOne()` | yes | transaction and standalone fallback both pass |
| scheduler state update | `RuntimeClient.updateOne()` or transaction `updateOne()` | yes | transaction and standalone fallback both pass |
| transaction capability | `RuntimeClient.supports_transactions` | yes | replica-set reports true; standalone reports false |
| session capability | `RuntimeClient.supports_sessions` | yes for transaction-path validation | replica-set test reports true |
| transaction start | `RuntimeClient.beginTransaction()` | yes when supported | replica-set review path passes |
| transaction review insert | `RuntimeTransaction.insertOne()` | yes when supported | replica-set review path passes |
| transaction state update | `RuntimeTransaction.updateOne()` | yes when supported | replica-set review path passes |
| transaction commit/lifetime | `RuntimeTransaction.commit()` / `deinit()` | yes when supported | replica-set review path passes |
| indexes | `RuntimeClient.createIndex()` | yes | CI independently verifies `deck_due_id` and `card_history` with `mongosh` |
| BSON field reads | `bson.Reader.get()` | yes | exercised throughout MongoStore parsing |
| BSON array reads | `bson.Reader.init()` / `next()` | yes | exercised when loading FSRS parameter weights |
| BSON value representation | `bson.Value` variants | yes | exercised by MongoStore parsing helpers |
| binary parameter IDs | `bson.Binary`, `bson.BinarySubtype.generic` | yes | unit coverage verifies 32-byte representation |

## Direct Bongo symbols Deez relies on

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

## Coupling assessment

Deez is coupled to Bongo's **public v0.3.0 API surface**, as any third-party consumer must be, but it is not coupled to Bongo implementation modules or wire-protocol internals.

In particular:

- Deez imports only the package module as `@import("bongo")`.
- Deez does not import `bongo/src/...`, `bongo.mongo.*` implementation files, OP_MSG internals, topology internals, pool internals, or transport internals.
- Deez does not reproduce Bongo connection, TLS, SCRAM, pooling, session, or transaction logic.
- `MongoStore` owns a public `bongo.RuntimeClient` and directly reads the public v0.3.0 `supports_sessions` / `supports_transactions` capability fields. Those field reads are the most concrete Bongo coupling in Deez, but they are part of the frozen public struct rather than an internal workaround.
- The integration test also inspects those public capability fields to prove the transaction and fallback paths being exercised.

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

CI verifies both index names directly against MongoDB with `mongosh` so Deez does not gain a `listIndexes` Bongo dependency merely for test introspection.

## Review write semantics

When `RuntimeClient.supports_transactions` is true, Deez starts a Bongo transaction, inserts the immutable review, updates the card's derived scheduler state, and commits.

When transactions are unavailable (for example a standalone `mongod`), Deez deliberately uses this order:

1. insert the immutable review;
2. update the derived scheduler state.

The review log is the source of truth. If the second write fails, scheduler state may be stale but can be rebuilt from review history. The standalone integration test records a review, clears derived scheduler state, and reconstructs the same FSRS memory state from history.

## Failure behavior

### MongoDB unavailable during startup

`MongoStore.connect()` returns the Bongo connection error. `app.run()` propagates it. Deez does not fall back to SQLite when `DEEZ_STORAGE=mongodb` was explicitly selected. The integration suite verifies an unreachable MongoDB URI fails to initialize.

### Missing MongoDB URI

When `DEEZ_STORAGE=mongodb` is set without `DEEZ_MONGO_URI`, Deez returns `error.MissingMongoUri`. It does not open SQLite.

### Authentication failure

Authentication is owned by `RuntimeClient.connectUri()`. Deez propagates the Bongo error and does not switch backends. The integration suite verifies wrong SCRAM credentials fail.

### TLS verification failure

TLS setup and certificate verification are owned by `RuntimeClient.connectUri()`. Deez propagates the Bongo error and does not switch backends. The integration suite verifies the self-signed TLS fixture is rejected when its CA is not trusted by the connection URI.

### Operation failure

MongoStore uses `try` at the Bongo boundary and `storage.Store` does not swallow or translate failures into successful operations. The integration suite sends an oversized card document through `storage.Store.createCard()` and verifies the rejected write is returned as an error and no card is persisted.

### Temporary disconnect

Deez has no hidden reconnect or retry implementation layered over Bongo. If Bongo returns an operation error after a connection has been established, MongoStore propagates it through `storage.Store`. Deez therefore inherits the frozen v0.3.0 reconnect/retry limitations rather than attempting to implement SDAM or retryable writes itself.

A mid-operation network disconnect is not artificially forced in the current Deez integration suite; the behavior is audited from the straight error-propagation path and Bongo remains responsible for its own connection/pool behavior.

### MongoDB unavailable during a review

- Transaction-capable server: an error before commit leaves the transaction uncommitted; Bongo transaction cleanup aborts an unfinished transaction.
- Standalone fallback: the immutable review is written before derived scheduler state. A failure on the second write can leave derived state stale, but the review remains available for deterministic state reconstruction.

Deez does not rely on complete retryable writes, complete transaction retry/error-label handling, or full SDAM behavior.

## Bongo v0.3.0 limitations Deez does not require

The MongoStore does not require or work around these intentionally excluded v0.3.0 areas:

- full SDAM/background topology monitoring;
- complete retryable read/write semantics;
- complete transaction retry/error-label handling;
- all read-preference routing modes;
- MONGODB-X509/mTLS client certificates;
- OP_COMPRESSED;
- complete SASLprep.

If a future Deez requirement appears to need one of these, document the requirement first and address it upstream in Bongo rather than reaching into Bongo internals from Deez.

## Cross-platform boundary

Deez contains no macOS-only or Linux-only Bongo API assumptions. The same `RuntimeClient` and `storage.Store` code is compiled for the selected Zig target. Linux CI runs the consumer and MongoDB integration gates. Bongo v0.3.0 is treated as the cross-platform dependency release validated separately on macOS and Linux.

## Consumer-boundary validation

The normal Deez build obtains Bongo only through `build.zig.zon`. `build.zig` calls `b.dependency("bongo", ...)` and imports `bongo_dependency.module("bongo")`; it does not reference a local Bongo source path.

Validation performed against the frozen commit/package:

```text
zig build                         PASS
zig build test                    PASS
zig build mongo-integration-test  PASS
```

The live MongoDB validation additionally passes these scenarios:

1. initialize MongoStore;
2. create a deck;
3. create cards;
4. load cards and decks;
5. query due cards;
6. save FSRS/scheduler state;
7. record a review;
8. reload immutable review history;
9. verify scheduler state;
10. independently verify required indexes;
11. reconnect and verify persisted data;
12. exercise transaction-capable review writes;
13. exercise standalone/non-transaction fallback and rebuild derived state;
14. propagate a rejected MongoDB write through `storage.Store`;
15. reject unreachable startup, invalid authentication, and untrusted TLS without falling back to SQLite.

## Defect result

No Bongo v0.3.0 defect was discovered by this Deez integration validation. No Bongo issue was filed, and no Bongo-internal workaround was added to Deez.

## Development readiness

The MongoDB backend is considered safe enough for **normal Deez development and dogfooding** against frozen Bongo v0.3.0.

That does not expand Bongo v0.3.0's published guarantees: Deez still inherits the documented limitations around full SDAM, complete retry semantics, advanced transaction retry handling, read-preference routing, X509/mTLS client authentication, compression, and complete SASLprep. SQLite remains the default Deez backend.
