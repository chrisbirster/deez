const std = @import("std");

const content = @import("content.zig");
const interaction = @import("interaction.zig");
const render = @import("render.zig");
const storage = @import("storage/root.zig");
const note_type_store = @import("storage/note_type_store.zig");
const generated_store = @import("storage/generated_card_store.zig");

pub const Generation = union(enum) {
    template: content.TemplateOrdinal,
    cloze: u32,
    occlusion: u32,
};

pub const CardDraft = struct {
    generation: Generation,
    question: []u8,
    answer: []u8,

    pub fn deinit(self: CardDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.question);
        allocator.free(self.answer);
    }
};

pub const Generated = struct {
    note_id: content.NoteId,
    card_ids: []u64,

    pub fn deinit(self: Generated, allocator: std.mem.Allocator) void {
        allocator.free(self.card_ids);
    }
};

fn builtinForId(id: content.NoteTypeId) !content.BuiltInNoteType {
    return content.BuiltInNoteType.fromId(id) catch return error.UnsupportedBuiltInNoteType;
}

fn requireFields(kind: content.BuiltInNoteType, values: []const []const u8) !void {
    const expected = kind.definition().fields.len;
    if (values.len != expected) return error.InvalidFieldCount;
    switch (kind) {
        .cloze => try content.requireText(values[0]),
        .optional_reverse => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
        .basic, .basic_reverse, .type_answer => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
        .multiple_choice => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
            try content.requireText(values[2]);
        },
        .multiple_select => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
            try content.requireText(values[2]);
        },
        .ordering => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
        .image_occlusion => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
    }
}

const Cloze = struct {
    ordinal: u32,
    text: []const u8,
    hint: ?[]const u8,
    start: usize,
    end: usize,
};

fn parseClozeAt(source: []const u8, start: usize) !?Cloze {
    if (!std.mem.startsWith(u8, source[start..], "{{c")) return null;
    var index = start + 3;
    const number_start = index;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    if (index == number_start or index + 1 >= source.len or source[index] != ':' or source[index + 1] != ':') return null;
    const ordinal = std.fmt.parseInt(u32, source[number_start..index], 10) catch return error.InvalidCloze;
    if (ordinal == 0) return error.InvalidCloze;
    index += 2;
    const body_start = index;
    const close_rel = std.mem.indexOf(u8, source[index..], "}}") orelse return error.InvalidCloze;
    const close = index + close_rel;
    const body = source[body_start..close];
    const hint_sep = std.mem.indexOf(u8, body, "::");
    return .{
        .ordinal = ordinal,
        .text = if (hint_sep) |position| body[0..position] else body,
        .hint = if (hint_sep) |position| body[position + 2 ..] else null,
        .start = start,
        .end = close + 2,
    };
}

fn collectClozeOrdinals(allocator: std.mem.Allocator, source: []const u8) ![]u32 {
    var ordinals: std.ArrayList(u32) = .empty;
    errdefer ordinals.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (try parseClozeAt(source, index)) |cloze| {
            var exists = false;
            for (ordinals.items) |value| {
                if (value == cloze.ordinal) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try ordinals.append(allocator, cloze.ordinal);
            index = cloze.end;
        } else index += 1;
    }
    if (ordinals.items.len == 0) return error.ClozeRequired;
    std.mem.sort(u32, ordinals.items, {}, std.sort.asc(u32));
    return ordinals.toOwnedSlice(allocator);
}

fn renderedDraft(
    allocator: std.mem.Allocator,
    definition: content.NoteTypeDefinition,
    fields: []const content.FieldValue,
    template_ordinal: content.TemplateOrdinal,
    cloze_ordinal: ?u32,
) !CardDraft {
    const rendered = try render.renderCard(
        allocator,
        definition,
        fields,
        template_ordinal,
        .{
            .mode = .plain_text,
            .cloze_ordinal = cloze_ordinal,
        },
    );

    allocator.free(rendered.css);
    if (rendered.typed_answer) |typed_answer| allocator.free(typed_answer);

    var draft: CardDraft = .{
        .generation = .{ .template = template_ordinal },
        .question = rendered.front,
        .answer = rendered.back,
    };

    if (cloze_ordinal) |ordinal| {
        draft.generation = .{ .cloze = ordinal };
    }

    return draft;
}

fn appendInteractionDraft(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(CardDraft),
    generation: Generation,
    text: interaction.CardText,
) !void {
    errdefer text.deinit(allocator);
    try result.append(allocator, .{
        .generation = generation,
        .question = text.question,
        .answer = text.answer,
    });
}

