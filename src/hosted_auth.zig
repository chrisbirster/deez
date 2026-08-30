const std = @import("std");
const bongo = @import("bongo");
const mongodb = @import("storage/mongodb.zig");
const media = @import("media.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const q = bongo.query;

pub const magic_link_ttl_ms: i64 = 15 * 60 * 1000;
pub const session_idle_ttl_ms: i64 = 7 * 24 * 60 * 60 * 1000;
pub const session_absolute_ttl_ms: i64 = 30 * 24 * 60 * 60 * 1000;
pub const session_touch_interval_ms: i64 = 5 * 60 * 1000;
pub const session_cookie_refresh_ms: i64 = 24 * 60 * 60 * 1000;
pub const magic_link_min_interval_ms: i64 = 60 * 1000;
pub const cookie_name = "__Host-deez_session";

pub const Error = error{
    InvalidEmail,
    InvalidUsername,
    UsernameUnavailable,
    InvalidMagicLink,
    ExpiredMagicLink,
    UsedMagicLink,
    InvalidSession,
    ExpiredSession,
    EmailDeliveryFailed,
    MissingHostedAuthConfiguration,
};

pub const Config = struct {
    base_url: []const u8,
    resend_api_key: []const u8,
    from_email: []const u8,
};

pub const User = struct {
    id: []const u8,
    email: []const u8,
    username: ?[]const u8,
};

pub const SessionResult = struct {
    user: User,
    refresh_cookie: bool,
};

pub const LoginResult = struct {
    user: User,
    session_token: []const u8,
    is_new_user: bool,
};

pub const Service = struct {
    io: Io,
    allocator: Allocator,
    mongo: *mongodb.Store,
    config: Config,

    pub fn init(io: Io, allocator: Allocator, mongo: *mongodb.Store, config: Config) Service {
        return .{ .io = io, .allocator = allocator, .mongo = mongo, .config = config };
    }

    fn database(self: *Service) []const u8 {
        return self.mongo.client.databaseName();
    }

    pub fn requestMagicLink(self: *Service, allocator: Allocator, raw_email: []const u8, now_ms: i64) !void {
        const email = try normalizeEmail(allocator, raw_email);
        defer allocator.free(email);

        var throttle = try self.mongo.client.findOne(self.database(), "auth_magic_rate", .{ ._id = email });
        if (throttle) |*owned| {
            defer owned.deinit();
            const last_sent_at_ms = try requiredI64(owned.bytes, "last_sent_at_ms");
            if (now_ms - last_sent_at_ms < magic_link_min_interval_ms) return;
        }

        var token_bytes: [32]u8 = undefined;
        try self.io.randomSecure(&token_bytes);
        var token_hex: [64]u8 = undefined;
        hexEncode(&token_bytes, &token_hex);
        const token = token_hex[0..];
        const token_hash = tokenHashHex(token);

        _ = try self.mongo.client.insertOne(self.database(), "auth_magic_links", .{
            ._id = token_hash[0..],
            .email = email,
            .created_at_ms = now_ms,
            .expires_at_ms = now_ms + magic_link_ttl_ms,
            .used_at_ms = @as(?i64, null),
        });

        var rate_result = try self.mongo.client.updateOne(
            self.database(),
            "auth_magic_rate",
            .{ ._id = email },
            q.set(.{ .last_sent_at_ms = now_ms }),
            true,
        );
        rate_result.deinit();

        try self.sendMagicLink(allocator, email, token);
    }

    pub fn consumeMagicLink(self: *Service, allocator: Allocator, token: []const u8, now_ms: i64) !LoginResult {
        if (!isToken(token)) return error.InvalidMagicLink;
        const token_hash = tokenHashHex(token);
        var magic = (try self.mongo.client.findOne(
            self.database(),
            "auth_magic_links",
            .{ ._id = token_hash[0..] },
        )) orelse return error.InvalidMagicLink;
        defer magic.deinit();

        if ((try optionalI64(magic.bytes, "used_at_ms")) != null) return error.UsedMagicLink;
        if (try requiredI64(magic.bytes, "expires_at_ms") < now_ms) return error.ExpiredMagicLink;
        const email = try allocator.dupe(u8, try requiredString(magic.bytes, "email"));

        var used = try self.mongo.client.updateOne(
            self.database(),
            "auth_magic_links",
            .{ ._id = token_hash[0..], .used_at_ms = @as(?i64, null) },
            q.set(.{ .used_at_ms = @as(?i64, now_ms) }),
            false,
        );
        defer used.deinit();
        if (used.matched_count != 1) return error.UsedMagicLink;

        const existing = try self.findUserByEmail(allocator, email);
        const is_new = existing == null;
        const user = if (existing) |value| value else try self.createUser(allocator, email, now_ms);
        const session_token = try self.createSession(allocator, user.id, now_ms);
        return .{ .user = user, .session_token = session_token, .is_new_user = is_new };
    }

    pub fn resolveSession(self: *Service, allocator: Allocator, token: []const u8, now_ms: i64) !SessionResult {
        if (!isToken(token)) return error.InvalidSession;
        const token_hash = tokenHashHex(token);
        var session = (try self.mongo.client.findOne(
            self.database(),
            "auth_sessions",
            .{ ._id = token_hash[0..] },
        )) orelse return error.InvalidSession;
        defer session.deinit();

        if ((try optionalI64(session.bytes, "revoked_at_ms")) != null) return error.InvalidSession;
        const last_seen_at_ms = try requiredI64(session.bytes, "last_seen_at_ms");
        const absolute_expires_at_ms = try requiredI64(session.bytes, "absolute_expires_at_ms");
        if (now_ms - last_seen_at_ms > session_idle_ttl_ms or now_ms > absolute_expires_at_ms) {
            try self.revokeSessionHash(token_hash[0..], now_ms);
            return error.ExpiredSession;
        }

        const user_id = try requiredString(session.bytes, "user_id");
        const user = (try self.findUserById(allocator, user_id)) orelse return error.InvalidSession;
        const refreshed_at_ms = (try optionalI64(session.bytes, "cookie_refreshed_at_ms")) orelse last_seen_at_ms;
        const should_touch = now_ms - last_seen_at_ms >= session_touch_interval_ms;
        const should_refresh = now_ms - refreshed_at_ms >= session_cookie_refresh_ms;

        if (should_touch or should_refresh) {
            var update = try self.mongo.client.updateOne(
                self.database(),
                "auth_sessions",
                .{ ._id = token_hash[0..] },
                q.set(.{
                    .last_seen_at_ms = if (should_touch) now_ms else last_seen_at_ms,
                    .cookie_refreshed_at_ms = if (should_refresh) now_ms else refreshed_at_ms,
                }),
                false,
            );
            update.deinit();
        }

        return .{ .user = user, .refresh_cookie = should_refresh };
    }

    pub fn revokeSession(self: *Service, token: []const u8, now_ms: i64) !void {
        if (!isToken(token)) return;
        const token_hash = tokenHashHex(token);
        try self.revokeSessionHash(token_hash[0..], now_ms);
    }

    pub fn revokeAllSessions(self: *Service, user_id: []const u8, now_ms: i64) !void {
        var cursor = try self.mongo.client.find(
            self.database(),
            "auth_sessions",
            .{ .user_id = user_id, .revoked_at_ms = @as(?i64, null) },
            .{},
        );
        defer cursor.deinit();
        while (try cursor.next()) |document| {
            const hash = try requiredString(document, "_id");
            try self.revokeSessionHash(hash, now_ms);
        }
    }

    pub fn claimUsername(self: *Service, allocator: Allocator, user_id: []const u8, raw_username: []const u8, now_ms: i64) !User {
        const username = try normalizeUsername(allocator, raw_username);
        defer allocator.free(username);

        var existing = try self.mongo.client.findOne(self.database(), "auth_usernames", .{ ._id = username });
        if (existing) |*owned| {
            defer owned.deinit();
            const owner = try requiredString(owned.bytes, "user_id");
            if (!std.mem.eql(u8, owner, user_id)) return error.UsernameUnavailable;
        } else {
            _ = try self.mongo.client.insertOne(self.database(), "auth_usernames", .{
                ._id = username,
                .user_id = user_id,
                .created_at_ms = now_ms,
            });
        }

        var updated = try self.mongo.client.updateOne(
            self.database(),
            "auth_users",
            .{ ._id = user_id },
            q.set(.{ .username = @as(?[]const u8, username), .updated_at_ms = now_ms }),
            false,
        );
        updated.deinit();
        return (try self.findUserById(allocator, user_id)) orelse error.InvalidSession;
    }

    pub fn assignDeck(self: *Service, user_id: []const u8, deck_id: u64, now_ms: i64) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ user_id, deck_id });
        defer self.allocator.free(key);
        var existing = try self.mongo.client.findOne(self.database(), "auth_deck_owners", .{ ._id = key });
        if (existing) |*owned| {
            owned.deinit();
            return;
        }
        _ = try self.mongo.client.insertOne(self.database(), "auth_deck_owners", .{
            ._id = key,
            .user_id = user_id,
            .deck_id = @as(i64, @intCast(deck_id)),
            .created_at_ms = now_ms,
        });
    }

    pub fn ownsDeck(self: *Service, user_id: []const u8, deck_id: u64) !bool {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ user_id, deck_id });
        defer self.allocator.free(key);
        var owned = try self.mongo.client.findOne(self.database(), "auth_deck_owners", .{ ._id = key });
        if (owned) |*document| document.deinit();
        return owned != null;
    }

    pub fn ownedDeckIds(self: *Service, allocator: Allocator, user_id: []const u8) ![]u64 {
        var cursor = try self.mongo.client.find(
            self.database(),
            "auth_deck_owners",
            .{ .user_id = user_id },
            .{ .sort = .{ .deck_id = @as(i32, 1) } },
        );
        defer cursor.deinit();
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        while (try cursor.next()) |document| {
            try ids.append(allocator, @intCast(try requiredI64(document, "deck_id")));
        }
        return ids.toOwnedSlice(allocator);
    }

    fn createUser(self: *Service, allocator: Allocator, email: []const u8, now_ms: i64) !User {
        var id_bytes: [16]u8 = undefined;
        try self.io.randomSecure(&id_bytes);
        var id_hex: [32]u8 = undefined;
        hexEncode(&id_bytes, &id_hex);
        const id = id_hex[0..];
        _ = try self.mongo.client.insertOne(self.database(), "auth_users", .{
            ._id = id,
            .email = email,
            .username = @as(?[]const u8, null),
            .email_verified_at_ms = now_ms,
            .created_at_ms = now_ms,
            .updated_at_ms = now_ms,
        });
        _ = try self.mongo.client.insertOne(self.database(), "auth_emails", .{
            ._id = email,
            .user_id = id,
        });
        return .{
            .id = try allocator.dupe(u8, id),
            .email = try allocator.dupe(u8, email),
            .username = null,
        };
    }

    fn findUserByEmail(self: *Service, allocator: Allocator, email: []const u8) !?User {
        var index = (try self.mongo.client.findOne(self.database(), "auth_emails", .{ ._id = email })) orelse return null;
        defer index.deinit();
        return self.findUserById(allocator, try requiredString(index.bytes, "user_id"));
    }

    pub fn findUserById(self: *Service, allocator: Allocator, user_id: []const u8) !?User {
        var owned = (try self.mongo.client.findOne(self.database(), "auth_users", .{ ._id = user_id })) orelse return null;
        defer owned.deinit();
        const document = owned.bytes;
        return .{
            .id = try allocator.dupe(u8, try requiredString(document, "_id")),
            .email = try allocator.dupe(u8, try requiredString(document, "email")),
            .username = if (try optionalString(document, "username")) |value| try allocator.dupe(u8, value) else null,
        };
    }

    fn createSession(self: *Service, allocator: Allocator, user_id: []const u8, now_ms: i64) ![]const u8 {
        var token_bytes: [32]u8 = undefined;
        try self.io.randomSecure(&token_bytes);
        var token_hex: [64]u8 = undefined;
        hexEncode(&token_bytes, &token_hex);
        const hash = tokenHashHex(token_hex[0..]);
        _ = try self.mongo.client.insertOne(self.database(), "auth_sessions", .{
            ._id = hash[0..],
            .user_id = user_id,
            .created_at_ms = now_ms,
            .last_seen_at_ms = now_ms,
            .cookie_refreshed_at_ms = now_ms,
            .absolute_expires_at_ms = now_ms + session_absolute_ttl_ms,
            .revoked_at_ms = @as(?i64, null),
        });
        return allocator.dupe(u8, token_hex[0..]);
    }

    fn revokeSessionHash(self: *Service, hash: []const u8, now_ms: i64) !void {
        var update = try self.mongo.client.updateOne(
            self.database(),
            "auth_sessions",
            .{ ._id = hash },
            q.set(.{ .revoked_at_ms = @as(?i64, now_ms) }),
            false,
        );
        update.deinit();
    }

    fn sendMagicLink(self: *Service, allocator: Allocator, email: []const u8, token: []const u8) !void {
        const link = try std.fmt.allocPrint(allocator, "{s}/auth/magic?token={s}", .{ self.config.base_url, token });
        defer allocator.free(link);
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"from\":\"{s}\",\"to\":[\"{s}\"],\"subject\":\"Sign in to Deez\",\"text\":\"Sign in to Deez:\\n\\n{s}\\n\\nThis link expires in 15 minutes. If you did not request it, you can ignore this email.\"}}",
            .{ self.config.from_email, email, link },
        );
        defer allocator.free(body);
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.resend_api_key});
        defer allocator.free(auth_header);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "deez.run/1" },
        };
        const uri = try std.Uri.parse("https://api.resend.com/emails");
        var request = try client.request(.POST, uri, .{ .extra_headers = &headers });
        defer request.deinit();
        try request.sendBodyComplete(body);
        var redirect_buffer: [4096]u8 = undefined;
        const response = try request.receiveHead(&redirect_buffer);
        const status = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) return error.EmailDeliveryFailed;
    }
};

