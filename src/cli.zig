const std = @import("std");
const DeckId = @import("card.zig").DeckId;
const CardId = @import("card.zig").CardId;

pub const HelpTopic = enum {
    general,
    deck,
    card,
    study,
    stats,
    inspect,
    fsrs,
    scheduler,
};

pub const StudyOrder = enum {
    due,
    reviews_first,
    new_first,
};

pub const Command = union(enum) {
    help: HelpTopic,
    decks,
    cards: struct { deck_id: DeckId },
    deck_add: struct { name: []const u8 },
    deck_rename: struct { deck_id: DeckId, name: []const u8 },
    deck_delete: struct { deck_id: DeckId },
    deck_export: struct { deck_id: DeckId },
    deck_import: struct { path: []const u8 },
    card_add: struct { deck_id: DeckId, question: []const u8, answer: []const u8 },
    card_edit: struct { card_id: CardId, question: []const u8, answer: []const u8 },
    card_delete: struct { card_id: CardId },
    study: struct {
        deck_id: DeckId,
        new_limit: ?usize,
        order: StudyOrder,
        shuffle: bool,
    },
    stats: struct { deck_id: ?DeckId, json: bool },
    inspect: struct { card_id: CardId, json: bool },
    fsrs_optimize: struct { deck_id: ?DeckId, recency_half_life_days: ?f64 },
    fsrs_evaluate: struct { deck_id: ?DeckId },
    fsrs_simulate: struct { retention: ?f64 },
    fsrs_retention,
    scheduler_list,
};

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn parseCount(text: []const u8) !usize {
    return std.fmt.parseInt(usize, text, 10) catch return error.InvalidNumber;
}

fn parseFloat(text: []const u8) !f64 {
    return std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
}

fn parseStudyOrder(text: []const u8) !StudyOrder {
    if (std.mem.eql(u8, text, "due")) return .due;
    if (std.mem.eql(u8, text, "reviews-first")) return .reviews_first;
    if (std.mem.eql(u8, text, "new-first")) return .new_first;
    return error.InvalidStudyOrder;
}

fn expectLength(args: []const []const u8, expected: usize) !void {
    if (args.len != expected) return error.InvalidArguments;
}

fn requireText(text: []const u8) ![]const u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
    return text;
}

fn parseHelpTopic(text: []const u8) !HelpTopic {
    if (std.mem.eql(u8, text, "deck") or std.mem.eql(u8, text, "decks")) return .deck;
    if (std.mem.eql(u8, text, "card") or std.mem.eql(u8, text, "cards")) return .card;
    if (std.mem.eql(u8, text, "study")) return .study;
    if (std.mem.eql(u8, text, "stats")) return .stats;
    if (std.mem.eql(u8, text, "inspect")) return .inspect;
    if (std.mem.eql(u8, text, "fsrs")) return .fsrs;
    if (std.mem.eql(u8, text, "scheduler")) return .scheduler;
    return error.UnknownHelpTopic;
}

fn isHelp(text: []const u8) bool {
    return std.mem.eql(u8, text, "--help") or std.mem.eql(u8, text, "-h");
}

