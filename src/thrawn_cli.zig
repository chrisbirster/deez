const std = @import("std");
const th = @import("thrawn");
const cli = @import("cli.zig");

pub const Help = union(enum) {
    general,
    core: cli.HelpTopic,
    backup,
    notes,
    rich,
};

pub const Route = union(enum) {
    help: Help,
    setup,
    core: cli.Command,
    backup_cli,
    notes_cli,
    rich_cli,
};

fn noop(_: *th.Context) !void {}

const setup_command: th.Command = .{
    .name = "setup",
    .summary = "Configure the storage backend",
    .handler = noop,
    .args = .{ .exact = 0 },
};

const decks_command: th.Command = .{
    .name = "decks",
    .summary = "List decks",
    .handler = noop,
    .args = .{ .exact = 0 },
};

const nuts_command: th.Command = .{
    .name = "nuts",
    .summary = "List decks",
    .handler = noop,
    .args = .{ .exact = 0 },
};

const cards_command: th.Command = .{
    .name = "cards",
    .summary = "List cards in a deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id" }} },
};

const deck_add_command: th.Command = .{
    .name = "add",
    .summary = "Create a deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "name" }} },
};

const deck_rename_command: th.Command = .{
    .name = "rename",
    .summary = "Rename a deck",
    .handler = noop,
    .args = .{ .positionals = &.{ .{ .name = "deck-id" }, .{ .name = "name" } } },
};

const deck_delete_command: th.Command = .{
    .name = "delete",
    .summary = "Delete a deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id" }} },
    .options = &.{.{ .long = "yes", .summary = "Confirm deletion" }},
};

const deck_export_command: th.Command = .{
    .name = "export",
    .summary = "Export a shareable deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id" }} },
};

const deck_import_command: th.Command = .{
    .name = "import",
    .summary = "Import a shareable deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "path" }} },
};

const deck_command: th.Command = .{
    .name = "deck",
    .summary = "Manage decks",
    .children = &.{
        &deck_add_command,
        &deck_rename_command,
        &deck_delete_command,
        &deck_export_command,
        &deck_import_command,
    },
};

const nut_export_command: th.Command = .{
    .name = "export",
    .summary = "Export a .nut deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id" }} },
};

const nut_import_command: th.Command = .{
    .name = "import",
    .summary = "Import a .nut deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "path" }} },
};

const nut_command: th.Command = .{
    .name = "nut",
    .summary = "Manage .nut deck files",
    .children = &.{ &nut_export_command, &nut_import_command },
};

const note_add_command: th.Command = .{
    .name = "add",
    .summary = "Create a note",
    .handler = noop,
    .args = .{
        .min = 4,
        .positionals = &.{
            .{ .name = "deck-id" },
            .{ .name = "note-type" },
            .{ .name = "fields", .variadic = true },
        },
    },
};

const note_edit_command: th.Command = .{
    .name = "edit",
    .summary = "Edit a note",
    .handler = noop,
    .args = .{
        .min = 4,
        .positionals = &.{
            .{ .name = "deck-id" },
            .{ .name = "note-id" },
            .{ .name = "fields", .variadic = true },
        },
    },
};

const note_command: th.Command = .{
    .name = "note",
    .summary = "Manage notes",
    .children = &.{ &note_add_command, &note_edit_command },
};

const notes_command: th.Command = .{
    .name = "notes",
    .summary = "List notes in a deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id" }} },
};

const card_add_command: th.Command = .{
    .name = "add",
    .summary = "Create a card",
    .handler = noop,
    .args = .{ .positionals = &.{
        .{ .name = "deck-id" },
        .{ .name = "question" },
        .{ .name = "answer" },
    } },
};

const card_edit_command: th.Command = .{
    .name = "edit",
    .summary = "Edit a card",
    .handler = noop,
    .args = .{ .positionals = &.{
        .{ .name = "card-id" },
        .{ .name = "question" },
        .{ .name = "answer" },
    } },
};

