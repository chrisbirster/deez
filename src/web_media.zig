const std = @import("std");
const httpz = @import("httpz");

const media = @import("media.zig");

const Io = std.Io;

pub fn resolveRoot(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const root = if (init.environ_map.get("DEEZ_MEDIA_ROOT")) |override| blk: {
        if (override.len == 0) return error.InvalidMediaRoot;
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const home = init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share/deez/media", .{home});
    };
    try Io.Dir.cwd().createDirPath(init.io, root);
    return root;
}

fn jsonError(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn isMissing(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "FileNotFound") or std.mem.eql(u8, name, "PathNotFound");
}

fn validateMime(value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidMediaMime;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidMediaMime;
}

fn setImmutableHeaders(res: *httpz.Response, hash: []const u8, mime: []const u8) ![]const u8 {
    try validateMime(mime);
    const etag = try std.fmt.allocPrint(res.arena, "\"{s}\"", .{hash});
    res.header("Content-Type", mime);
    res.header("Cache-Control", "public, max-age=31536000, immutable");
    res.header("ETag", etag);
    res.header("X-Content-Type-Options", "nosniff");
    res.header("Cross-Origin-Resource-Policy", "same-origin");
    // Media may include active document formats such as SVG. When navigated to
    // directly, keep them sandboxed rather than granting the local app origin.
    res.header("Content-Security-Policy", "sandbox; default-src 'none'");
    return etag;
}

pub fn serve(
    io: Io,
    media_root: []const u8,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const hash = req.param("hash") orelse {
        try jsonError(res, 400, "invalid_media_hash", "Missing media SHA-256 hash");
        return;
    };
    if (!media.isValidHashHex(hash)) {
        try jsonError(res, 400, "invalid_media_hash", "Media hash must be 64 lowercase hexadecimal characters");
        return;
    }

    const metadata = media.loadMetadata(res.arena, io, media_root, hash) catch |err| {
        if (isMissing(err)) {
            try jsonError(res, 404, "media_not_found", "Media not found");
            return;
        }
        return err;
    };
    defer metadata.deinit(res.arena);

    const etag = try setImmutableHeaders(res, hash, metadata.mime);
    if (req.header("if-none-match")) |candidate| {
        if (std.mem.eql(u8, candidate, etag)) {
            res.status = 304;
            res.body = "";
            return;
        }
    }

    const blob = media.loadBlob(res.arena, io, media_root, hash) catch |err| {
        if (isMissing(err)) {
            try jsonError(res, 404, "media_not_found", "Media not found");
            return;
        }
        return err;
    };
    if (metadata.size != blob.len) return error.MediaSizeMismatch;
    res.body = blob;
}

test "media MIME header validation rejects line breaks" {
    try validateMime("image/png");
    try std.testing.expectError(error.InvalidMediaMime, validateMime("image/png\r\nX-Evil: yes"));
    try std.testing.expectError(error.InvalidMediaMime, validateMime(""));
}
