const std = @import("std");
const Io = std.Io;
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const format_name = "deez.nut";
pub const format_version: u32 = 1;

const deck_kind = "deck";
const card_kind = "card";

const Envelope = struct {
    kind: []const u8,
};

const DeckRecord = struct {
    kind: []const u8,
    format: []const u8,
    version: u32,
    name: []const u8,
};

const CardRecord = struct {
    kind: []const u8,
    question: []const u8,
    answer: []const u8,
};

pub const ImportResult = struct {
    deck_id: u64,
    card_count: usize,
};

fn requireText(text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
}

fn validateDeck(record: DeckRecord) !void {
    if (!std.mem.eql(u8, record.kind, deck_kind)) return error.InvalidNutRecord;
    if (!std.mem.eql(u8, record.format, format_name)) return error.UnsupportedNutFormat;
    if (record.version != format_version) return error.UnsupportedNutVersion;
    try requireText(record.name);
}

fn validateCard(record: CardRecord) !void {
    if (!std.mem.eql(u8, record.kind, card_kind)) return error.InvalidNutRecord;
    try requireText(record.question);
    try requireText(record.answer);
}

/// Export a shareable Deez .nut file. A .nut file is NDJSON: the first
/// non-empty line is a deck record and every following record is a card.
/// Personal review history and derived scheduler state are intentionally
/// excluded; use Deez backup/restore for a full-fidelity personal archive.
pub fn exportDeck(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    writer: *Io.Writer,
) !void {
    const deck = (try store.getDeck(allocator, deck_id)) orelse return error.DeckNotFound;
    defer deck.deinit(allocator);

    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }

    const header: DeckRecord = .{
        .kind = deck_kind,
        .format = format_name,
        .version = format_version,
        .name = deck.name,
    };
    try std.json.Stringify.value(header, .{}, writer);
    try writer.writeAll("\n");

    for (cards) |card| {
        const record: CardRecord = .{
            .kind = card_kind,
            .question = card.question,
            .answer = card.answer,
        };
        try std.json.Stringify.value(record, .{}, writer);
        try writer.writeAll("\n");
    }
}

pub fn importSlice(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    bytes: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var deck_id: ?u64 = null;
    var card_count: usize = 0;

    errdefer if (deck_id) |id| store.deleteDeck(id) catch {};

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var envelope = try std.json.parseFromSlice(Envelope, allocator, line, .{
            .ignore_unknown_fields = true,
        });
        const is_deck = std.mem.eql(u8, envelope.value.kind, deck_kind);
        const is_card = std.mem.eql(u8, envelope.value.kind, card_kind);
        envelope.deinit();

        if (is_deck) {
            if (deck_id != null) return error.DuplicateNutHeader;

            var parsed = try std.json.parseFromSlice(DeckRecord, allocator, line, .{
                .ignore_unknown_fields = false,
            });
            defer parsed.deinit();
            try validateDeck(parsed.value);

            const id = try store.createDeck(parsed.value.name, created_at_ms);
            deck_id = id;
            _ = try store.ensureDefaultFsrs7(created_at_ms);
            continue;
        }

        if (is_card) {
            const id = deck_id orelse return error.MissingNutHeader;

            var parsed = try std.json.parseFromSlice(CardRecord, allocator, line, .{
                .ignore_unknown_fields = false,
            });
            defer parsed.deinit();
            try validateCard(parsed.value);

            _ = try store.createCard(id, parsed.value.question, parsed.value.answer, created_at_ms);
            card_count += 1;
            continue;
        }

        return error.UnsupportedNutRecordKind;
    }

    return .{
        .deck_id = deck_id orelse return error.MissingNutHeader,
        .card_count = card_count,
    };
}

test ".nut import creates a fresh deck and cards" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    const source =
        \\{"kind":"deck","format":"deez.nut","version":1,"name":"Zig Basics"}
        \\{"kind":"card","question":"What is Zig?","answer":"A systems programming language"}
        \\{"kind":"card","question":"What is comptime?","answer":"Compile-time execution"}
    ;

    const result = try importSlice(std.testing.allocator, &store, source, 1234);
    try std.testing.expectEqual(@as(usize, 2), result.card_count);

    const deck = (try store.getDeck(std.testing.allocator, result.deck_id)).?;
    defer deck.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Zig Basics", deck.name);

    const cards = try store.cards(std.testing.allocator, result.deck_id);
    defer {
        for (cards) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(cards);
    }
    try std.testing.expectEqual(@as(usize, 2), cards.len);
    try std.testing.expectEqualStrings("What is Zig?", cards[0].question);
    try std.testing.expectEqualStrings("What is comptime?", cards[1].question);
}

test ".nut export is compact line-oriented JSON" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    const deck_id = try store.createDeck("BSON", 0);
    _ = try store.createCard(deck_id, "What is BSON?", "Binary JSON", 0);
    _ = try store.createCard(deck_id, "Portable?", "Yes", 0);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try exportDeck(std.testing.allocator, &store, deck_id, &out.writer);

    const bytes = out.written();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"kind\":\"deck\",\"format\":\"deez.nut\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"kind\":\"card\",\"question\":\"What is BSON?\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "reviews") == null);
}

test ".nut requires a deck header before cards" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    const source =
        \\{"kind":"card","question":"q","answer":"a"}
    ;
    try std.testing.expectError(
        error.MissingNutHeader,
        importSlice(std.testing.allocator, &store, source, 0),
    );
}