const card_delete_command: th.Command = .{
    .name = "delete",
    .summary = "Delete a card",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "card-id" }} },
    .options = &.{.{ .long = "yes", .summary = "Confirm deletion" }},
};

const card_command: th.Command = .{
    .name = "card",
    .summary = "Manage cards",
    .children = &.{ &card_add_command, &card_edit_command, &card_delete_command },
};

const study_command: th.Command = .{
    .name = "study",
    .summary = "Study a deck",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id" }} },
    .options = &.{
        .{ .long = "new-limit", .kind = .value, .value_name = "count", .summary = "Limit new cards" },
        .{
            .long = "order",
            .kind = .value,
            .value_type = .choice,
            .value_name = "order",
            .choices = &.{ "due", "reviews-first", "new-first" },
            .summary = "Study queue order",
        },
        .{ .long = "shuffle", .summary = "Shuffle the session" },
    },
};

const stats_command: th.Command = .{
    .name = "stats",
    .summary = "Show study statistics",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} },
    .options = &.{.{ .long = "json", .summary = "Emit JSON" }},
};

const inspect_command: th.Command = .{
    .name = "inspect",
    .summary = "Inspect scheduler state for a card",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "card-id" }} },
    .options = &.{.{ .long = "json", .summary = "Emit JSON" }},
};

const fsrs_optimize_command: th.Command = .{
    .name = "optimize",
    .summary = "Optimize FSRS parameters",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} },
    .options = &.{.{ .long = "recency", .summary = "Use recency weighting" }},
};

const fsrs_evaluate_command: th.Command = .{
    .name = "evaluate",
    .summary = "Evaluate FSRS parameters",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} },
};

const fsrs_simulate_command: th.Command = .{
    .name = "simulate",
    .summary = "Simulate FSRS retention",
    .handler = noop,
    .args = .{ .exact = 0 },
    .options = &.{.{
        .long = "retention",
        .kind = .value,
        .value_name = "0..1",
        .summary = "Desired retention",
    }},
};

const fsrs_retention_command: th.Command = .{
    .name = "retention",
    .summary = "Show current retention",
    .handler = noop,
    .args = .{ .exact = 0 },
};

const fsrs_command: th.Command = .{
    .name = "fsrs",
    .summary = "FSRS tools",
    .children = &.{
        &fsrs_optimize_command,
        &fsrs_evaluate_command,
        &fsrs_simulate_command,
        &fsrs_retention_command,
    },
};

const scheduler_list_command: th.Command = .{
    .name = "list",
    .summary = "List scheduler configuration",
    .handler = noop,
    .args = .{ .exact = 0 },
};

const scheduler_command: th.Command = .{
    .name = "scheduler",
    .summary = "Inspect scheduler configuration",
    .children = &.{&scheduler_list_command},
};

const backup_command: th.Command = .{
    .name = "backup",
    .summary = "Export a full-fidelity archive",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} },
};

const restore_command: th.Command = .{
    .name = "restore",
    .summary = "Restore a full-fidelity archive",
    .handler = noop,
    .args = .{ .exact = 0 },
    .options = &.{
        .{ .long = "dry-run", .exclusive_group = "restore-mode" },
        .{ .long = "yes", .exclusive_group = "restore-mode" },
    },
};

const media_add_command: th.Command = .{
    .name = "add",
    .summary = "Add a media file",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "path" }} },
};

const media_command: th.Command = .{
    .name = "media",
    .summary = "Manage media",
    .children = &.{&media_add_command},
};

const sack_export_command: th.Command = .{
    .name = "export",
    .summary = "Export a deck and media bundle",
    .handler = noop,
    .args = .{ .positionals = &.{ .{ .name = "deck-id" }, .{ .name = "output.sack" } } },
};

const sack_import_command: th.Command = .{
    .name = "import",
    .summary = "Import a deck and media bundle",
    .handler = noop,
    .args = .{ .positionals = &.{.{ .name = "input.sack" }} },
};

