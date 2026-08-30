const std = @import("std");
const httpz = @import("httpz");
const build_options = @import("build_options");
const content = @import("content.zig");
const hosted_auth = @import("hosted_auth.zig");
const storage = @import("storage/root.zig");
const web_assets = @import("web_assets.zig");
const web_cards = @import("web_cards.zig");
const web_media = @import("web_media.zig");
const web_notes = @import("web_notes.zig");
const web_study = @import("web_study.zig");

const Io = std.Io;
const max_api_body_bytes: usize = 1024 * 1024;
const content_security_policy = "default-src 'self'; base-uri 'none'; connect-src 'self'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'";

pub const Options = struct {
    port: u16 = 8080,
    web_root: ?[]const u8 = null,
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

const DeckResponse = struct {
    id: []const u8,
    name: []const u8,
    note_count: usize,
    card_count: usize,
    due_count: usize,
};

const NoteSummaryResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    preview: []const u8,
    card_count: usize,
    updated_at_ms: i64,
};

const NoteResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    fields: []const []const u8,
    tags: []const []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const Handler = struct {
    io: Io,
    port: u16,
    store: *storage.Store,
    auth: *hosted_auth.Service,
    web_root: ?[]const u8,
    media_root: []const u8,
    store_mutex: Io.Mutex = .init,

    pub fn dispatch(
        self: *Handler,
        action: httpz.Action(*Handler),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        applySecurityHeaders(res);
        if (!isAllowedHostedRequest(req.header("host"), req.header("origin"))) {
            forbidden(res);
            return;
        }
        if (!isMediaApiPath(req.url.path) and req.body_len > max_api_body_bytes) {
            try jsonError(res, 413, "request_too_large", "Deez Web API JSON bodies are limited to 1 MiB");
            return;
        }
        self.store_mutex.lockUncancelable(self.io);
        defer self.store_mutex.unlock(self.io);
        try action(self, req, res);
    }

    pub fn notFound(_: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        applySecurityHeaders(res);
        if (!isAllowedHostedRequest(req.header("host"), req.header("origin"))) {
            forbidden(res);
            return;
        }
        if (req.method == .GET and !std.mem.startsWith(u8, req.url.path, "/api/")) {
            // The handler is recovered from the route action context in dispatch;
            // fallback serving is installed explicitly below instead.
        }
        try jsonError(res, 404, "not_found", "Not found");
    }

    pub fn uncaughtError(_: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("hosted web request failed path={s} error={}", .{ req.url.path, err });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}";
    }
};

pub fn run(init: std.process.Init, store: *storage.Store, auth: *hosted_auth.Service, options: Options) !void {
    if (options.port == 0) return error.InvalidPort;
    const media_root = try web_media.resolveRoot(init, init.arena.allocator());
    var handler: Handler = .{
        .io = init.io,
        .port = options.port,
        .store = store,
        .auth = auth,
        .web_root = options.web_root,
        .media_root = media_root,
    };

    var server = try httpz.Server(*Handler).init(init.io, init.gpa, .{
        .address = .all(options.port),
        .workers = .{ .max_conn = 64 },
        .request = .{
            .max_body_size = max_api_body_bytes,
            .lazy_read_size = max_api_body_bytes + 1,
            .max_header_count = 32,
            .max_param_count = 16,
            .max_query_count = 32,
            .max_form_count = 16,
        },
        .response = .{ .max_header_count = 32 },
        .timeout = .{ .request = 15, .keepalive = 15, .request_count = 100 },
    }, &handler);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/version", versionInfo, .{});
    router.get("/api/v1/capabilities", capabilities, .{});

    router.post("/api/v1/auth/magic-link", requestMagicLink, .{});
    router.post("/api/v1/auth/magic/consume", consumeMagicLink, .{});
    router.get("/api/v1/auth/me", me, .{});
    router.post("/api/v1/auth/username", setUsername, .{});
    router.post("/api/v1/auth/logout", logout, .{});
    router.post("/api/v1/auth/logout-all", logoutAll, .{});

    router.get("/api/v1/stats", stats, .{});
    router.post("/api/v1/media", mediaUpload, .{});
    router.get("/api/v1/media/:hash", mediaAsset, .{});
    router.get("/api/v1/decks", decks, .{});
    router.post("/api/v1/decks", createDeck, .{});
    router.get("/api/v1/decks/:id", deck, .{});
    router.patch("/api/v1/decks/:id", renameDeck, .{});
    router.delete("/api/v1/decks/:id", deleteDeck, .{});
    router.get("/api/v1/decks/:id/notes", deckNotes, .{});
    router.post("/api/v1/decks/:id/notes", createNote, .{});
    router.get("/api/v1/decks/:id/cards", deckCards, .{});
    router.get("/api/v1/decks/:id/study/next", studyNext, .{});
    router.get("/api/v1/notes/:id", note, .{});
    router.patch("/api/v1/notes/:id", updateNote, .{});
    router.delete("/api/v1/notes/:id", deleteNote, .{});
    router.post("/api/v1/notes/preview", previewNote, .{});
    router.get("/api/v1/cards/:id", card, .{});
    router.get("/api/v1/cards/:id/study/preview", studyPreview, .{});
    router.post("/api/v1/cards/:id/reviews", studyReview, .{});

    // httpz's notFound callback cannot use the handler pointer in this version,
    // so register a final catch-all GET route for SPA deep links.
    router.get("/*", spaFallback, .{});

    std.debug.print("Deez hosted web listening on http://0.0.0.0:{d}/\n", .{options.port});
    try server.listen();
}

