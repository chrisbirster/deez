const std = @import("std");
const email_sender = @import("email_sender.zig");
const hosted_auth = @import("hosted_auth.zig");
const hosted_web = @import("hosted_web.zig");
const storage = @import("storage/root.zig");

pub fn run(
    init: std.process.Init,
    store: *storage.Store,
    options: hosted_web.Options,
) !void {
    const base_url_raw = init.environ_map.get("DEEZ_AUTH_BASE_URL") orelse return error.MissingHostedAuthConfiguration;
    const email_endpoint = init.environ_map.get("DEEZ_EMAIL_ENDPOINT") orelse return error.MissingHostedAuthConfiguration;
    const relay_token = init.environ_map.get("DEEZ_EMAIL_RELAY_TOKEN") orelse return error.MissingHostedAuthConfiguration;
    var base_url_end = base_url_raw.len;
    while (base_url_end > 0 and base_url_raw[base_url_end - 1] == '/') base_url_end -= 1;
    const base_url = base_url_raw[0..base_url_end];

    if (!std.mem.startsWith(u8, base_url, "https://") or base_url.len <= "https://".len) {
        return error.InvalidHostedAuthBaseUrl;
    }
    if (!std.mem.startsWith(u8, email_endpoint, "https://") or email_endpoint.len <= "https://".len) {
        return error.InvalidHostedEmailEndpoint;
    }
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