const sack_command: th.Command = .{
    .name = "sack",
    .summary = "Manage rich deck bundles",
    .children = &.{ &sack_export_command, &sack_import_command },
};

pub const root_command: th.Command = .{
    .name = "deez",
    .summary = "Drill, Evaluate, Encode, Zen",
    .children = &.{
        &setup_command,
        &decks_command,
        &nuts_command,
        &cards_command,
        &deck_command,
        &nut_command,
        &note_command,
        &notes_command,
        &card_command,
        &study_command,
        &stats_command,
        &inspect_command,
        &fsrs_command,
        &scheduler_command,
        &backup_command,
        &restore_command,
        &media_command,
        &sack_command,
    },
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

fn requireText(text: []const u8) ![]const u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
    return text;
}

fn parseStudyOrder(text: []const u8) !cli.StudyOrder {
    if (std.mem.eql(u8, text, "due")) return .due;
    if (std.mem.eql(u8, text, "reviews-first")) return .reviews_first;
    if (std.mem.eql(u8, text, "new-first")) return .new_first;
    return error.InvalidStudyOrder;
}

fn parseHelpTopic(text: []const u8) !cli.HelpTopic {
    if (std.mem.eql(u8, text, "deck") or std.mem.eql(u8, text, "decks")) return .deck;
    if (std.mem.eql(u8, text, "nut") or std.mem.eql(u8, text, "nuts")) return .nut;
    if (std.mem.eql(u8, text, "note") or std.mem.eql(u8, text, "notes")) return .note;
    if (std.mem.eql(u8, text, "card") or std.mem.eql(u8, text, "cards")) return .card;
    if (std.mem.eql(u8, text, "study")) return .study;
    if (std.mem.eql(u8, text, "stats")) return .stats;
    if (std.mem.eql(u8, text, "inspect")) return .inspect;
    if (std.mem.eql(u8, text, "fsrs")) return .fsrs;
    if (std.mem.eql(u8, text, "scheduler")) return .scheduler;
    return error.UnknownHelpTopic;
}