fn health(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .status = "ok" }, .{});
}

fn versionInfo(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .version = build_options.version, .api_version = "v1" }, .{});
}

fn capabilities(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const note_types = try res.arena.alloc(CapabilityNoteType, content.built_in_note_types.len);
    for (content.built_in_note_types, 0..) |definition, index| {
        const fields = try res.arena.alloc(CapabilityField, definition.fields.len);
        for (definition.fields, 0..) |field, field_index| {
            fields[field_index] = .{ .ordinal = field.ordinal, .name = field.name };
        }
        note_types[index] = .{
            .id = try idText(res.arena, definition.id),
            .slug = definition.slug,
            .name = definition.name,
            .fields = fields,
        };
    }
    const interactions = [_][]const u8{ "reveal", "type_answer", "single_choice", "multiple_choice", "ordering", "image_occlusion" };
    const formats = [_][]const u8{ "nut", "sack" };
    try res.json(.{
        .api_version = "v1",
        .note_types = &note_types,
        .interactions = &interactions,
        .import_formats = &formats,
        .export_formats = &formats,
    }, .{});
}

const MagicLinkInput = struct { email: []const u8 };
fn requestMagicLink(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    noStore(res);
    const input = (try req.json(MagicLinkInput)) orelse {
        try jsonError(res, 400, "invalid_request", "Email is required");
        return;
    };
    self.auth.requestMagicLink(res.arena, input.email, nowMs(self.io)) catch |err| switch (err) {
        error.InvalidEmail => {
            // Keep the public response intentionally generic to avoid account enumeration.
        },
        error.EmailDeliveryFailed => {
            try jsonError(res, 503, "email_unavailable", "Unable to send the sign-in email right now");
            return;
        },
        else => return err,
    };
    res.status = 202;
    try res.json(.{ .status = "check_email" }, .{});
}

const MagicConsumeInput = struct { token: []const u8 };
fn consumeMagicLink(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    noStore(res);
    const input = (try req.json(MagicConsumeInput)) orelse {
        try jsonError(res, 400, "invalid_request", "Magic-link token is required");
        return;
    };
    const login = self.auth.consumeMagicLink(res.arena, input.token, nowMs(self.io)) catch |err| switch (err) {
        error.InvalidMagicLink, error.ExpiredMagicLink, error.UsedMagicLink => {
            try jsonError(res, 401, "invalid_magic_link", "This sign-in link is invalid, expired, or already used");
            return;
        },
        else => return err,
    };
    try setSessionCookie(res, login.session_token);
    try res.json(.{
        .user = .{ .id = login.user.id, .email = login.user.email, .username = login.user.username },
        .needs_username = login.user.username == null,
        .is_new_user = login.is_new_user,
    }, .{});
}

fn me(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    noStore(res);
    const user = (try requireUser(self, req, res)) orelse return;
    try res.json(.{ .id = user.id, .email = user.email, .username = user.username }, .{});
}