pub fn normalizeEmail(allocator: Allocator, input: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len < 3 or trimmed.len > 254) return error.InvalidEmail;
    var at_count: usize = 0;
    var at_index: usize = 0;
    for (trimmed, 0..) |byte, index| {
        if (byte == '@') {
            at_count += 1;
            at_index = index;
            continue;
        }
        if (byte <= 0x20 or byte >= 0x7f or byte == '"' or byte == '\\') return error.InvalidEmail;
    }
    if (at_count != 1 or at_index == 0 or at_index + 1 >= trimmed.len) return error.InvalidEmail;
    if (std.mem.indexOfScalar(u8, trimmed[at_index + 1 ..], '.') == null) return error.InvalidEmail;
    const result = try allocator.dupe(u8, trimmed);
    for (result) |*byte| byte.* = std.ascii.toLower(byte.*);
    return result;
}

pub fn normalizeUsername(allocator: Allocator, input: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len < 3 or trimmed.len > 32) return error.InvalidUsername;
    const result = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(result);
    for (result) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
        if (!(std.ascii.isAlphanumeric(byte.*) or byte.* == '_' or byte.* == '-')) return error.InvalidUsername;
    }
    const reserved = [_][]const u8{ "admin", "api", "app", "auth", "docs", "login", "logout", "nuts", "publish", "search", "settings", "support" };
    for (reserved) |name| if (std.mem.eql(u8, result, name)) return error.InvalidUsername;
    return result;
}

