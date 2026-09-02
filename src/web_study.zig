const std = @import("std");
const httpz = @import("httpz");

const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const study_mod = @import("study.zig");

const Io = std.Io;
const max_review_clock_skew_ms: i64 = 5 * 60 * 1000;

const DueCardResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    due_at_ms: ?i64,
};

const NextResponse = struct {
    card: ?DueCardResponse,
};

const CandidateResponse = struct {
    rating: u8,
    due_at_ms: i64,
    interval_days: f64,
};

const ScheduleResponse = struct {
    again: CandidateResponse,
    hard: CandidateResponse,
    good: CandidateResponse,
    easy: CandidateResponse,
};

const PreviewResponse = struct {
    card_id: []const u8,
    review_count: usize,
    retrievability: ?f64,
    schedule: ScheduleResponse,
};

const ReviewInput = struct {
    rating: u8,
    expected_review_count: usize,
    reviewed_at_ms: ?i64 = null,
};

const SchedulerResponse = struct {
    stability_days: ?f64,
    difficulty: ?f64,
    due_at_ms: i64,
    last_reviewed_at_ms: ?i64,
};

const ReviewResponse = struct {
    review_id: []const u8,
    card_id: []const u8,
    rating: u8,
    reviewed_at_ms: i64,
    due_at_ms: i64,
    interval_days: f64,
    scheduler: SchedulerResponse,
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn idText(allocator: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{id});
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

fn parseId(req: *httpz.Request, res: *httpz.Response, name: []const u8) ?u64 {
    const text = req.param(name) orelse {
        jsonError(res, 400, "invalid_id", "Missing resource ID") catch {};
        return null;
    };
    if (text.len == 0) {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    }
    return std.fmt.parseInt(u64, text, 10) catch {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    };
}

fn candidateResponse(candidate: fsrs.Candidate) CandidateResponse {
    return .{
        .rating = candidate.rating.value(),
        .due_at_ms = candidate.due_at_ms,
        .interval_days = candidate.interval_days,
    };
}

fn ensureActiveCard(store: *storage.Store, allocator: std.mem.Allocator, card_id: u64) !bool {
    const owned = (try store.getCard(allocator, card_id)) orelse return false;
    owned.deinit(allocator);
    return !try store.isCardRetired(card_id);
}

fn parseReviewOrder(text: []const u8) !study_mod.ReviewOrder {
    if (std.mem.eql(u8, text, "due")) return .due;
    if (std.mem.eql(u8, text, "reviews-first")) return .reviews_first;
    if (std.mem.eql(u8, text, "new-first")) return .new_first;
    return error.InvalidReviewOrder;
}

pub fn next(
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

    const query = try req.query();
    var options: study_mod.SessionOptions = .{};
    var new_seen: usize = 0;
    if (query.get("new_limit")) |text| {
        options.new_limit = std.fmt.parseInt(usize, text, 10) catch {
            try jsonError(res, 400, "invalid_new_limit", "new_limit must be a non-negative integer");
            return;
        };
    }
    if (query.get("new_seen")) |text| {
        new_seen = std.fmt.parseInt(usize, text, 10) catch {
            try jsonError(res, 400, "invalid_new_seen", "new_seen must be a non-negative integer");
            return;
        };
    }
    if (query.get("order")) |text| {
        options.review_order = parseReviewOrder(text) catch {
            try jsonError(res, 400, "invalid_review_order", "order must be due, reviews-first, or new-first");
            return;
        };
    }
    if (query.get("shuffle_seed")) |text| {
        options.shuffle_seed = std.fmt.parseInt(u64, text, 10) catch {
            try jsonError(res, 400, "invalid_shuffle_seed", "shuffle_seed must be an unsigned integer");
            return;
        };
    }

    var session = study_mod.Session.init(study_mod.Study.init(store), deck_id, options);
    session.new_seen = new_seen;
    const selected = try session.next(res.arena, nowMs(io));
    if (selected == null) {
        try res.json(NextResponse{ .card = null }, .{});
        return;
    }

    const card = selected.?;
    defer card.deinit(res.arena);
    try res.json(NextResponse{
        .card = .{
            .id = try idText(res.arena, card.id),
            .deck_id = try idText(res.arena, card.deck_id),
            .due_at_ms = card.due_at_ms,
        },
    }, .{});
}

pub fn preview(
    store: *storage.Store,
    io: Io,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const card_id = parseId(req, res, "id") orelse return;
    if (!try ensureActiveCard(store, res.arena, card_id)) {
        try jsonError(res, 404, "card_not_found", "Card not found");
        return;
    }

    const history = try store.loadHistory(res.arena, card_id);
    const result = try study_mod.Study.init(store).preview(res.arena, card_id, nowMs(io));
    try res.json(PreviewResponse{
        .card_id = try idText(res.arena, card_id),
        .review_count = history.len,
        .retrievability = result.retrievability,
        .schedule = .{
            .again = candidateResponse(result.schedule.again),
            .hard = candidateResponse(result.schedule.hard),
            .good = candidateResponse(result.schedule.good),
            .easy = candidateResponse(result.schedule.easy),
        },
    }, .{});
}

pub fn review(
    store: *storage.Store,
    io: Io,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const card_id = parseId(req, res, "id") orelse return;
    if (!try ensureActiveCard(store, res.arena, card_id)) {
        try jsonError(res, 404, "card_not_found", "Card not found");
        return;
    }

    const input = req.json(ReviewInput) catch {
        try jsonError(res, 400, "invalid_json", "Request body must include rating and expected_review_count");
        return;
    } orelse {
        try jsonError(res, 400, "missing_body", "Request body must include rating and expected_review_count");
        return;
    };
    const rating = fsrs.Rating.fromValue(input.rating) catch {
        try jsonError(res, 400, "invalid_rating", "Rating must be 1 (Again), 2 (Hard), 3 (Good), or 4 (Easy)");
        return;
    };

    const history = try store.loadHistory(res.arena, card_id);
    if (history.len != input.expected_review_count) {
        try jsonError(res, 409, "stale_review", "Card review history changed; refresh the study card before rating again");
        return;
    }

    const server_now_ms = nowMs(io);
    const reviewed_at_ms = input.reviewed_at_ms orelse server_now_ms;
    if (reviewed_at_ms > server_now_ms + max_review_clock_skew_ms) {
        try jsonError(res, 400, "invalid_review_time", "reviewed_at_ms cannot be in the future");
        return;
    }
    if (history.len != 0 and reviewed_at_ms <= history[history.len - 1].reviewed_at_ms) {
        try jsonError(res, 409, "stale_review", "Review time must be later than the existing review history");
        return;
    }

    if (try store.getSchedulerState(card_id)) |state| {
        if (state.due_at_ms > reviewed_at_ms) {
            try jsonError(res, 409, "card_not_due", "Card is not due for review yet");
            return;
        }
    }

    const result = try study_mod.Study.init(store).recordReview(
        res.arena,
        card_id,
        rating,
        reviewed_at_ms,
    );

    res.status = 201;
    try res.json(ReviewResponse{
        .review_id = try idText(res.arena, result.review_id),
        .card_id = try idText(res.arena, card_id),
        .rating = rating.value(),
        .reviewed_at_ms = reviewed_at_ms,
        .due_at_ms = result.candidate.due_at_ms,
        .interval_days = result.candidate.interval_days,
        .scheduler = .{
            .stability_days = result.state.stability_days,
            .difficulty = result.state.difficulty,
            .due_at_ms = result.state.due_at_ms,
            .last_reviewed_at_ms = result.state.last_reviewed_at_ms,
        },
    }, .{});
}

test "study candidate response preserves the FSRS rating and interval" {
    const candidate: fsrs.Candidate = .{
        .rating = .good,
        .due_at_ms = 1234,
        .interval_days = 2.5,
    };
    const response = candidateResponse(candidate);
    try std.testing.expectEqual(@as(u8, 3), response.rating);
    try std.testing.expectEqual(@as(i64, 1234), response.due_at_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), response.interval_days, 1e-12);
}

test "study review-order parser accepts the CLI spellings" {
    try std.testing.expectEqual(study_mod.ReviewOrder.due, try parseReviewOrder("due"));
    try std.testing.expectEqual(study_mod.ReviewOrder.reviews_first, try parseReviewOrder("reviews-first"));
    try std.testing.expectEqual(study_mod.ReviewOrder.new_first, try parseReviewOrder("new-first"));
    try std.testing.expectError(error.InvalidReviewOrder, parseReviewOrder("random"));
}