const UsernameInput = struct { username: []const u8 };
fn setUsername(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    noStore(res);
    const user = (try requireUser(self, req, res)) orelse return;
    const input = (try req.json(UsernameInput)) orelse {
        try jsonError(res, 400, "invalid_request", "Username is required");
        return;
    };
    const updated = self.auth.claimUsername(res.arena, user.id, input.username, nowMs(self.io)) catch |err| switch (err) {
        error.InvalidUsername => {
            try jsonError(res, 400, "invalid_username", "Username must be 3-32 letters, numbers, hyphens, or underscores and cannot be reserved");
            return;
        },
        error.UsernameUnavailable => {
            try jsonError(res, 409, "username_unavailable", "That username is already taken");
            return;
        },
        else => return err,
    };
    try res.json(.{ .id = updated.id, .email = updated.email, .username = updated.username }, .{});
}

fn logout(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    noStore(res);
    if (req.cookies().get(hosted_auth.cookie_name)) |token| try self.auth.revokeSession(token, nowMs(self.io));
    try clearSessionCookie(res);
    res.status = 204;
}

fn logoutAll(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    noStore(res);
    const user = (try requireUser(self, req, res)) orelse return;
    try self.auth.revokeAllSessions(user.id, nowMs(self.io));
    try clearSessionCookie(res);
    res.status = 204;
}

fn stats(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const query = try req.query();
    if (query.get("deck_id")) |deck_text| {
        const deck_id = parseIdText(deck_text) catch {
            try jsonError(res, 400, "invalid_deck_id", "deck_id must be an unsigned integer");
            return;
        };
        if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
        const value = try self.store.stats(nowMs(self.io), deck_id);
        try res.json(.{ .decks = value.deck_count, .cards = value.card_count, .due = value.due_count, .reviews = value.review_count }, .{});
        return;
    }

    const ids = try self.auth.ownedDeckIds(res.arena, user.id);
    var cards_count: usize = 0;
    var due_count: usize = 0;
    var review_count: usize = 0;
    for (ids) |deck_id| {
        if (try self.store.getDeck(res.arena, deck_id) == null) continue;
        const value = try self.store.stats(nowMs(self.io), deck_id);
        cards_count += value.card_count;
        due_count += value.due_count;
        review_count += value.review_count;
    }
    try res.json(.{ .decks = ids.len, .cards = cards_count, .due = due_count, .reviews = review_count }, .{});
}

fn mediaUpload(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = (try requireUser(self, req, res)) orelse return;
    try web_media.upload(self.io, self.media_root, req, res);
}

fn mediaAsset(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = (try requireUser(self, req, res)) orelse return;
    try web_media.serve(self.io, self.media_root, req, res);
}

fn decks(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const ids = try self.auth.ownedDeckIds(res.arena, user.id);
    var result: std.ArrayList(DeckResponse) = .empty;
    for (ids) |deck_id| {
        const owned = (try self.store.getDeck(res.arena, deck_id)) orelse continue;
        const deck_stats = try self.store.stats(nowMs(self.io), deck_id);
        const notes = try storage.ContentStore.init(self.store).notesForDeck(res.arena, deck_id);
        try result.append(res.arena, .{
            .id = try idText(res.arena, owned.id),
            .name = owned.name,
            .note_count = notes.len,
            .card_count = deck_stats.card_count,
            .due_count = deck_stats.due_count,
        });
    }
    try res.json(result.items, .{});
}

const DeckNameInput = struct { name: []const u8 };
fn createDeck(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const input = (try req.json(DeckNameInput)) orelse {
        try jsonError(res, 400, "invalid_request", "Deck name is required");
        return;
    };
    const name = std.mem.trim(u8, input.name, " \t\r\n");
    if (name.len == 0 or name.len > 200) {
        try jsonError(res, 400, "invalid_deck_name", "Deck name must be between 1 and 200 characters");
        return;
    }
    const deck_id = try self.store.createDeck(name, nowMs(self.io));
    _ = try self.store.ensureDefaultFsrs7(nowMs(self.io));
    try self.auth.assignDeck(user.id, deck_id, nowMs(self.io));
    res.status = 201;
    try deckResponse(self, deck_id, res);
}

fn deck(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try deckResponse(self, deck_id, res);
}

fn renameDeck(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    const input = (try req.json(DeckNameInput)) orelse {
        try jsonError(res, 400, "invalid_request", "Deck name is required");
        return;
    };
    const name = std.mem.trim(u8, input.name, " \t\r\n");
    if (name.len == 0 or name.len > 200) {
        try jsonError(res, 400, "invalid_deck_name", "Deck name must be between 1 and 200 characters");
        return;
    }
    try self.store.renameDeck(deck_id, name);
    try deckResponse(self, deck_id, res);
}

