const std = @import("std");
const hosted_auth = @import("hosted_auth.zig");
const hosted_web = @import("hosted_web.zig");
const storage = @import("storage/root.zig");

pub fn run(
    init: std.process.Init,
    store: *storage.Store,
    options: hosted_web.Options,
) !void {
    const base_url_raw = init.environ_map.get("DEEZ_AUTH_BASE_URL") orelse return error.MissingHostedAuthConfiguration;
    const api_key = init.environ_map.get("DEEZ_RESEND_API_KEY") orelse return error.MissingHostedAuthConfiguration;
    const from_email = init.environ_map.get("DEEZ_AUTH_FROM") orelse return error.MissingHostedAuthConfiguration;
    const base_url = std.mem.trimRight(u8, base_url_raw, "/");

    if (!std.mem.startsWith(u8, base_url, "https://") or base_url.len <= "https://".len) {
        return error.InvalidHostedAuthBaseUrl;
    }
    if (api_key.len == 0 or from_email.len == 0) return error.MissingHostedAuthConfiguration;

    switch (store.*) {
        .mongodb => |*mongo| {
            var auth = hosted_auth.Service.init(init.io, init.gpa, mongo, .{
                .base_url = base_url,
                .resend_api_key = api_key,
                .from_email = from_email,
            });
            try hosted_web.run(init, store, &auth, options);
        },
        .sqlite => return error.HostedRequiresMongoDB,
    }
}
