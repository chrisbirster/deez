const std = @import("std");
const Io = std.Io;
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const format_name = "deez.deck";
pub const format_version: u32 = 1;

pub const CardFile = struct {
    question: []const u8,
    answer: []const u8,
};

pub const DeckContents = struct {
    name: []const u8,
    cards: []const CardFile,
};

pub const File = struct {
    format: []const u8,
    version: u32,
    deck: DeckContents,
};

pub const ImportResult = struct {
    deck_id: u64,
    card_count: usize,
};

fn requireText(text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
}

fn validate(file: File) !void {
    if (!std.mem.eql(u8, file.format, format_name)) return error.UnsupportedDeckFormat;
    if (file.version != format_version) return error.UnsupportedDeckVersion;
    try requireText(file.deck.name);
    for (file.deck.cards) |card| {
        try requireText(card.question);
        try requireText(card.answer);
    }
}

/// Export a shareable deck-content file. Personal review history and derived
/// scheduler state are intentionally excluded; use Deez backup/restore for a
/// full-fidelity personal archive.
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

    const file_cards = try allocator.alloc(CardFile, cards.len);
    defer allocator.free(file_cards);
    for (cards, 0..) |card, index| {
        file_cards[index] = .{
            .question = card.question,
            .answer = card.answer,
        };
    }

    const file: File = .{
        .format = format_name,
        .version = format_version,
        .deck = .{
            .name = deck.name,
            .cards = file_cards,
        },
    };
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2 }, writer);
    try writer.writeAll("\n");
}

pub fn importSlice(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    bytes: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    var parsed = try std.json.parseFromSlice(File, allocator, bytes, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    try validate(parsed.value);

    const deck_id = try store.createDeck(parsed.value.deck.name, created_at_ms);
    errdefer store.deleteDeck(deck_id) catch {};

    _ = try store.ensureDefaultFsrs7(created_at_ms);
    for (parsed.value.deck.cards) |card| {
        _ = try store.createCard(deck_id, card.question, card.answer, created_at_ms);
    }

    return .{
        .deck_id = deck_id,
        .card_count = parsed.value.deck.cards.len,
    };
}

test "JSON deck import creates a fresh deck and cards" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    const json =
        \\{
        \\  "format": "deez.deck",
        \\  "version": 1,
        \\  "deck": {
        \\    "name": "Zig Basics",
        \\    "cards": [
        \\      {"question": "What is Zig?", "answer": "A systems programming language"},
        \\      {"question": "What is comptime?", "answer": "Compile-time execution"}
        \\    ]
        \\  }
        \\}
    ;

    const result = try importSlice(std.testing.allocator, &store, json, 1234);
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

test "JSON deck export contains content without review state" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    const deck_id = try store.createDeck("BSON", 0);
    _ = try store.createCard(deck_id, "What is BSON?", "Binary JSON", 0);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try exportDeck(std.testing.allocator, &store, deck_id, &out.writer);

    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"format\": \"deez.deck\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\": \"BSON\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "What is BSON?") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "reviews") == null);
}