fn deleteDeck(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try self.store.deleteDeck(deck_id);
    res.status = 204;
}

fn deckResponse(self: *Handler, deck_id: u64, res: *httpz.Response) !void {
    const owned = (try self.store.getDeck(res.arena, deck_id)) orelse {
        try jsonError(res, 404, "deck_not_found", "Deck not found");
        return;
    };
    const deck_stats = try self.store.stats(nowMs(self.io), deck_id);
    const notes = try storage.ContentStore.init(self.store).notesForDeck(res.arena, deck_id);
    try res.json(DeckResponse{
        .id = try idText(res.arena, owned.id),
        .name = owned.name,
        .note_count = notes.len,
        .card_count = deck_stats.card_count,
        .due_count = deck_stats.due_count,
    }, .{});
}

fn deckNotes(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    const notes = try storage.ContentStore.init(self.store).notesForDeck(res.arena, deck_id);
    const result = try res.arena.alloc(NoteSummaryResponse, notes.len);
    for (notes, 0..) |entry, index| {
        result[index] = .{
            .id = try idText(res.arena, entry.note.id),
            .deck_id = try idText(res.arena, deck_id),
            .note_type = try noteTypeSlug(entry.note.note_type_id),
            .preview = if (entry.note.fields.len == 0) "" else entry.note.fields[0].value,
            .card_count = entry.card_count,
            .updated_at_ms = entry.note.updated_at_ms,
        };
    }
    try res.json(result, .{});
}

fn createNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try web_notes.createNote(self.store, self.io, req, res);
}

