const std = @import("std");
const Io = std.Io;
const deez = @import("deez");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;

    const command = deez.cli.parse(args) catch |err| {
        var stderr_buffer: [2048]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;
        try stderr.print("deez: {s}\n\n{s}", .{ @errorName(err), deez.cli.help_text });
        try stderr.flush();
        return;
    };

    try deez.app.run(init, command);
}

test {
    std.testing.refAllDecls(deez);
}