pub fn parse(args: []const []const u8) !Command {
    if (args.len <= 1) return .{ .help = .general };
    const command = args[1];

    if (std.mem.eql(u8, command, "help")) {
        if (args.len == 2) return .{ .help = .general };
        if (args.len == 3) return .{ .help = try parseHelpTopic(args[2]) };
        return error.InvalidArguments;
    }
    if (isHelp(command)) {
        try expectLength(args, 2);
        return .{ .help = .general };
    }
    if (std.mem.eql(u8, command, "decks")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .deck };
        try expectLength(args, 2);
        return .decks;
    }
    if (std.mem.eql(u8, command, "cards")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .card };
        try expectLength(args, 3);
        return .{ .cards = .{ .deck_id = try parseId(args[2]) } };
    }
    if (std.mem.eql(u8, command, "deck")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .deck };
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[2], "add")) {
            try expectLength(args, 4);
            return .{ .deck_add = .{ .name = try requireText(args[3]) } };
        }
        if (std.mem.eql(u8, args[2], "rename")) {
            try expectLength(args, 5);
            return .{ .deck_rename = .{
                .deck_id = try parseId(args[3]),
                .name = try requireText(args[4]),
            } };
        }
        if (std.mem.eql(u8, args[2], "delete")) {
            if (args.len != 5 or !std.mem.eql(u8, args[4], "--yes")) return error.ConfirmationRequired;
            return .{ .deck_delete = .{ .deck_id = try parseId(args[3]) } };
        }
        if (std.mem.eql(u8, args[2], "export")) {
            try expectLength(args, 4);
            return .{ .deck_export = .{ .deck_id = try parseId(args[3]) } };
        }
        if (std.mem.eql(u8, args[2], "import")) {
            try expectLength(args, 4);
            return .{ .deck_import = .{ .path = try requireText(args[3]) } };
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, command, "card")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .card };
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[2], "add")) {
            try expectLength(args, 6);
            return .{ .card_add = .{
                .deck_id = try parseId(args[3]),
                .question = try requireText(args[4]),
                .answer = try requireText(args[5]),
            } };
        }
        if (std.mem.eql(u8, args[2], "edit")) {
            try expectLength(args, 6);
            return .{ .card_edit = .{
                .card_id = try parseId(args[3]),
                .question = try requireText(args[4]),
                .answer = try requireText(args[5]),
            } };
        }
        if (std.mem.eql(u8, args[2], "delete")) {
            if (args.len != 5 or !std.mem.eql(u8, args[4], "--yes")) return error.ConfirmationRequired;
            return .{ .card_delete = .{ .card_id = try parseId(args[3]) } };
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, command, "study")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .study };
        if (args.len < 3) return error.InvalidArguments;

        const deck_id = try parseId(args[2]);
        var new_limit: ?usize = null;
        var order: StudyOrder = .due;
        var order_set = false;
        var shuffle = false;
        var index: usize = 3;
        while (index < args.len) {
            if (std.mem.eql(u8, args[index], "--new-limit")) {
                if (new_limit != null or index + 1 >= args.len) return error.InvalidArguments;
                new_limit = try parseCount(args[index + 1]);
                index += 2;
            } else if (std.mem.eql(u8, args[index], "--order")) {
                if (order_set or index + 1 >= args.len) return error.InvalidArguments;
                order = try parseStudyOrder(args[index + 1]);
                order_set = true;
                index += 2;
            } else if (std.mem.eql(u8, args[index], "--shuffle")) {
                if (shuffle) return error.InvalidArguments;
                shuffle = true;
                index += 1;
            } else {
                return error.InvalidArguments;
            }
        }
        return .{ .study = .{
            .deck_id = deck_id,
            .new_limit = new_limit,
            .order = order,
            .shuffle = shuffle,
        } };
    }
    if (std.mem.eql(u8, command, "stats")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .stats };
        var deck_id: ?DeckId = null;
        var json = false;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                if (json) return error.InvalidArguments;
                json = true;
            } else if (deck_id == null) {
                deck_id = try parseId(arg);
            } else return error.InvalidArguments;
        }
        return .{ .stats = .{ .deck_id = deck_id, .json = json } };
    }
    if (std.mem.eql(u8, command, "inspect")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .inspect };
        if (args.len != 3 and args.len != 4) return error.InvalidArguments;
        const json = args.len == 4 and std.mem.eql(u8, args[3], "--json");
        if (args.len == 4 and !json) return error.InvalidArguments;
        return .{ .inspect = .{ .card_id = try parseId(args[2]), .json = json } };
    }
    if (std.mem.eql(u8, command, "fsrs")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .fsrs };
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[2], "optimize")) {
            var deck_id: ?DeckId = null;
            var recency = false;
            var index: usize = 3;
            while (index < args.len) {
                if (std.mem.eql(u8, args[index], "--recency")) {
                    if (recency) return error.InvalidArguments;
                    recency = true;
                    index += 1;
                } else if (deck_id == null) {
                    deck_id = try parseId(args[index]);
                    index += 1;
                } else return error.InvalidArguments;
            }
            return .{ .fsrs_optimize = .{
                .deck_id = deck_id,
                .recency_half_life_days = if (recency) 1.0 else null,
            } };
        }
        if (std.mem.eql(u8, args[2], "evaluate")) {
            if (args.len == 3) return .{ .fsrs_evaluate = .{ .deck_id = null } };
            if (args.len == 4) return .{ .fsrs_evaluate = .{ .deck_id = try parseId(args[3]) } };
            return error.InvalidArguments;
        }
        if (std.mem.eql(u8, args[2], "simulate")) {
            if (args.len == 3) return .{ .fsrs_simulate = .{ .retention = null } };
            if (args.len == 5 and std.mem.eql(u8, args[3], "--retention")) {
                return .{ .fsrs_simulate = .{ .retention = try parseFloat(args[4]) } };
            }
            return error.InvalidArguments;
        }
        if (std.mem.eql(u8, args[2], "retention")) {
            try expectLength(args, 3);
            return .fsrs_retention;
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, command, "scheduler")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .help = .scheduler };
        if (args.len == 3 and std.mem.eql(u8, args[2], "list")) return .scheduler_list;
        return error.UnknownCommand;
    }
    return error.UnknownCommand;
}