fn note(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const note_id = parseRouteId(req, res, "id") orelse return;
    const deck_id = (try storage.ContentMembership.init(self.store).deckIdForNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    const owned = (try storage.ContentStore.init(self.store).getNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    const fields = try res.arena.alloc([]const u8, owned.fields.len);
    for (owned.fields, 0..) |field, index| fields[index] = field.value;
    var parsed_tags = std.json.parseFromSlice([]const []const u8, res.arena, owned.tags_json, .{}) catch {
        try jsonError(res, 500, "invalid_note_tags", "Stored note tags are invalid");
        return;
    };
    defer parsed_tags.deinit();
    try res.json(NoteResponse{
        .id = try idText(res.arena, owned.id),
        .deck_id = try idText(res.arena, deck_id),
        .note_type = try noteTypeSlug(owned.note_type_id),
        .fields = fields,
        .tags = parsed_tags.value,
        .created_at_ms = owned.created_at_ms,
        .updated_at_ms = owned.updated_at_ms,
    }, .{});
}

fn updateNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const note_id = parseRouteId(req, res, "id") orelse return;
    const deck_id = (try storage.ContentMembership.init(self.store).deckIdForNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try web_notes.updateNote(self.store, self.io, req, res);
}

fn deleteNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const note_id = parseRouteId(req, res, "id") orelse return;
    const deck_id = (try storage.ContentMembership.init(self.store).deckIdForNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try web_notes.deleteNote(self.store, self.io, req, res);
}

fn previewNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = (try requireUser(self, req, res)) orelse return;
    try web_notes.previewNote(req, res);
}

fn deckCards(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try web_cards.deckCards(self.store, req, res);
}

fn studyNext(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const user = (try requireUser(self, req, res)) orelse return;
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (!try requireOwnedDeck(self, user.id, deck_id, res)) return;
    try web_study.next(self.store, self.io, req, res);
}

fn card(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    if (!try requireOwnedCard(self, req, res)) return;
    try web_cards.card(self.store, req, res);
}

fn studyPreview(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    if (!try requireOwnedCard(self, req, res)) return;
    try web_study.preview(self.store, self.io, req, res);
}

fn studyReview(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    if (!try requireOwnedCard(self, req, res)) return;
    try web_study.review(self.store, self.io, req, res);
}

fn requireOwnedCard(self: *Handler, req: *httpz.Request, res: *httpz.Response) !bool {
    const user = (try requireUser(self, req, res)) orelse return false;
    const card_id = parseRouteId(req, res, "id") orelse return false;
    const owned = (try self.store.getCard(res.arena, card_id)) orelse {
        try jsonError(res, 404, "card_not_found", "Card not found");
        return false;
    };
    return requireOwnedDeck(self, user.id, owned.deck_id, res);
}

fn requireOwnedDeck(self: *Handler, user_id: []const u8, deck_id: u64, res: *httpz.Response) !bool {
    if (try self.auth.ownsDeck(user_id, deck_id)) return true;
    // Return 404, not 403, so resource IDs cannot be probed across accounts.
    try jsonError(res, 404, "deck_not_found", "Deck not found");
    return false;
}

fn requireUser(self: *Handler, req: *httpz.Request, res: *httpz.Response) !?hosted_auth.User {
    const token = req.cookies().get(hosted_auth.cookie_name) orelse {
        try unauthorized(res);
        return null;
    };
    const session = self.auth.resolveSession(res.arena, token, nowMs(self.io)) catch |err| switch (err) {
        error.InvalidSession, error.ExpiredSession => {
            try clearSessionCookie(res);
            try unauthorized(res);
            return null;
        },
        else => return err,
    };
    if (session.refresh_cookie) try setSessionCookie(res, token);
    return session.user;
}

fn spaFallback(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    if (self.web_root == null or req.method != .GET or std.mem.startsWith(u8, req.url.path, "/api/")) {
        try jsonError(res, 404, "not_found", "Not found");
        return;
    }
    switch (try web_assets.serve(self.io, self.web_root.?, req.url.path, res)) {
        .served => return,
        .not_found, .unsafe_path => {},
    }
    try jsonError(res, 404, "not_found", "Not found");
}

fn parseRouteId(req: *httpz.Request, res: *httpz.Response, name: []const u8) ?u64 {
    const text = req.param(name) orelse {
        jsonError(res, 400, "invalid_id", "Missing resource ID") catch {};
        return null;
    };
    return parseIdText(text) catch {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    };
}

fn parseIdText(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidId;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidId;
}

fn noteTypeSlug(note_type_id: content.NoteTypeId) ![]const u8 {
    return (try content.BuiltInNoteType.fromId(note_type_id)).definition().slug;
}

fn idText(allocator: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{id});
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn setSessionCookie(res: *httpz.Response, token: []const u8) !void {
    try res.setCookie(hosted_auth.cookie_name, token, .{
        .path = "/",
        .max_age = @intCast(hosted_auth.session_idle_ttl_ms / 1000),
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
}

fn clearSessionCookie(res: *httpz.Response) !void {
    try res.setCookie(hosted_auth.cookie_name, "", .{
        .path = "/",
        .max_age = 0,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
}

fn noStore(res: *httpz.Response) void {
    res.header("Cache-Control", "no-store");
}

fn applySecurityHeaders(res: *httpz.Response) void {
    res.header("Content-Security-Policy", content_security_policy);
    res.header("Cross-Origin-Opener-Policy", "same-origin");
    res.header("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
    res.header("Referrer-Policy", "no-referrer");
    res.header("X-Content-Type-Options", "nosniff");
    res.header("X-Frame-Options", "DENY");
}

fn jsonError(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{ .@"error" = .{ .code = code, .message = message } }, .{});
}

fn unauthorized(res: *httpz.Response) !void {
    noStore(res);
    try jsonError(res, 401, "authentication_required", "Sign in to continue");
}

fn forbidden(res: *httpz.Response) void {
    res.status = 403;
    res.content_type = .JSON;
    res.body = "{\"error\":{\"code\":\"forbidden_origin\",\"message\":\"Request origin is not allowed by the Deez server\"}}";
}

fn isMediaApiPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/api/v1/media") or std.mem.startsWith(u8, path, "/api/v1/media/");
}

fn isAllowedHostedRequest(host_value: ?[]const u8, origin_value: ?[]const u8) bool {
    const host = host_value orelse return false;
    if (host.len == 0) return false;
    const origin = origin_value orelse return true;
    const http_prefix = "http://";
    const https_prefix = "https://";
    const origin_host = if (std.mem.startsWith(u8, origin, https_prefix))
        origin[https_prefix.len..]
    else if (std.mem.startsWith(u8, origin, http_prefix))
        origin[http_prefix.len..]
    else
        return false;
    return std.ascii.eqlIgnoreCase(host, origin_host);
}

test "hosted request validation requires same origin when Origin is present" {
    try std.testing.expect(isAllowedHostedRequest("deez.run", null));
    try std.testing.expect(isAllowedHostedRequest("deez.run", "https://deez.run"));
    try std.testing.expect(!isAllowedHostedRequest("deez.run", "https://evil.example"));
}