pub fn drafts(
    allocator: std.mem.Allocator,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
) ![]CardDraft {
    try requireFields(kind, values);

    const definition = kind.definition();
    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);

    var result: std.ArrayList(CardDraft) = .empty;
    errdefer {
        for (result.items) |draft| draft.deinit(allocator);
        result.deinit(allocator);
    }

    switch (kind) {
        .basic, .type_answer => {
            try result.append(
                allocator,
                try renderedDraft(allocator, definition, fields, 0, null),
            );
        },
        .basic_reverse => {
            try result.append(
                allocator,
                try renderedDraft(allocator, definition, fields, 0, null),
            );
            try result.append(
                allocator,
                try renderedDraft(allocator, definition, fields, 1, null),
            );
        },
        .optional_reverse => {
            try result.append(
                allocator,
                try renderedDraft(allocator, definition, fields, 0, null),
            );

            if (std.mem.trim(u8, values[2], " \t\r\n").len != 0) {
                try result.append(
                    allocator,
                    try renderedDraft(allocator, definition, fields, 1, null),
                );
            }
        },
        .cloze => {
            const ordinals = try collectClozeOrdinals(allocator, values[0]);
            defer allocator.free(ordinals);

            for (ordinals) |ordinal| {
                try result.append(
                    allocator,
                    try renderedDraft(
                        allocator,
                        definition,
                        fields,
                        0,
                        ordinal,
                    ),
                );
            }
        },
        .multiple_choice => {
            const text = try interaction.multipleChoice(allocator, values[0], values[1], values[2], values[3]);
            try appendInteractionDraft(allocator, &result, .{ .template = 0 }, text);
        },
        .multiple_select => {
            const text = try interaction.multipleSelect(allocator, values[0], values[1], values[2], values[3]);
            try appendInteractionDraft(allocator, &result, .{ .template = 0 }, text);
        },
        .ordering => {
            const text = try interaction.ordering(allocator, values[0], values[1], values[2]);
            try appendInteractionDraft(allocator, &result, .{ .template = 0 }, text);
        },
        .image_occlusion => {
            const ids = try interaction.occlusionIds(allocator, values[0], values[1]);
            defer allocator.free(ids);
            for (ids) |id| {
                const text = try interaction.imageOcclusion(allocator, values[0], values[1], values[2], id);
                try appendInteractionDraft(allocator, &result, .{ .occlusion = id }, text);
            }
        },
    }

    return result.toOwnedSlice(allocator);
}

fn fieldValues(allocator: std.mem.Allocator, values: []const []const u8) ![]content.FieldValue {
    const fields = try allocator.alloc(content.FieldValue, values.len);
    for (values, 0..) |value, index| fields[index] = .{ .ordinal = @intCast(index), .value = value };
    return fields;
}

fn syncCards(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
    generated: []const CardDraft,
    created_at_ms: i64,
) ![]u64 {
    const ids = try allocator.alloc(u64, generated.len);
    errdefer allocator.free(ids);
    for (generated, 0..) |draft, index| {
        const key = switch (draft.generation) {
            .template => |ordinal| try content.generationKey(allocator, note_id, ordinal),
            .cloze => |ordinal| try content.clozeGenerationKey(allocator, note_id, ordinal),
            .occlusion => |id| try content.occlusionGenerationKey(allocator, note_id, id),
        };
        defer allocator.free(key);
        if (try generated_store.cardIdForKey(store, key)) |card_id| {
            try store.updateCard(card_id, draft.question, draft.answer);
            ids[index] = card_id;
        } else {
            const card_id = try store.createCard(deck_id, draft.question, draft.answer, created_at_ms);
            errdefer store.deleteCard(card_id) catch {};
            const template_ordinal: content.TemplateOrdinal = switch (draft.generation) {
                .template => |ordinal| ordinal,
                .cloze, .occlusion => 0,
            };
            try generated_store.link(store, card_id, note_id, template_ordinal, key);
            ids[index] = card_id;
        }
    }
    return ids;
}

pub fn create(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
    tags_json: []const u8,
    created_at_ms: i64,
) !Generated {
    try requireFields(kind, values);
    const definition = kind.definition();
    try note_type_store.ensure(allocator, store, definition, created_at_ms);
    _ = try store.ensureDefaultFsrs7(created_at_ms);
    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);
    const content_store = storage.ContentStore.init(store);
    const note_id = try content_store.createNote(allocator, definition.id, fields, tags_json, created_at_ms);
    const generated = try drafts(allocator, kind, values);
    defer {
        for (generated) |draft| draft.deinit(allocator);
        allocator.free(generated);
    }
    return .{ .note_id = note_id, .card_ids = try syncCards(allocator, store, deck_id, note_id, generated, created_at_ms) };
}

