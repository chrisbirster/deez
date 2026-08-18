const std = @import("std");
const DeckId = @import("card.zig").DeckId;
const CardId = @import("card.zig").CardId;

pub const Command = union(enum) {
    help,
    decks,
    deck_add: struct { name: []const u8 },
    deck_rename: struct { deck_id: DeckId, name: []const u8 },
    deck_delete: struct { deck_id: DeckId },
    card_add: struct { deck_id: DeckId, question: []const u8, answer: []const u8 },
    card_edit: struct { card_id: CardId, question: []const u8, answer: []const u8 },
    card_delete: struct { card_id: CardId },
    study: struct { deck_id: DeckId },
    stats: struct { deck_id: ?DeckId },
    inspect: struct { card_id: CardId },
    fsrs_optimize: struct { deck_id: ?DeckId, recency_half_life_days: ?f64 },
    fsrs_evaluate: struct { deck_id: ?DeckId },
    fsrs_simulate: struct { retention: ?f64 },
    fsrs_retention,
    scheduler_list,
};

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn parseFloat(text: []const u8) !f64 {
    return std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
}

fn expectLength(args: []const []const u8, expected: usize) !void {
    if (args.len != expected) return error.InvalidArguments;
}

pub fn parse(args: []const []const u8) !Command {
    if (args.len <= 1) return .help;
    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, command, "decks")) {
        try expectLength(args, 2);
        return .decks;
    }
    if (std.mem.eql(u8, command, "deck")) {
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[2], "add")) {
            try expectLength(args, 4);
            return .{ .deck_add = .{ .name = args[3] } };
        }
        if (std.mem.eql(u8, args[2], "rename")) {
            try expectLength(args, 5);
            return .{ .deck_rename = .{ .deck_id = try parseId(args[3]), .name = args[4] } };
        }
        if (std.mem.eql(u8, args[2], "delete")) {
            try expectLength(args, 4);
            return .{ .deck_delete = .{ .deck_id = try parseId(args[3]) } };
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, command, "card")) {
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[2], "add")) {
            try expectLength(args, 6);
            return .{ .card_add = .{
                .deck_id = try parseId(args[3]),
                .question = args[4],
                .answer = args[5],
            } };
        }
        if (std.mem.eql(u8, args[2], "edit")) {
            try expectLength(args, 6);
            return .{ .card_edit = .{
                .card_id = try parseId(args[3]),
                .question = args[4],
                .answer = args[5],
            } };
        }
        if (std.mem.eql(u8, args[2], "delete")) {
            try expectLength(args, 4);
            return .{ .card_delete = .{ .card_id = try parseId(args[3]) } };
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, command, "study")) {
        try expectLength(args, 3);
        return .{ .study = .{ .deck_id = try parseId(args[2]) } };
    }
    if (std.mem.eql(u8, command, "stats")) {
        if (args.len == 2) return .{ .stats = .{ .deck_id = null } };
        if (args.len == 3) return .{ .stats = .{ .deck_id = try parseId(args[2]) } };
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, command, "inspect")) {
        try expectLength(args, 3);
        return .{ .inspect = .{ .card_id = try parseId(args[2]) } };
    }
    if (std.mem.eql(u8, command, "fsrs")) {
        if (args.len < 3) return error.InvalidArguments;
        if (std.mem.eql(u8, args[2], "optimize")) {
            var deck_id: ?DeckId = null;
            var recency_half_life_days: ?f64 = null;
            var index: usize = 3;
            while (index < args.len) {
                if (std.mem.eql(u8, args[index], "--recency-days")) {
                    if (index + 1 >= args.len) return error.InvalidArguments;
                    recency_half_life_days = try parseFloat(args[index + 1]);
                    index += 2;
                } else if (deck_id == null) {
                    deck_id = try parseId(args[index]);
                    index += 1;
                } else return error.InvalidArguments;
            }
            return .{ .fsrs_optimize = .{
                .deck_id = deck_id,
                .recency_half_life_days = recency_half_life_days,
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
        if (args.len == 3 and std.mem.eql(u8, args[2], "list")) return .scheduler_list;
        return error.UnknownCommand;
    }
    return error.UnknownCommand;
}

pub const help_text =
    \\DEEZ — Drill, Evaluate, Encode, Zen
    \\
    \\Usage:
    \\  deez decks
    \\  deez deck add <name>
    \\  deez deck rename <deck-id> <name>
    \\  deez deck delete <deck-id>
    \\  deez card add <deck-id> <question> <answer>
    \\  deez card edit <card-id> <question> <answer>
    \\  deez card delete <card-id>
    \\  deez study <deck-id>
    \\  deez stats [deck-id]
    \\  deez inspect <card-id>
    \\  deez fsrs optimize [deck-id] [--recency-days <days>]
    \\  deez fsrs evaluate [deck-id]
    \\  deez fsrs simulate [--retention <0..1>]
    \\  deez fsrs retention
    \\  deez scheduler list
;

test "parse study command" {
    const args = [_][]const u8{ "deez", "study", "42" };
    const command = try parse(&args);
    try std.testing.expectEqual(@as(DeckId, 42), command.study.deck_id);
}

test "parse card add command" {
    const args = [_][]const u8{ "deez", "card", "add", "3", "What is BSON?", "Binary JSON" };
    const command = try parse(&args);
    try std.testing.expectEqual(@as(DeckId, 3), command.card_add.deck_id);
    try std.testing.expectEqualStrings("What is BSON?", command.card_add.question);
}

test "parse optimizer recency option" {
    const args = [_][]const u8{ "deez", "fsrs", "optimize", "5", "--recency-days", "90" };
    const command = try parse(&args);
    try std.testing.expectEqual(@as(?DeckId, 5), command.fsrs_optimize.deck_id);
    try std.testing.expectApproxEqAbs(@as(f64, 90), command.fsrs_optimize.recency_half_life_days.?, 1e-12);
}

test "unknown command is rejected" {
    const args = [_][]const u8{ "deez", "wat" };
    try std.testing.expectError(error.UnknownCommand, parse(&args));
}
