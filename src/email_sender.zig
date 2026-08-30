const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{EmailDeliveryFailed};

/// Provider-neutral email boundary used by hosted authentication.
/// Production uses the narrow HTTP relay. Tests can inject Recording without
/// AWS, network access, or credentials.
pub const Sender = union(enum) {
    relay: Relay,
    recording: *Recording,

    pub fn send(
        self: *Sender,
        allocator: Allocator,
        to: []const u8,
        magic_link: []const u8,
    ) !void {
        switch (self.*) {
            .relay => |*relay| try relay.send(allocator, to, magic_link),
            .recording => |recording| try recording.send(to, magic_link),
        }
    }
};

pub const Relay = struct {
    io: Io,
    allocator: Allocator,
    endpoint: []const u8,
    bearer_token: []const u8,

    pub fn send(
        self: *Relay,
        allocator: Allocator,
        to: []const u8,
        magic_link: []const u8,
    ) !void {
        // `to` is normalized by hosted_auth and magic_link is generated from a
        // fixed trusted origin plus a hex token, so neither value can inject JSON.
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"to\":\"{s}\",\"magic_link\":\"{s}\"}}",
            .{ to, magic_link },
        );
        defer allocator.free(body);

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.bearer_token});
        defer allocator.free(auth_header);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "deez.run/1" },
        };
        const uri = std.Uri.parse(self.endpoint) catch return error.EmailDeliveryFailed;
        var request = client.request(.POST, uri, .{ .extra_headers = &headers }) catch return error.EmailDeliveryFailed;
        defer request.deinit();
        request.sendBodyComplete(body) catch return error.EmailDeliveryFailed;
        var redirect_buffer: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect_buffer) catch return error.EmailDeliveryFailed;
        const status = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) return error.EmailDeliveryFailed;
    }
};

pub const Recording = struct {
    allocator: Allocator,
    calls: usize = 0,
    last_to: ?[]u8 = null,
    last_magic_link: ?[]u8 = null,

    pub fn init(allocator: Allocator) Recording {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Recording) void {
        if (self.last_to) |value| self.allocator.free(value);
        if (self.last_magic_link) |value| self.allocator.free(value);
        self.* = .{ .allocator = self.allocator };
    }

    fn send(self: *Recording, to: []const u8, magic_link: []const u8) !void {
        if (self.last_to) |value| self.allocator.free(value);
        if (self.last_magic_link) |value| self.allocator.free(value);
        self.last_to = try self.allocator.dupe(u8, to);
        errdefer {
            self.allocator.free(self.last_to.?);
            self.last_to = null;
        }
        self.last_magic_link = try self.allocator.dupe(u8, magic_link);
        self.calls += 1;
    }
};

test "recording sender captures the narrow magic-link payload" {
    var recording = Recording.init(std.testing.allocator);
    defer recording.deinit();
    var sender: Sender = .{ .recording = &recording };

    try sender.send(
        std.testing.allocator,
        "person@example.com",
        "https://deez.run/auth/magic?token=abc123",
    );

    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqualStrings("person@example.com", recording.last_to.?);
    try std.testing.expectEqualStrings(
        "https://deez.run/auth/magic?token=abc123",
        recording.last_magic_link.?,
    );
}