pub fn update(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
    values: []const []const u8,
    tags_json: []const u8,
    updated_at_ms: i64,
) ![]u64 {
    const content_store = storage.ContentStore.init(store);
    const note = (try content_store.getNote(allocator, note_id)) orelse return error.NoteNotFound;
    defer note.deinit(allocator);
    const kind = try builtinForId(note.note_type_id);
    try requireFields(kind, values);
    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);
    try generated_store.updateNote(allocator, store, note_id, fields, tags_json, updated_at_ms);
    const generated = try drafts(allocator, kind, values);
    defer {
        for (generated) |draft| draft.deinit(allocator);
        allocator.free(generated);
    }
    return syncCards(allocator, store, deck_id, note_id, generated, updated_at_ms);
}

test "reverse note generates stable forward and reverse cards" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("reverse", 0);
    const values = [_][]const u8{ "capital of France", "Paris" };
    const created = try create(std.testing.allocator, &store, deck_id, .basic_reverse, &values, "[]", 0);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);

    const ids = try update(std.testing.allocator, &store, deck_id, created.note_id, &values, "[]", 1);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u64, created.card_ids, ids);
}

test "optional reverse allows a blank toggle" {
    const values = [_][]const u8{ "France", "Paris", "" };
    const generated = try drafts(std.testing.allocator, .optional_reverse, &values);
    defer {
        for (generated) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated);
    }
    try std.testing.expectEqual(@as(usize, 1), generated.len);
}

test "cloze generates one card per distinct cloze ordinal" {
    const values = [_][]const u8{ "Paris is {{c1::France}} and Rome is {{c2::Italy}}; {{c1::Paris}} is a city.", "" };
    const generated = try drafts(std.testing.allocator, .cloze, &values);
    defer {
        for (generated) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated);
    }
    try std.testing.expectEqual(@as(usize, 2), generated.len);
    try std.testing.expect(std.mem.indexOf(u8, generated[0].question, "[...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated[0].answer, "France") != null);
}

test "multiple choice and multiple select generate one logical card" {
    const choices = "[{\"id\":\"stack\",\"text\":\"Stack\"},{\"id\":\"queue\",\"text\":\"Queue\"},{\"id\":\"hash\",\"text\":\"Hash table\"}]";
    const mc = [_][]const u8{ "Average O(1) lookup?", choices, "hash", "Uses hashing." };
    const generated_mc = try drafts(std.testing.allocator, .multiple_choice, &mc);
    defer {
        for (generated_mc) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated_mc);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_mc.len);
    try std.testing.expect(std.mem.indexOf(u8, generated_mc[0].answer, "Hash table") != null);

    const ms = [_][]const u8{ "Stack O(1) operations?", choices, "[\"stack\",\"queue\"]", "Example only." };
    const generated_ms = try drafts(std.testing.allocator, .multiple_select, &ms);
    defer {
        for (generated_ms) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_ms.len);
}

test "ordering generates a scrambled prompt and canonical answer" {
    const items = "[{\"id\":\"a\",\"text\":\"First\"},{\"id\":\"b\",\"text\":\"Second\"},{\"id\":\"c\",\"text\":\"Third\"}]";
    const values = [_][]const u8{ "Put these in order", items, "" };
    const generated = try drafts(std.testing.allocator, .ordering, &values);
    defer {
        for (generated) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated);
    }
    try std.testing.expectEqual(@as(usize, 1), generated.len);
    try std.testing.expect(std.mem.indexOf(u8, generated[0].answer, "1. First") != null);
}

test "image occlusion identity follows mask id across reordering" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("occlusion", 0);
    const image = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const masks_a = "[{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right\"},{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left\"}]";
    const fields_a = [_][]const u8{ image, masks_a, "tree" };
    const created = try create(std.testing.allocator, &store, deck_id, .image_occlusion, &fields_a, "[]", 0);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);

    const masks_b = "[{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left node\"},{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right node\"}]";
    const fields_b = [_][]const u8{ image, masks_b, "tree" };
    const updated = try update(std.testing.allocator, &store, deck_id, created.note_id, &fields_b, "[]", 1);
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualSlices(u64, created.card_ids, updated);
}
