const std = @import("std");

pub const NoteTypeId = u64;
pub const NoteId = u64;
pub const FieldOrdinal = u32;
pub const TemplateOrdinal = u32;

pub const NoteKind = enum {
    basic,
    custom,
    cloze,
};

pub const FieldDefinition = struct {
    ordinal: FieldOrdinal,
    name: []const u8,
};

pub const CardTemplate = struct {
    ordinal: TemplateOrdinal,
    name: []const u8,
    front: []const u8,
    back: []const u8,
};

pub const NoteTypeDefinition = struct {
    id: NoteTypeId,
    slug: []const u8,
    name: []const u8,
    kind: NoteKind,
    css: []const u8,
    fields: []const FieldDefinition,
    templates: []const CardTemplate,
};

pub const FieldValue = struct {
    ordinal: FieldOrdinal,
    value: []const u8,
};

pub const OwnedFieldValue = struct {
    ordinal: FieldOrdinal,
    value: []u8,

    pub fn deinit(self: OwnedFieldValue, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const OwnedNote = struct {
    id: NoteId,
    note_type_id: NoteTypeId,
    tags_json: []u8,
    fields: []OwnedFieldValue,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: OwnedNote, allocator: std.mem.Allocator) void {
        allocator.free(self.tags_json);
        for (self.fields) |field| field.deinit(allocator);
        allocator.free(self.fields);
    }
};

pub const GeneratedCardSource = struct {
    note_id: NoteId,
    template_ordinal: TemplateOrdinal,
    generation_key: []u8,

    pub fn deinit(self: GeneratedCardSource, allocator: std.mem.Allocator) void {
        allocator.free(self.generation_key);
    }
};

pub const CreatedNote = struct {
    note_id: NoteId,
    card_ids: []u64,

    pub fn deinit(self: CreatedNote, allocator: std.mem.Allocator) void {
        allocator.free(self.card_ids);
    }
};

const basic_fields = [_]FieldDefinition{
    .{ .ordinal = 0, .name = "Front" },
    .{ .ordinal = 1, .name = "Back" },
};

const basic_templates = [_]CardTemplate{
    .{
        .ordinal = 0,
        .name = "Card 1",
        .front = "{{Front}}",
        .back = "{{FrontSide}}<hr id=answer>{{Back}}",
    },
};

pub const basic_note_type: NoteTypeDefinition = .{
    .id = 1,
    .slug = "basic",
    .name = "Basic",
    .kind = .basic,
    .css = ".card { font-family: sans-serif; font-size: 20px; text-align: center; }",
    .fields = &basic_fields,
    .templates = &basic_templates,
};

pub fn generationKey(
    allocator: std.mem.Allocator,
    note_id: NoteId,
    template_ordinal: TemplateOrdinal,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "note:{d}:template:{d}", .{ note_id, template_ordinal });
}

pub fn clozeGenerationKey(
    allocator: std.mem.Allocator,
    note_id: NoteId,
    cloze_ordinal: u32,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "note:{d}:cloze:{d}", .{ note_id, cloze_ordinal });
}

pub fn requireText(text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
}

pub fn validateNoteType(definition: NoteTypeDefinition) !void {
    try requireText(definition.slug);
    try requireText(definition.name);
    if (definition.fields.len == 0) return error.NoteTypeRequiresField;
    if (definition.templates.len == 0 and definition.kind != .cloze) return error.NoteTypeRequiresTemplate;

    for (definition.fields, 0..) |field, index| {
        if (field.ordinal != index) return error.InvalidFieldOrdinal;
        try requireText(field.name);
    }
    for (definition.templates, 0..) |template, index| {
        if (template.ordinal != index) return error.InvalidTemplateOrdinal;
        try requireText(template.name);
    }
}

test "built in Basic note type is valid" {
    try validateNoteType(basic_note_type);
    try std.testing.expectEqual(@as(NoteTypeId, 1), basic_note_type.id);
    try std.testing.expectEqualStrings("Front", basic_note_type.fields[0].name);
    try std.testing.expectEqualStrings("Back", basic_note_type.fields[1].name);
}

test "generation keys are stable by note and template" {
    const key = try generationKey(std.testing.allocator, 42, 1);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("note:42:template:1", key);
}