pub const help_text =
    \\DEEZ — Drill, Evaluate, Encode, Zen
    \\
    \\Usage:
    \\  deez setup
    \\  deez help [deck|card|study|stats|inspect|fsrs|scheduler]
    \\  deez decks
    \\  deez cards <deck-id>
    \\  deez deck add <name>
    \\  deez deck rename <deck-id> <name>
    \\  deez deck delete <deck-id> --yes
    \\  deez deck export <deck-id> > deck.json
    \\  deez deck import <deck.json>
    \\  deez card add <deck-id> <question> <answer>
    \\  deez card edit <card-id> <question> <answer>
    \\  deez card delete <card-id> --yes
    \\  deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
    \\  deez stats [deck-id] [--json]
    \\  deez inspect <card-id> [--json]
    \\  deez fsrs optimize [deck-id] [--recency]
    \\  deez fsrs evaluate [deck-id]
    \\  deez fsrs simulate [--retention <0..1>]
    \\  deez fsrs retention
    \\  deez scheduler list
;

const deck_help =
    \\Deck commands:
    \\  deez decks
    \\  deez deck add <name>
    \\  deez deck rename <deck-id> <name>
    \\  deez deck delete <deck-id> --yes
    \\  deez deck export <deck-id> > deck.json
    \\  deez deck import <deck.json>
;
const card_help =
    \\Card commands:
    \\  deez cards <deck-id>
    \\  deez card add <deck-id> <question> <answer>
    \\  deez card edit <card-id> <question> <answer>
    \\  deez card delete <card-id> --yes
;
const study_help =
    \\Study command:
    \\  deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
    \\
    \\Defaults preserve timestamp order and do not limit new cards or shuffle.
;
const stats_help = "Usage: deez stats [deck-id] [--json]\n";
const inspect_help = "Usage: deez inspect <card-id> [--json]\n";
const fsrs_help =
    \\FSRS commands:
    \\  deez fsrs optimize [deck-id] [--recency]
    \\  deez fsrs evaluate [deck-id]
    \\  deez fsrs simulate [--retention <0..1>]
    \\  deez fsrs retention
;
const scheduler_help = "Usage: deez scheduler list\n";

pub fn helpText(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .general => help_text,
        .deck => deck_help,
        .card => card_help,
        .study => study_help,
        .stats => stats_help,
        .inspect => inspect_help,
        .fsrs => fsrs_help,
        .scheduler => scheduler_help,
    };
}

test "parse study command" {
    const args = [_][]const u8{ "deez", "study", "42" };
    const command = try parse(&args);
    try std.testing.expectEqual(@as(DeckId, 42), command.study.deck_id);
    try std.testing.expectEqual(@as(?usize, null), command.study.new_limit);
    try std.testing.expectEqual(StudyOrder.due, command.study.order);
    try std.testing.expect(!command.study.shuffle);
}

test "parse study queue options" {
    const args = [_][]const u8{
        "deez",
        "study",
        "42",
        "--new-limit",
        "10",
        "--order",
        "reviews-first",
        "--shuffle",
    };
    const command = try parse(&args);
    try std.testing.expectEqual(@as(?usize, 10), command.study.new_limit);
    try std.testing.expectEqual(StudyOrder.reviews_first, command.study.order);
    try std.testing.expect(command.study.shuffle);
}

