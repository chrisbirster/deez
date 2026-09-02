const std = @import("std");
const Io = std.Io;
const deez = @import("deez");

fn writeHelp(out: *Io.Writer, target: deez.thrawn_cli.Help) !void {
    switch (target) {
        .general => try out.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
            deez.cli.help_text,
            deez.author_cli.help_text,
            deez.edit_cli.help_text,
            deez.stats_cli.help_text,
            deez.notes_cli.help_text,
            deez.backup_cli.help_text,
            deez.rich_cli.help_text,
            deez.remote_cli.help_text,
            deez.web_cli.help_text,
            deez.server.help_text,
        }),
        .core => |topic| try out.writeAll(deez.cli.helpText(topic)),
        .backup => try out.writeAll(deez.backup_cli.help_text),
        .notes => try out.writeAll(deez.notes_cli.help_text),
        .rich => try out.writeAll(deez.rich_cli.help_text),
    }
}

fn printErrorAndExit(init: std.process.Init, err: anyerror, help: deez.thrawn_cli.Help) noreturn {
    var stderr_buffer: [16384]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    stderr.print("deez: {s}\n\n", .{@errorName(err)}) catch {};
    writeHelp(stderr, help) catch {};
    stderr.flush() catch {};
    std.process.exit(2);
}

fn printRawErrorAndExit(init: std.process.Init, err: anyerror, help: []const u8) noreturn {
    var stderr_buffer: [16384]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    stderr.print("deez: {s}\n\n{s}", .{ @errorName(err), help }) catch {};
    stderr.flush() catch {};
    std.process.exit(2);
}

fn printHelp(init: std.process.Init, help: deez.thrawn_cli.Help) !void {
    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try writeHelp(out, help);
}

fn isBackupUsageError(err: anyerror) bool {
    return switch (err) {
        error.InvalidArguments,
        error.InvalidId,
        error.ConfirmationRequired,
        error.UnknownCommand,
        => true,
        else => false,
    };
}

fn isLegacyOptionalReverseAuthoring(args: []const []const u8) bool {
    return args.len >= 5 and
        std.mem.eql(u8, args[1], "note") and
        std.mem.eql(u8, args[2], "add") and
        std.mem.eql(u8, args[4], "optional-reverse");
}

fn runGuardedSync(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 2) printRawErrorAndExit(init, error.InvalidArguments, deez.remote_cli.help_text);
    const deletions = deez.sync_guard.prepare(init) catch |err| switch (err) {
        error.NotLoggedIn,
        error.SyncAccountMismatch,
        error.SyncDeletionConflict,
        error.InvalidSyncState,
        => printRawErrorAndExit(init, err, deez.remote_cli.help_text),
        else => return err,
    };

    deez.remote_cli.run(init, args) catch |err| switch (err) {
        error.InvalidArguments,
        error.InvalidMagicLink,
        error.NotLoggedIn,
        error.MissingCloudSession,
        => printRawErrorAndExit(init, err, deez.remote_cli.help_text),
        else => return err,
    };
    try deez.sync_guard.seal(init);

    if (deletions.total() != 0) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        const out = &stdout_file_writer.interface;
        defer out.flush() catch {};
        try out.print(
            "Deleted during sync: local {d} decks/{d} notes, cloud {d} decks/{d} notes.\n",
            .{
                deletions.deleted_local_decks,
                deletions.deleted_local_notes,
                deletions.deleted_remote_decks,
                deletions.deleted_remote_notes,
            },
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;

    if (deez.server.isCommand(args)) {
        deez.server.runCommand(init, args) catch |err|
            printRawErrorAndExit(init, err, deez.server.help_text);
        return;
    }

    if (deez.web_cli.isCommand(args)) {
        deez.web_cli.run(init, args) catch |err| {
            switch (err) {
                error.InvalidArguments, error.InvalidPort => printRawErrorAndExit(init, err, deez.web_cli.help_text),
                else => return err,
            }
        };
        return;
    }

    if (deez.sync_guard.isSyncCommand(args)) {
        return runGuardedSync(init, args);
    }

    if (deez.remote_cli.isCommand(args)) {
        deez.remote_cli.run(init, args) catch |err| {
            switch (err) {
                error.InvalidArguments,
                error.InvalidMagicLink,
                error.NotLoggedIn,
                error.MissingCloudSession,
                => printRawErrorAndExit(init, err, deez.remote_cli.help_text),
                else => return err,
            }
        };
        return;
    }

    if (deez.stats_cli.isCommand(args)) {
        deez.stats_cli.run(init, args) catch |err| {
            switch (err) {
                error.InvalidArguments, error.InvalidId, error.InvalidStatsWindow => printRawErrorAndExit(init, err, deez.stats_cli.help_text),
                else => return err,
            }
        };
        return;
    }

    if (deez.author_cli.isCommand(args)) {
        deez.author_cli.run(init, args) catch |err| {
            switch (err) {
                error.InvalidArguments, error.InvalidId, error.DeckNotFound => printRawErrorAndExit(init, err, deez.author_cli.help_text),
                else => return err,
            }
        };
        return;
    }

    if (deez.edit_cli.isCommand(args)) {
        deez.edit_cli.run(init, args) catch |err| {
            switch (err) {
                error.InvalidArguments,
                error.InvalidId,
                error.DeckNotFound,
                error.NoteNotFound,
                error.NoDecks,
                error.NoEditableNotes,
                => printRawErrorAndExit(init, err, deez.edit_cli.help_text),
                else => return err,
            }
        };
        return;
    }

    if (isLegacyOptionalReverseAuthoring(args)) {
        printRawErrorAndExit(init, error.UnknownNoteType, deez.cli.helpText(.note));
    }

    var route = deez.thrawn_cli.parse(arena, args) catch |err| {
        printErrorAndExit(init, err, deez.thrawn_cli.errorHelp(args));
    };
    defer route.deinit(arena);

    switch (route) {
        .help => |help| try printHelp(init, help),
        .setup => try deez.config.setup(init),
        .core => |command| try deez.app.run(init, command),
        .backup_cli => {
            deez.backup_cli.run(init, args) catch |err| {
                if (isBackupUsageError(err)) printErrorAndExit(init, err, .backup);
                return err;
            };
        },
        .notes_cli => {
            deez.notes_cli.run(init, args) catch |err| {
                switch (err) {
                    error.InvalidArguments, error.InvalidId => printErrorAndExit(init, err, .notes),
                    else => return err,
                }
            };
        },
        .rich_cli => {
            deez.rich_cli.run(init, args) catch |err| {
                switch (err) {
                    error.InvalidArguments, error.InvalidId, error.UnknownCommand => printErrorAndExit(init, err, .rich),
                    else => return err,
                }
            };
        },
    }
}

test {
    std.testing.refAllDecls(deez);
}
