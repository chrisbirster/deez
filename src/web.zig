const std = @import("std");
const httpz = @import("httpz");
const content = @import("content.zig");

pub const default_port: u16 = 49317;
pub const api_version = "v1";
pub const version = std.mem.trim(u8, @embedFile("../VERSION"), " \t\r\n");

pub const Options = struct {
    port: u16 = default_port,
};

const CapabilityField = struct {
    ordinal: content.FieldOrdinal,
    name: []const u8,
};

const CapabilityNoteType = struct {
    id: []const u8,
    slug: []const u8,
    name: []const u8,
    fields: []const CapabilityField,
};

const Handler = struct {
    port: u16,

    pub fn dispatch(
        self: *Handler,
        action: httpz.Action(*Handler),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        if (!isAllowedHost(req.header("host"), self.port) or
            !isAllowedOrigin(req.header("origin"), self.port))
        {
            forbidden(res);
            return;
        }
        try action(self, req, res);
    }

    pub fn notFound(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.content_type = .JSON;
        res.body = "{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}";
    }

    pub fn uncaughtError(_: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("web request failed path={s} error={}", .{ req.url.path, err });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}";
    }
};

pub fn run(init: std.process.Init, options: Options) !void {
    if (options.port == 0) return error.InvalidPort;

    var handler: Handler = .{ .port = options.port };
    var server = try httpz.Server(*Handler).init(init.io, init.gpa, .{
        .address = .localhost(options.port),
        .workers = .{
            .max_conn = 64,
        },
        .request = .{
            .max_body_size = 1024 * 1024,
            .max_header_count = 32,
            .max_param_count = 16,
            .max_query_count = 32,
            .max_form_count = 16,
        },
        .response = .{
            .max_header_count = 32,
        },
        .timeout = .{
            .request = 10,
            .keepalive = 15,
            .request_count = 100,
        },
    }, &handler);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/version", versionInfo, .{});
    router.get("/api/v1/capabilities", capabilities, .{});

    std.debug.print("Deez Web API listening on http://127.0.0.1:{d}/\n", .{options.port});
    try server.listen();
}

fn health(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .status = "ok" }, .{});
}

fn versionInfo(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{
        .version = version,
        .api_version = api_version,
    }, .{});
}

fn capabilities(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const note_types = try res.arena.alloc(CapabilityNoteType, content.built_in_note_types.len);
    for (content.built_in_note_types, 0..) |definition, index| {
        const fields = try res.arena.alloc(CapabilityField, definition.fields.len);
        for (definition.fields, 0..) |field, field_index| {
            fields[field_index] = .{
                .ordinal = field.ordinal,
                .name = field.name,
            };
        }
        note_types[index] = .{
            .id = try std.fmt.allocPrint(res.arena, "{d}", .{definition.id}),
            .slug = definition.slug,
            .name = definition.name,
            .fields = fields,
        };
    }

    const interactions = [_][]const u8{
        "reveal",
        "type_answer",
        "single_choice",
        "multiple_choice",
        "ordering",
        "image_occlusion",
    };
    const formats = [_][]const u8{ "nut", "sack" };

    try res.json(.{
        .api_version = api_version,
        .note_types = note_types,
        .interactions = &interactions,
        .import_formats = &formats,
        .export_formats = &formats,
    }, .{});
}

fn forbidden(res: *httpz.Response) void {
    res.status = 403;
    res.content_type = .JSON;
    res.body = "{\"error\":{\"code\":\"forbidden_origin\",\"message\":\"Request is not from the local Deez Web origin\"}}";
}

fn isAllowedHost(value: ?[]const u8, port: u16) bool {
    const host = value orelse return false;
    const colon = std.mem.lastIndexOfScalar(u8, host, ':') orelse return false;
    if (colon == 0 or colon + 1 >= host.len) return false;

    const name = host[0..colon];
    const parsed_port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return false;
    if (parsed_port != port) return false;

    return std.mem.eql(u8, name, "127.0.0.1") or std.ascii.eqlIgnoreCase(name, "localhost");
}

fn isAllowedOrigin(value: ?[]const u8, port: u16) bool {
    const origin = value orelse return true;
    const prefix = "http://";
    if (!std.mem.startsWith(u8, origin, prefix)) return false;
    return isAllowedHost(origin[prefix.len..], port);
}

test "local web host validation only accepts the configured loopback endpoint" {
    try std.testing.expect(isAllowedHost("127.0.0.1:49317", 49317));
    try std.testing.expect(isAllowedHost("localhost:49317", 49317));
    try std.testing.expect(isAllowedHost("LOCALHOST:49317", 49317));

    try std.testing.expect(!isAllowedHost(null, 49317));
    try std.testing.expect(!isAllowedHost("127.0.0.1:49318", 49317));
    try std.testing.expect(!isAllowedHost("127.0.0.1.evil.example:49317", 49317));
    try std.testing.expect(!isAllowedHost("example.com:49317", 49317));
}

test "local web origin validation permits absent or exact same-origin headers" {
    try std.testing.expect(isAllowedOrigin(null, 49317));
    try std.testing.expect(isAllowedOrigin("http://127.0.0.1:49317", 49317));
    try std.testing.expect(isAllowedOrigin("http://localhost:49317", 49317));

    try std.testing.expect(!isAllowedOrigin("https://127.0.0.1:49317", 49317));
    try std.testing.expect(!isAllowedOrigin("http://127.0.0.1:49318", 49317));
    try std.testing.expect(!isAllowedOrigin("http://localhost:49317.evil.example", 49317));
    try std.testing.expect(!isAllowedOrigin("https://example.com", 49317));
}
