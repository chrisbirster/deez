pub const current_version: i32 = 1;

pub const migration_v1 =
    \\PRAGMA foreign_keys = ON;
    \\CREATE TABLE IF NOT EXISTS parameter_sets (
    \\    id BLOB PRIMARY KEY CHECK(length(id) = 32),
    \\    algorithm_family TEXT NOT NULL,
    \\    algorithm_major INTEGER NOT NULL,
    \\    implementation_major INTEGER NOT NULL,
    \\    implementation_minor INTEGER NOT NULL,
    \\    implementation_patch INTEGER NOT NULL,
    \\    source TEXT NOT NULL,
    \\    parameters_json TEXT NOT NULL DEFAULT '[]',
    \\    desired_retention REAL NOT NULL,
    \\    minimum_interval_days REAL NOT NULL,
    \\    maximum_interval_days REAL NOT NULL,
    \\    created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS parameter_weights (
    \\    parameter_set_id BLOB NOT NULL REFERENCES parameter_sets(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL CHECK(position >= 0),
    \\    value REAL NOT NULL,
    \\    PRIMARY KEY(parameter_set_id, position)
    \\);
    \\CREATE TABLE IF NOT EXISTS deck_groups (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    algorithm_family TEXT NULL,
    \\    algorithm_major INTEGER NULL,
    \\    parameter_set_id BLOB NULL REFERENCES parameter_sets(id),
    \\    created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS scheduler_defaults (
    \\    id INTEGER PRIMARY KEY CHECK(id = 1),
    \\    algorithm_family TEXT NOT NULL DEFAULT 'fsrs',
    \\    algorithm_major INTEGER NOT NULL DEFAULT 7,
    \\    parameter_set_id BLOB NULL REFERENCES parameter_sets(id)
    \\);
    \\INSERT OR IGNORE INTO scheduler_defaults(id, algorithm_family, algorithm_major) VALUES (1, 'fsrs', 7);
    \\CREATE TABLE IF NOT EXISTS decks (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    group_id INTEGER NULL REFERENCES deck_groups(id) ON DELETE SET NULL,
    \\    algorithm_family TEXT NULL,
    \\    algorithm_major INTEGER NULL,
    \\    parameter_set_id BLOB NULL REFERENCES parameter_sets(id),
    \\    created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS decks_group_id_idx ON decks(group_id);
    \\CREATE TABLE IF NOT EXISTS cards (
    \\    id INTEGER PRIMARY KEY,
    \\    deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
    \\    question TEXT NOT NULL,
    \\    answer TEXT NOT NULL,
    \\    created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS cards_deck_id_idx ON cards(deck_id);
    \\CREATE TABLE IF NOT EXISTS reviews (
    \\    id INTEGER PRIMARY KEY,
    \\    card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE RESTRICT,
    \\    rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 4),
    \\    reviewed_at_ms INTEGER NOT NULL,
    \\    algorithm_family TEXT NULL,
    \\    algorithm_major INTEGER NULL,
    \\    implementation_major INTEGER NULL,
    \\    implementation_minor INTEGER NULL,
    \\    implementation_patch INTEGER NULL,
    \\    parameter_set_id BLOB NULL REFERENCES parameter_sets(id),
    \\    scheduled_at_ms INTEGER NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS reviews_card_time_idx ON reviews(card_id, reviewed_at_ms, id);
    \\CREATE TRIGGER IF NOT EXISTS reviews_immutable_update
    \\BEFORE UPDATE ON reviews BEGIN
    \\    SELECT RAISE(ABORT, 'review history is immutable');
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS reviews_immutable_delete
    \\BEFORE DELETE ON reviews BEGIN
    \\    SELECT RAISE(ABORT, 'review history is immutable');
    \\END;
    \\CREATE TABLE IF NOT EXISTS scheduler_state (
    \\    card_id INTEGER PRIMARY KEY REFERENCES cards(id) ON DELETE CASCADE,
    \\    algorithm_family TEXT NOT NULL,
    \\    algorithm_major INTEGER NOT NULL,
    \\    implementation_major INTEGER NOT NULL,
    \\    implementation_minor INTEGER NOT NULL,
    \\    implementation_patch INTEGER NOT NULL,
    \\    parameter_set_id BLOB NOT NULL REFERENCES parameter_sets(id),
    \\    stability_days REAL NULL,
    \\    difficulty REAL NULL,
    \\    due_at_ms INTEGER NOT NULL,
    \\    last_reviewed_at_ms INTEGER NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS scheduler_state_due_idx ON scheduler_state(due_at_ms);
    \\PRAGMA user_version = 1;
;
