const std = @import("std");
const cli_tree = @import("cli_tree.zig");

test "note add variadic fields remain borrowed from caller argv" {
    const args = [_][]const u8{
        "deez",
        "note",
        "add",
        "3",
        "reverse",
        "France",
        "Paris",
    };

    const route = try cli_tree.parse(std.testing.allocator, &args);
    const fields = route.core.note_add.fields;

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields.ptr == args[5..].ptr);
    try std.testing.expectEqualStrings("France", fields[0]);
    try std.testing.expectEqualStrings("Paris", fields[1]);
}

test "note edit variadic fields remain borrowed from caller argv" {
    const args = [_][]const u8{
        "deez",
        "note",
        "edit",
        "3",
        "9",
        "France",
        "Paris",
    };

    const route = try cli_tree.parse(std.testing.allocator, &args);
    const fields = route.core.note_edit.fields;

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields.ptr == args[5..].ptr);
    try std.testing.expectEqualStrings("France", fields[0]);
    try std.testing.expectEqualStrings("Paris", fields[1]);
}
