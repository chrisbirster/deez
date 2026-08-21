const std = @import("std");
const Io = std.Io;
const deez = @import("deez");

fn printErrorAndExit(init: std.process.Init, err: anyerror, help: []const u8) noreturn {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    stderr.print("deez: {s}\n\n{s}", .{ @errorName(err), help }) catch {};
    stderr.flush() catch {};
    std.process.exit(2);
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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;

    if (deez.backup_cli.isCommand(args)) {
        deez.backup_cli.run(init, args) catch |err| {
            if (isBackupUsageError(err)) printErrorAndExit(init, err, deez.backup_cli.help_text);
            return err;
        };
        return;
    }

    const command = deez.cli.parse(args) catch |err| {
        var help_buffer: [8192]u8 = undefined;
        var writer = Io.Writer.fixed(&help_buffer);
        writer.print("{s}\n{s}", .{ deez.cli.help_text, deez.backup_cli.help_text }) catch
            printErrorAndExit(init, err, deez.cli.help_text);
        printErrorAndExit(init, err, writer.buffered());
    };

    try deez.app.run(init, command);
}

test {
    std.testing.refAllDecls(deez);
}