test "parse card listing and add commands" {
    const list_args = [_][]const u8{ "deez", "cards", "3" };
    const listing = try parse(&list_args);
    try std.testing.expectEqual(@as(DeckId, 3), listing.cards.deck_id);

    const add_args = [_][]const u8{ "deez", "card", "add", "3", "What is BSON?", "Binary JSON" };
    const command = try parse(&add_args);
    try std.testing.expectEqual(@as(DeckId, 3), command.card_add.deck_id);
    try std.testing.expectEqualStrings("What is BSON?", command.card_add.question);
}

test "parse JSON deck import and export commands" {
    const export_args = [_][]const u8{ "deez", "deck", "export", "7" };
    const exported = try parse(&export_args);
    try std.testing.expectEqual(@as(DeckId, 7), exported.deck_export.deck_id);

    const import_args = [_][]const u8{ "deez", "deck", "import", "zig.json" };
    const imported = try parse(&import_args);
    try std.testing.expectEqualStrings("zig.json", imported.deck_import.path);
}

test "parse optimizer recency option" {
    const args = [_][]const u8{ "deez", "fsrs", "optimize", "5", "--recency" };
    const command = try parse(&args);
    try std.testing.expectEqual(@as(?DeckId, 5), command.fsrs_optimize.deck_id);
    try std.testing.expect(command.fsrs_optimize.recency_half_life_days != null);
}

test "optimizer rejects duplicate recency flag" {
    const args = [_][]const u8{ "deez", "fsrs", "optimize", "--recency", "--recency" };
    try std.testing.expectError(error.InvalidArguments, parse(&args));
}

test "command-specific help parses" {
    const args = [_][]const u8{ "deez", "help", "fsrs" };
    const command = try parse(&args);
    try std.testing.expectEqual(HelpTopic.fsrs, command.help);
    try std.testing.expect(std.mem.indexOf(u8, helpText(command.help), "optimize") != null);
}

test "stats and inspect support machine-readable output" {
    const stats_args = [_][]const u8{ "deez", "stats", "4", "--json" };
    const stats = try parse(&stats_args);
    try std.testing.expectEqual(@as(?DeckId, 4), stats.stats.deck_id);
    try std.testing.expect(stats.stats.json);

    const inspect_args = [_][]const u8{ "deez", "inspect", "9", "--json" };
    const inspect = try parse(&inspect_args);
    try std.testing.expect(inspect.inspect.json);
}

test "destructive commands require explicit confirmation" {
    const deck_args = [_][]const u8{ "deez", "deck", "delete", "3" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&deck_args));
    const card_args = [_][]const u8{ "deez", "card", "delete", "9" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&card_args));
}

test "blank names and card text are rejected" {
    const deck_args = [_][]const u8{ "deez", "deck", "add", "   " };
    try std.testing.expectError(error.InvalidText, parse(&deck_args));
    const card_args = [_][]const u8{ "deez", "card", "add", "1", "", "answer" };
    try std.testing.expectError(error.InvalidText, parse(&card_args));
}

test "invalid ids and missing required arguments are rejected" {
    const invalid_id = [_][]const u8{ "deez", "cards", "nope" };
    try std.testing.expectError(error.InvalidId, parse(&invalid_id));

    const invalid_order = [_][]const u8{ "deez", "study", "1", "--order", "random" };
    try std.testing.expectError(error.InvalidStudyOrder, parse(&invalid_order));

    const cases = [_][]const []const u8{
        &.{ "deez", "deck" },
        &.{ "deez", "deck", "add" },
        &.{ "deez", "deck", "export" },
        &.{ "deez", "deck", "import" },
        &.{ "deez", "cards" },
        &.{ "deez", "card" },
        &.{ "deez", "card", "add", "1" },
        &.{ "deez", "study" },
        &.{ "deez", "inspect" },
        &.{ "deez", "fsrs" },
    };
    for (cases) |case_args| try std.testing.expectError(error.InvalidArguments, parse(case_args));
}

test "unknown command is rejected" {
    const args = [_][]const u8{ "deez", "wat" };
    try std.testing.expectError(error.UnknownCommand, parse(&args));
}
