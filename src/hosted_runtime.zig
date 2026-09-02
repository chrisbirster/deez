const std = @import("std");
const email_sender = @import("email_sender.zig");
const hosted_auth = @import("hosted_auth.zig");
const hosted_web = @import("hosted_web.zig");
const storage = @import("storage/root.zig");

fn isLoopbackHttp(url: []const u8) bool {
    const prefixes = [_][]const u8{
        "http://127.0.0.1",
        "http://localhost",
        "http://[::1]",
    };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, url, prefix)) continue;
        if (url.len == prefix.len) return true;
        return url[prefix.len] == ':' or url[prefix.len] == '/';
    }
    return false;
}

fn validHostedUrl(url: []const u8, allow_insecure_loopback: bool) bool {
    if (std.mem.startsWith(u8, url, "https://") and url.len > "https://".len) return true;
    return allow_insecure_loopback and isLoopbackHttp(url);
}

pub fn run(
    init: std.process.Init,
    store: *storage.Store,
    options: hosted_web.Options,
) !void {
    const base_url_raw = init.environ_map.get("DEEZ_AUTH_BASE_URL") orelse return error.MissingHostedAuthConfiguration;
    const email_endpoint = init.environ_map.get("DEEZ_EMAIL_ENDPOINT") orelse return error.MissingHostedAuthConfiguration;
    const relay_token = init.environ_map.get("DEEZ_EMAIL_RELAY_TOKEN") orelse return error.MissingHostedAuthConfiguration;
    const allow_insecure_loopback = if (init.environ_map.get("DEEZ_ALLOW_INSECURE_HOSTED_LOCALHOST")) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
    var base_url_end = base_url_raw.len;
    while (base_url_end > 0 and base_url_raw[base_url_end - 1] == '/') base_url_end -= 1;
    const base_url = base_url_raw[0..base_url_end];

    if (!validHostedUrl(base_url, allow_insecure_loopback)) return error.InvalidHostedAuthBaseUrl;
    if (!validHostedUrl(email_endpoint, allow_insecure_loopback)) return error.InvalidHostedEmailEndpoint;
    if (relay_token.len == 0) return error.MissingHostedAuthConfiguration;

    switch (store.*) {
        .mongodb => |*mongo| {
            var sender: email_sender.Sender = .{ .relay = .{
                .io = init.io,
                .allocator = init.gpa,
                .endpoint = email_endpoint,
                .bearer_token = relay_token,
            } };
            var auth = hosted_auth.Service.init(
                init.io,
                init.gpa,
                mongo,
                .{ .base_url = base_url },
                &sender,
            );
            try hosted_web.run(init, store, &auth, options);
        },
        .sqlite => return error.HostedRequiresMongoDB,
    }
}

test "hosted URL validation remains HTTPS-only unless loopback is explicitly enabled" {
    try std.testing.expect(validHostedUrl("https://deez.run", false));
    try std.testing.expect(!validHostedUrl("http://127.0.0.1:18080", false));
    try std.testing.expect(validHostedUrl("http://127.0.0.1:18080", true));
    try std.testing.expect(validHostedUrl("http://localhost:18080/send", true));
    try std.testing.expect(validHostedUrl("http://[::1]:18080", true));
    try std.testing.expect(!validHostedUrl("http://127.0.0.1.evil.example", true));
    try std.testing.expect(!validHostedUrl("http://localhost.evil.example", true));
}