fn helpFor(command: *const th.Command) Help {
    if (command == &root_command or command == &setup_command) return .general;
    if (command == &decks_command or command == &deck_command or
        command == &deck_add_command or command == &deck_rename_command or
        command == &deck_delete_command or command == &deck_export_command or
        command == &deck_import_command)
    {
        return .{ .core = .deck };
    }
    if (command == &nuts_command or command == &nut_command or
        command == &nut_export_command or command == &nut_import_command)
    {
        return .{ .core = .nut };
    }
    if (command == &note_command or command == &note_add_command or command == &note_edit_command) {
        return .{ .core = .note };
    }
    if (command == &cards_command or command == &card_command or
        command == &card_add_command or command == &card_edit_command or command == &card_delete_command)
    {
        return .{ .core = .card };
    }
    if (command == &study_command) return .{ .core = .study };
    if (command == &stats_command) return .{ .core = .stats };
    if (command == &inspect_command) return .{ .core = .inspect };
    if (command == &fsrs_command or command == &fsrs_optimize_command or
        command == &fsrs_evaluate_command or command == &fsrs_simulate_command or
        command == &fsrs_retention_command)
    {
        return .{ .core = .fsrs };
    }
    if (command == &scheduler_command or command == &scheduler_list_command) return .{ .core = .scheduler };
    if (command == &backup_command or command == &restore_command) return .backup;
    if (command == &notes_command) return .notes;
    if (command == &media_command or command == &media_add_command or
        command == &sack_command or command == &sack_export_command or command == &sack_import_command)
    {
        return .rich;
    }
    return .general;
}

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Route {
    const args = if (argv.len > 0) argv[1..] else &.{};

    if (args.len > 0 and std.mem.eql(u8, args[0], "help")) {
        if (args.len == 1) return .{ .help = .general };
        if (args.len == 2) return .{ .help = .{ .core = try parseHelpTopic(args[1]) } };
        return error.InvalidArguments;
    }

    try th.validation.validate(&root_command);

    const selection = switch (th.resolve(&root_command, args)) {
        .help => |selected| return .{ .help = helpFor(selected.command) },
        .unknown => return error.UnknownCommand,
        .execute => |selected| selected,
    };

    var parsed = th.options.parseWithMode(
        allocator,
        selection.command.options,
        selection.args,
        selection.command.passthrough,
    ) catch return error.InvalidArguments;
    defer parsed.deinit();

    if (!selection.command.args.valid(parsed.positionals.len)) return error.InvalidArguments;

    const command = selection.command;
    const pos = parsed.positionals;

    if (command == &setup_command) return .setup;
    if (command == &backup_command) {
        if (pos.len == 1) _ = try parseId(pos[0]);
        return .backup_cli;
    }
    if (command == &restore_command) {
        if (!parsed.has("dry-run") and !parsed.has("yes")) return error.ConfirmationRequired;
        return .backup_cli;
    }
    if (command == &notes_command) {
        _ = try parseId(pos[0]);
        return .notes_cli;
    }
    if (command == &media_add_command or command == &sack_export_command or command == &sack_import_command) {
        if (command == &sack_export_command) _ = try parseId(pos[0]);
        return .rich_cli;
    }

    if (command == &decks_command or command == &nuts_command) return .{ .core = .decks };
    if (command == &cards_command) return .{ .core = .{ .cards = .{ .deck_id = try parseId(pos[0]) } } };
    if (command == &deck_add_command) return .{ .core = .{ .deck_add = .{ .name = try requireText(pos[0]) } } };
    if (command == &deck_rename_command) return .{ .core = .{ .deck_rename = .{
        .deck_id = try parseId(pos[0]),
        .name = try requireText(pos[1]),
    } } };
    if (command == &deck_delete_command) {
        if (!parsed.has("yes")) return error.ConfirmationRequired;
        return .{ .core = .{ .deck_delete = .{ .deck_id = try parseId(pos[0]) } } };
    }
    if (command == &deck_export_command) return .{ .core = .{ .deck_export = .{ .deck_id = try parseId(pos[0]) } } };
    if (command == &deck_import_command) return .{ .core = .{ .deck_import = .{ .path = try requireText(pos[0]) } } };
    if (command == &nut_export_command) return .{ .core = .{ .nut_export = .{ .deck_id = try parseId(pos[0]) } } };
    if (command == &nut_import_command) return .{ .core = .{ .nut_import = .{ .path = try requireText(pos[0]) } } };
    if (command == &note_add_command) return .{ .core = .{ .note_add = .{
        .deck_id = try parseId(pos[0]),
        .note_type = try requireText(pos[1]),
        .fields = selection.args[2..],
    } } };
    if (command == &note_edit_command) return .{ .core = .{ .note_edit = .{
        .deck_id = try parseId(pos[0]),
        .note_id = try parseId(pos[1]),
        .fields = selection.args[2..],
    } } };
    if (command == &card_add_command) return .{ .core = .{ .card_add = .{
        .deck_id = try parseId(pos[0]),
        .question = try requireText(pos[1]),
        .answer = try requireText(pos[2]),
    } } };
    if (command == &card_edit_command) return .{ .core = .{ .card_edit = .{
        .card_id = try parseId(pos[0]),
        .question = try requireText(pos[1]),
        .answer = try requireText(pos[2]),
    } } };
    if (command == &card_delete_command) {
        if (!parsed.has("yes")) return error.ConfirmationRequired;
        return .{ .core = .{ .card_delete = .{ .card_id = try parseId(pos[0]) } } };
    }
    if (command == &study_command) {
        const order = if (parsed.find("order")) |value| try parseStudyOrder(value) else cli.StudyOrder.due;
        const new_limit = if (parsed.find("new-limit")) |value| try parseCount(value) else null;
        return .{ .core = .{ .study = .{
            .deck_id = try parseId(pos[0]),
            .new_limit = new_limit,
            .order = order,
            .shuffle = parsed.has("shuffle"),
        } } };
    }
    if (command == &stats_command) return .{ .core = .{ .stats = .{
        .deck_id = if (pos.len == 1) try parseId(pos[0]) else null,
        .json = parsed.has("json"),
    } } };
    if (command == &inspect_command) return .{ .core = .{ .inspect = .{
        .card_id = try parseId(pos[0]),
        .json = parsed.has("json"),
    } } };
    if (command == &fsrs_optimize_command) return .{ .core = .{ .fsrs_optimize = .{
        .deck_id = if (pos.len == 1) try parseId(pos[0]) else null,
        .recency_half_life_days = if (parsed.has("recency")) 1.0 else null,
    } } };
    if (command == &fsrs_evaluate_command) return .{ .core = .{ .fsrs_evaluate = .{
        .deck_id = if (pos.len == 1) try parseId(pos[0]) else null,
    } } };
    if (command == &fsrs_simulate_command) return .{ .core = .{ .fsrs_simulate = .{
        .retention = if (parsed.find("retention")) |value| try parseFloat(value) else null,
    } } };
    if (command == &fsrs_retention_command) return .{ .core = .fsrs_retention };
    if (command == &scheduler_list_command) return .{ .core = .scheduler_list };

    return error.UnknownCommand;
}

