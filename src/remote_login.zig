const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const default_base_url = "https://deez.run";
const cookie_name = "__Host-deez_session";
const max_http_body_bytes: usize = 16 * 1024 * 1024;

const CloudConfig = struct {
    version: u32 = 1,
    base_url: []const u8,
    session: []const u8,
};

const RawResponse = struct {
    status: u16,
    body: []u8,
    session: ?[]u8 = null,
};

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "login");
}

fn home(init: std.process.Init) ![]const u8 {
    return init.environ_map.get("HOME") orelse error.MissingHomeDirectory;
}

fn configDir(allocator: Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez", .{home_dir});
}

fn cloudConfigPath(allocator: Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez/cloud.json", .{home_dir});
}

fn writePrivateFile(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.createFileAbsolute(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    file.setPermissions(init.io, @enumFromInt(0o600)) catch {};
    try file.writeStreamingAll(init.io, bytes);
}

fn stringifyAlloc(allocator: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn saveCloudConfig(init: std.process.Init, value: CloudConfig) !void {
    const allocator = init.arena.allocator();
    const dir = try configDir(allocator, try home(init));
    try Io.Dir.cwd().createDirPath(init.io, dir);
    const path = try cloudConfigPath(allocator, try home(init));
    const bytes = try stringifyAlloc(allocator, value);
    try writePrivateFile(init, path, bytes);
}

fn readByte(io: Io) !u8 {
    var buffer: [1]u8 = undefined;
    var buffers = [_][]u8{buffer[0..]};
    const read = try Io.File.stdin().readStreaming(io, &buffers);
    if (read == 0) return error.EndOfStream;
    return buffer[0];
}

fn readLine(allocator: Allocator, io: Io) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = readByte(io) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte != '\r') try bytes.append(allocator, byte);
    }
    return bytes.toOwnedSlice(allocator);
}

fn extractSession(allocator: Allocator, head: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const prefix = cookie_name ++ "=";
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const rest = value[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        return try allocator.dupe(u8, rest[0..end]);
    }
    return null;
}

fn httpRequest(
    init: std.process.Init,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
) !RawResponse {
    const allocator = init.arena.allocator();
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    var headers: [3]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "Accept", .value = "application/json" };
    count += 1;
    headers[count] = .{ .name = "User-Agent", .value = "deez-cli/1" };
    count += 1;
    if (body != null) {
        headers[count] = .{ .name = "Content-Type", .value = "application/json" };
        count += 1;
    }

    const uri = try std.Uri.parse(url);
    var request = try client.request(method, uri, .{ .extra_headers = headers[0..count] });
    defer request.deinit();
    if (body) |bytes| {
        try request.sendBodyComplete(@constCast(bytes));
    } else {
        try request.sendBodiless();
    }

    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    const session = try extractSession(allocator, response.head.bytes);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const response_body = try reader.allocRemaining(allocator, .limited(max_http_body_bytes));
    return .{ .status = status, .body = response_body, .session = session };
}

fn requireSuccess(response: RawResponse) !void {
    if (response.status >= 200 and response.status < 300) return;
    std.log.err("deez.run returned HTTP {d}: {s}", .{ response.status, response.body });
    return error.CloudRequestFailed;
}

fn apiUrl(allocator: Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1{s}", .{ std.mem.trimEnd(u8, base_url, "/"), path });
}

fn baseUrl(init: std.process.Init) []const u8 {
    return init.environ_map.get("DEEZ_CLOUD_URL") orelse default_base_url;
}

fn parseMagicToken(input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 64) return trimmed;
    const marker = "token=";
    const start = (std.mem.indexOf(u8, trimmed, marker) orelse return error.InvalidMagicLink) + marker.len;
    var end = trimmed.len;
    if (std.mem.indexOfScalarPos(u8, trimmed, start, '&')) |index| end = @min(end, index);
    if (std.mem.indexOfScalarPos(u8, trimmed, start, '#')) |index| end = @min(end, index);
    const token = trimmed[start..end];
    if (token.len != 64) return error.InvalidMagicLink;
    return token;
}

fn cloudConfigFromConsumed(base_url: []const u8, consumed: RawResponse) !CloudConfig {
    return .{
        .base_url = base_url,
        .session = consumed.session orelse return error.MissingCloudSession,
    };
}

fn login(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    const allocator = init.arena.allocator();
    const base = baseUrl(init);
    const request_url = try apiUrl(allocator, base, "/auth/magic-link");
    const request_body = try stringifyAlloc(allocator, .{ .email = args[2] });
    const requested = try httpRequest(init, .POST, request_url, request_body);
    try requireSuccess(requested);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.print("Magic link sent to {s}.\nPaste the link from the email here (it is read only by this process): ", .{args[2]});
    try out.flush();

    const line = try readLine(allocator, init.io);
    const token = try parseMagicToken(line);
    const consume_url = try apiUrl(allocator, base, "/auth/magic/consume");
    const consume_body = try stringifyAlloc(allocator, .{ .token = token });
    const consumed = try httpRequest(init, .POST, consume_url, consume_body);
    try requireSuccess(consumed);

    // The session cookie is the durable result of a successful magic-link consume.
    // Persist it before interpreting any optional response body. This intentionally
    // avoids making login depend on the consume endpoint's JSON representation.
    const cloud = try cloudConfigFromConsumed(base, consumed);
    try saveCloudConfig(init, cloud);

    try out.print("Signed in as {s}.\n", .{args[2]});
    try out.flush();
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (!isCommand(args)) return error.InvalidArguments;
    return login(init, args);
}

test "magic-link parser accepts raw tokens and full URLs" {
    const raw = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqualStrings(raw, try parseMagicToken(raw));
    const url = "https://deez.run/auth/magic?token=" ++ raw;
    try std.testing.expectEqualStrings(raw, try parseMagicToken(url));
}

test "session extraction accepts hosted auth cookie" {
    const head = "HTTP/1.1 200 OK\r\nset-cookie: __Host-deez_session=abc123; Path=/; Secure; HttpOnly\r\n\r\n";
    const session = (try extractSession(std.testing.allocator, head)).?;
    defer std.testing.allocator.free(session);
    try std.testing.expectEqualStrings("abc123", session);
}

test "successful consume does not require a JSON response body" {
    var body = [_]u8{ '<', 'h', 't', 'm', 'l', '>' };
    var session = [_]u8{ 's', 'e', 's', 's', 'i', 'o', 'n' };
    const cloud = try cloudConfigFromConsumed("https://deez.run", .{
        .status = 200,
        .body = body[0..],
        .session = session[0..],
    });
    try std.testing.expectEqualStrings("https://deez.run", cloud.base_url);
    try std.testing.expectEqualStrings("session", cloud.session);
}
