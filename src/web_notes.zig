const std = @import("std");
const httpz = @import("httpz");

const card_render = @import("card_render.zig");
const card_types = @import("card_types.zig");
const content = @import("content.zig");
const note_mutation = @import("note_mutation.zig");
const storage = @import("storage/root.zig");

const Io = std.Io;
const max_bulk_notes: usize = 2048;

const NoteInput = struct {
    note_type: []const u8,
    fields: []const []const u8,
    tags: []const []const u8,
};

const CreateNoteRequest = struct {
    note_type: ?[]const u8 = null,
    fields: ?[]const []const u8 = null,
    tags: ?[]const []const u8 = null,
    notes: ?[]const NoteInput = null,
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

const ChoiceResponse = struct {
    id: []const u8,
    text: []const u8,
};

const OcclusionMaskResponse = struct {
    id: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    answer: []const u8,
    prompt: ?[]const u8 = null,
};

const InteractionResponse = struct {
    type: []const u8,
    answer: ?[]const u8 = null,
    choices: ?[]const ChoiceResponse = null,
    correct_id: ?[]const u8 = null,
    correct_ids: ?[]const []const u8 = null,
    items: ?[]const ChoiceResponse = null,
    image_ref: ?[]const u8 = null,
    masks: ?[]const OcclusionMaskResponse = null,
    target_mask_id: ?u32 = null,
};

const GenerationResponse = struct {
    kind: []const u8,
    ordinal: u32,
};

const RenderedCardResponse = struct {
    generation: GenerationResponse,
    front: []const u8,
    back: []const u8,
    css: []const u8,
    interaction: InteractionResponse,
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn idText(allocator: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{id});
}

fn parseId(req: *httpz.Request, res: *httpz.Response, name: []const u8) ?u64 {
    const text = req.param(name) orelse {
        jsonError(res, 400, "invalid_id", "Missing resource ID") catch {};
        return null;
    };
    return std.fmt.parseInt(u64, text, 10) catch {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    };
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

fn isInvalidNoteError(err: anyerror) bool {
    const name = @errorName(err);
    const validation_errors = [_][]const u8{
        "InvalidFieldCount",
        "InvalidText",
        "EmptyText",
        "InvalidCloze",
        "ClozeRequired",
        "InvalidInteractionText",
        "NotEnoughChoices",
        "UnknownChoiceId",
        "CorrectChoiceRequired",
        "DuplicateChoiceId",
        "DuplicateCorrectChoiceId",
        "InvalidChoiceJson",
        "InvalidMaskJson",
        "InvalidOrderingJson",
        "InvalidImageReference",
        "OcclusionRequired",
    };
    for (validation_errors) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn invalidNote(res: *httpz.Response) !void {
    try jsonError(res, 400, "invalid_note", "Note fields are invalid for this note type");
}

fn parseInput(req: *httpz.Request, res: *httpz.Response) !?NoteInput {
    return req.json(NoteInput) catch {
        try jsonError(res, 400, "invalid_json", "Request body must be a valid note input");
        return null;
    } orelse {
        try jsonError(res, 400, "missing_body", "Request body is required");
        return null;
    };
}

fn parseCreateRequest(req: *httpz.Request, res: *httpz.Response) !?CreateNoteRequest {
    return req.json(CreateNoteRequest) catch {
        try jsonError(res, 400, "invalid_json", "Request body must be a valid note input or bulk note request");
        return null;
    } orelse {
        try jsonError(res, 400, "missing_body", "Request body is required");
        return null;
    };
}

fn tagsJson(allocator: std.mem.Allocator, tags: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(tags, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn noteTypeSlug(note_type_id: content.NoteTypeId) ![]const u8 {
    return (try content.BuiltInNoteType.fromId(note_type_id)).definition().slug;
}

fn noteResponse(
    store: *storage.Store,
    res: *httpz.Response,
    note_id: content.NoteId,
) !?NoteResponse {
    const owned = (try storage.ContentStore.init(store).getNote(res.arena, note_id)) orelse return null;
    const deck_id = (try storage.ContentMembership.init(store).deckIdForNote(res.arena, note_id)) orelse return null;

    const fields = try res.arena.alloc([]const u8, owned.fields.len);
    for (owned.fields, 0..) |field, index| fields[index] = field.value;

    const parsed_tags = std.json.parseFromSliceLeaky([]const []const u8, res.arena, owned.tags_json, .{}) catch
        return error.InvalidStoredTags;

    return .{
        .id = try idText(res.arena, owned.id),
        .deck_id = try idText(res.arena, deck_id),
        .note_type = try noteTypeSlug(owned.note_type_id),
        .fields = fields,
        .tags = parsed_tags,
        .created_at_ms = owned.created_at_ms,
        .updated_at_ms = owned.updated_at_ms,
    };
}

fn writeNote(store: *storage.Store, res: *httpz.Response, note_id: content.NoteId) !void {
    const value = (try noteResponse(store, res, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    try res.json(value, .{});
}

fn copyChoices(allocator: std.mem.Allocator, choices: []const card_render.Choice) ![]ChoiceResponse {
    const result = try allocator.alloc(ChoiceResponse, choices.len);
    for (choices, 0..) |choice, index| {
        result[index] = .{ .id = choice.id, .text = choice.text };
    }
    return result;
}

fn copyIds(allocator: std.mem.Allocator, ids: []const []u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, ids.len);
    for (ids, 0..) |id, index| result[index] = id;
    return result;
}

fn interactionResponse(
    allocator: std.mem.Allocator,
    interaction: card_render.Interaction,
) !InteractionResponse {
    return switch (interaction) {
        .reveal => .{ .type = "reveal" },
        .type_answer => |value| .{
            .type = "type_answer",
            .answer = value.answer,
        },
        .single_choice => |value| .{
            .type = "single_choice",
            .choices = try copyChoices(allocator, value.choices),
            .correct_id = value.correct_id,
        },
        .multiple_choice => |value| .{
            .type = "multiple_choice",
            .choices = try copyChoices(allocator, value.choices),
            .correct_ids = try copyIds(allocator, value.correct_ids),
        },
        .ordering => |value| .{
            .type = "ordering",
            .items = try copyChoices(allocator, value.items),
        },
        .image_occlusion => |value| blk: {
            const masks = try allocator.alloc(OcclusionMaskResponse, value.masks.len);
            for (value.masks, 0..) |mask, index| {
                masks[index] = .{
                    .id = mask.id,
                    .x = mask.x,
                    .y = mask.y,
                    .width = mask.width,
                    .height = mask.height,
                    .answer = mask.answer,
                    .prompt = mask.prompt,
                };
            }
            break :blk .{
                .type = "image_occlusion",
                .image_ref = value.image_ref,
                .masks = masks,
                .target_mask_id = value.target_mask_id,
            };
        },
    };
}

fn generationResponse(generation: card_types.Generation) GenerationResponse {
    return switch (generation) {
        .template => |ordinal| .{ .kind = "template", .ordinal = ordinal },
        .cloze => |ordinal| .{ .kind = "cloze", .ordinal = ordinal },
        .occlusion => |id| .{ .kind = "occlusion", .ordinal = id },
    };
}

fn createOne(
    store: *storage.Store,
    res: *httpz.Response,
    deck_id: u64,
    input: NoteInput,
    created_at_ms: i64,
) !?content.NoteId {
    const kind = content.BuiltInNoteType.parse(input.note_type) catch {
        try jsonError(res, 400, "unknown_note_type", "Unsupported note type");
        return null;
    };
    const tags_json = try tagsJson(res.arena, input.tags);
    const generated = note_mutation.create(
        res.arena,
        store,
        deck_id,
        kind,
        input.fields,
        tags_json,
        created_at_ms,
    ) catch |err| {
        if (isInvalidNoteError(err)) {
            try invalidNote(res);
            return null;
        }
        return err;
    };
    return generated.note_id;
}

fn rollbackCreated(
    store: *storage.Store,
    allocator: std.mem.Allocator,
    deck_id: u64,
    ids: []const content.NoteId,
    timestamp_ms: i64,
) void {
    var index = ids.len;
    while (index > 0) {
        index -= 1;
        note_mutation.delete(allocator, store, deck_id, ids[index], timestamp_ms) catch {};
    }
}

pub fn createNote(
    store: *storage.Store,
    io: Io,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const deck_id = parseId(req, res, "id") orelse return;
    if (try store.getDeck(res.arena, deck_id) == null) {
        try jsonError(res, 404, "deck_not_found", "Deck not found");
        return;
    }

    const request = (try parseCreateRequest(req, res)) orelse return;
    const timestamp_ms = nowMs(io);

    if (request.notes) |notes| {
        if (request.note_type != null or request.fields != null or request.tags != null) {
            try jsonError(res, 400, "invalid_request", "Bulk note requests cannot include single-note fields");
            return;
        }
        if (notes.len == 0 or notes.len > max_bulk_notes) {
            try jsonError(res, 400, "invalid_bulk_size", "Bulk note requests must contain between 1 and 2048 notes");
            return;
        }

        var created_ids: std.ArrayList(content.NoteId) = .empty;
        var responses: std.ArrayList(NoteResponse) = .empty;
        try created_ids.ensureTotalCapacity(res.arena, notes.len);
        try responses.ensureTotalCapacity(res.arena, notes.len);

        for (notes) |input| {
            const note_id = (try createOne(store, res, deck_id, input, timestamp_ms)) orelse {
                rollbackCreated(store, res.arena, deck_id, created_ids.items, timestamp_ms);
                return;
            };
            try created_ids.append(res.arena, note_id);
            const value = (try noteResponse(store, res, note_id)) orelse {
                rollbackCreated(store, res.arena, deck_id, created_ids.items, timestamp_ms);
                return error.NoteCreationLost;
            };
            try responses.append(res.arena, value);
        }

        res.status = 201;
        try res.json(.{ .notes = responses.items }, .{});
        return;
    }

    const note_type = request.note_type orelse {
        try jsonError(res, 400, "invalid_request", "note_type is required");
        return;
    };
    const fields = request.fields orelse {
        try jsonError(res, 400, "invalid_request", "fields are required");
        return;
    };
    const input: NoteInput = .{
        .note_type = note_type,
        .fields = fields,
        .tags = request.tags orelse &.{},
    };
    const note_id = (try createOne(store, res, deck_id, input, timestamp_ms)) orelse return;
    res.status = 201;
    try writeNote(store, res, note_id);
}

pub fn updateNote(
    store: *storage.Store,
    io: Io,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const note_id = parseId(req, res, "id") orelse return;
    const existing = (try storage.ContentStore.init(store).getNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    const deck_id = (try storage.ContentMembership.init(store).deckIdForNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_attached", "Note is not attached to a deck");
        return;
    };
    const input = (try parseInput(req, res)) orelse return;
    const existing_slug = try noteTypeSlug(existing.note_type_id);
    if (!std.mem.eql(u8, existing_slug, input.note_type)) {
        try jsonError(res, 400, "note_type_immutable", "Changing a note type is not supported");
        return;
    }
    const tags_json = try tagsJson(res.arena, input.tags);
    const ids = note_mutation.update(
        res.arena,
        store,
        deck_id,
        note_id,
        input.fields,
        tags_json,
        nowMs(io),
    ) catch |err| {
        if (isInvalidNoteError(err)) {
            try invalidNote(res);
            return;
        }
        return err;
    };
    _ = ids;
    try writeNote(store, res, note_id);
}

pub fn deleteNote(
    store: *storage.Store,
    io: Io,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const note_id = parseId(req, res, "id") orelse return;
    const deck_id = (try storage.ContentMembership.init(store).deckIdForNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    try note_mutation.delete(res.arena, store, deck_id, note_id, nowMs(io));
    res.status = 204;
    res.body = "";
}

pub fn previewNote(
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const input = (try parseInput(req, res)) orelse return;
    const kind = content.BuiltInNoteType.parse(input.note_type) catch {
        try jsonError(res, 400, "unknown_note_type", "Unsupported note type");
        return;
    };
    const drafts = card_types.renderedDrafts(res.arena, kind, input.fields, .html) catch |err| {
        if (isInvalidNoteError(err)) {
            try invalidNote(res);
            return;
        }
        return err;
    };
    const cards = try res.arena.alloc(RenderedCardResponse, drafts.len);
    for (drafts, 0..) |draft, index| {
        cards[index] = .{
            .generation = generationResponse(draft.generation),
            .front = draft.rendered.front,
            .back = draft.rendered.back,
            .css = draft.rendered.css,
            .interaction = try interactionResponse(res.arena, draft.rendered.interaction),
        };
    }
    try res.json(.{ .cards = cards }, .{ .emit_null_optional_fields = false });
}

test "generation response matches the web contract" {
    const template = generationResponse(.{ .template = 2 });
    try std.testing.expectEqualStrings("template", template.kind);
    try std.testing.expectEqual(@as(u32, 2), template.ordinal);
    const cloze = generationResponse(.{ .cloze = 3 });
    try std.testing.expectEqualStrings("cloze", cloze.kind);
    try std.testing.expectEqual(@as(u32, 3), cloze.ordinal);
}

test "validation error classification is independent of inferred error sets" {
    try std.testing.expect(isInvalidNoteError(error.InvalidText));
    try std.testing.expect(isInvalidNoteError(error.InvalidFieldCount));
    try std.testing.expect(!isInvalidNoteError(error.OutOfMemory));
}