pub fn errorHelp(argv: []const []const u8) Help {
    if (argv.len < 2) return .general;
    const command = argv[1];
    if (std.mem.eql(u8, command, "backup") or std.mem.eql(u8, command, "restore")) return .backup;
    if (std.mem.eql(u8, command, "notes")) return .notes;
    if (std.mem.eql(u8, command, "media") or std.mem.eql(u8, command, "sack")) return .rich;
    return .general;
}

test "Thrawn tree parses representative core commands" {
    const study_args = [_][]const u8{ "deez", "study", "42", "--new-limit", "10", "--order", "reviews-first", "--shuffle" };
    const study_route = try parse(std.testing.allocator, &study_args);
    try std.testing.expect(study_route == .core);
    try std.testing.expectEqual(@as(u64, 42), study_route.core.study.deck_id);
    try std.testing.expectEqual(@as(?usize, 10), study_route.core.study.new_limit);
    try std.testing.expectEqual(cli.StudyOrder.reviews_first, study_route.core.study.order);
    try std.testing.expect(study_route.core.study.shuffle);

    const deck_args = [_][]const u8{ "deez", "deck", "delete", "3", "--yes" };
    const deck_route = try parse(std.testing.allocator, &deck_args);
    try std.testing.expectEqual(@as(u64, 3), deck_route.core.deck_delete.deck_id);
}

test "Thrawn tree preserves deez nuts behavior" {
    const args = [_][]const u8{ "deez", "nuts" };
    const route = try parse(std.testing.allocator, &args);
    try std.testing.expect(route.core == .decks);
}

test "Thrawn tree routes streaming and rich commands" {
    const backup_args = [_][]const u8{ "deez", "backup", "42" };
    try std.testing.expect((try parse(std.testing.allocator, &backup_args)) == .backup_cli);

    const notes_args = [_][]const u8{ "deez", "notes", "1" };
    try std.testing.expect((try parse(std.testing.allocator, &notes_args)) == .notes_cli);

    const sack_args = [_][]const u8{ "deez", "sack", "import", "deck.sack" };
    try std.testing.expect((try parse(std.testing.allocator, &sack_args)) == .rich_cli);
}

test "Thrawn tree keeps confirmation and validation errors" {
    const unsafe = [_][]const u8{ "deez", "deck", "delete", "3" };
    try std.testing.expectError(error.ConfirmationRequired, parse(std.testing.allocator, &unsafe));

    const invalid_id = [_][]const u8{ "deez", "cards", "nope" };
    try std.testing.expectError(error.InvalidId, parse(std.testing.allocator, &invalid_id));

    const missing = [_][]const u8{ "deez", "study" };
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &missing));
}