fn isToken(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn tokenHashHex(token: []const u8) [64]u8 {
    return media.sha256Hex(token);
}

fn hexEncode(bytes: []const u8, output: []u8) void {
    std.debug.assert(output.len == bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        output[index * 2] = std.fmt.hex_charset[byte >> 4];
        output[index * 2 + 1] = std.fmt.hex_charset[byte & 0x0f];
    }
}

fn requiredString(document: []const u8, field: []const u8) ![]const u8 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.InvalidSession;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidSession,
    };
}

fn optionalString(document: []const u8, field: []const u8) !?[]const u8 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return null;
    if (value == .null_value) return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidSession,
    };
}

fn requiredI64(document: []const u8, field: []const u8) !i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.InvalidSession;
    return switch (value) {
        .int64 => |number| number,
        .int32 => |number| number,
        else => error.InvalidSession,
    };
}

fn optionalI64(document: []const u8, field: []const u8) !?i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return null;
    if (value == .null_value) return null;
    return switch (value) {
        .int64 => |number| number,
        .int32 => |number| number,
        else => error.InvalidSession,
    };
}

test "email normalization is lowercase and conservative" {
    const value = try normalizeEmail(std.testing.allocator, "  Chris+deez@Example.COM ");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("chris+deez@example.com", value);
    try std.testing.expectError(error.InvalidEmail, normalizeEmail(std.testing.allocator, "no-at.example.com"));
}

test "username normalization reserves application routes" {
    const value = try normalizeUsername(std.testing.allocator, "ChrisDontMiss");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("chrisdontmiss", value);
    try std.testing.expectError(error.InvalidUsername, normalizeUsername(std.testing.allocator, "api"));
    try std.testing.expectError(error.InvalidUsername, normalizeUsername(std.testing.allocator, "bad name"));
}
