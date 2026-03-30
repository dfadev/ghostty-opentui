const std = @import("std");
const builtin = @import("builtin");
const napigen = if (builtin.is_test) undefined else @import("napigen");
const ghostty_vt = @import("ghostty-vt");
const color = ghostty_vt.color;
const pagepkg = ghostty_vt.page;
const formatter = ghostty_vt.formatter;
const Screen = ghostty_vt.Screen;

// Disable all logging from ghostty-vt library
pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = struct {
        pub fn logFn(
            comptime _: std.log.Level,
            comptime _: @Type(.enum_literal),
            comptime _: []const u8,
            _: anytype,
        ) void {}
    }.logFn,
};

pub const StyleFlags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    inverse: bool = false,
    faint: bool = false,
    _padding: u2 = 0,

    pub fn toInt(self: StyleFlags) u8 {
        return @bitCast(self);
    }

    pub fn eql(self: StyleFlags, other: StyleFlags) bool {
        return self.toInt() == other.toInt();
    }
};

pub const CellStyle = struct {
    fg: ?color.RGB,
    bg: ?color.RGB,
    flags: StyleFlags,

    pub fn eql(self: CellStyle, other: CellStyle) bool {
        const fg_eq = if (self.fg) |a| (if (other.fg) |b| a.r == b.r and a.g == b.g and a.b == b.b else false) else other.fg == null;
        const bg_eq = if (self.bg) |a| (if (other.bg) |b| a.r == b.r and a.g == b.g and a.b == b.b else false) else other.bg == null;
        return fg_eq and bg_eq and self.flags.eql(other.flags);
    }
};

fn getStyleFromCell(
    cell: *const pagepkg.Cell,
    pin: ghostty_vt.Pin,
    palette: *const color.Palette,
    terminal_bg: ?color.RGB,
) CellStyle {
    var flags: StyleFlags = .{};
    var fg: ?color.RGB = null;
    var bg: ?color.RGB = null;

    const style = pin.style(cell);

    flags.bold = style.flags.bold;
    flags.italic = style.flags.italic;
    flags.faint = style.flags.faint;
    flags.inverse = style.flags.inverse;
    flags.strikethrough = style.flags.strikethrough;
    flags.underline = style.flags.underline != .none;

    fg = switch (style.fg_color) {
        .none => null,
        .palette => |idx| palette[idx],
        .rgb => |rgb| rgb,
    };

    bg = style.bg(cell, palette) orelse switch (cell.content_tag) {
        .bg_color_palette => palette[cell.content.color_palette],
        .bg_color_rgb => .{ .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b },
        else => null,
    };

    // If the background color matches the terminal's default background, treat it as transparent
    if (bg) |cell_bg| {
        if (terminal_bg) |term_bg| {
            if (cell_bg.r == term_bg.r and cell_bg.g == term_bg.g and cell_bg.b == term_bg.b) {
                bg = null;
            }
        }
    }

    return .{ .fg = fg, .bg = bg, .flags = flags };
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeColor(writer: anytype, rgb: ?color.RGB) !void {
    if (rgb) |c| {
        try writer.print("\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ c.r, c.g, c.b });
    } else {
        try writer.writeAll("null");
    }
}

/// Count total lines in terminal screen
fn countLines(screen: *Screen) usize {
    return screen.pages.total_rows;
}

/// Check if terminal has at least `threshold` lines - O(threshold) not O(total)
fn hasEnoughLines(screen: *Screen, threshold: usize) bool {
    var count: usize = 0;
    var iter = screen.pages.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (iter.next()) |_| {
        count += 1;
        if (count >= threshold) return true;
    }
    return false;
}

pub fn writeJsonOutput(
    writer: anytype,
    t: *ghostty_vt.Terminal,
    offset: usize,
    limit: ?usize,
    cursor_style_set: bool,
    total_lines: usize,
) !void {
    const screen = t.screens.active;
    const palette = &t.colors.palette.current;
    const terminal_bg = t.colors.background.get();

    // Check if cursor is visible (DECTCEM mode - DEC text cursor enable mode)
    const cursor_visible = t.modes.get(.cursor_visible);

    // If the inner application explicitly set a cursor style via DECSCUSR,
    // report the actual style. Otherwise report "default" so the consumer
    // can preserve the outer terminal's native cursor.
    const cursor_style_name: []const u8 = if (cursor_style_set)
        @tagName(screen.cursor.cursor_style)
    else
        "default";

    try writer.writeAll("{");
    try writer.print("\"cols\":{},\"rows\":{},", .{ screen.pages.cols, screen.pages.rows });
    try writer.print("\"cursor\":[{},{}],", .{ screen.cursor.x, screen.cursor.y });
    try writer.print("\"cursorVisible\":{},", .{cursor_visible});
    try writer.print("\"cursorStyle\":\"{s}\",", .{cursor_style_name});
    try writer.print("\"offset\":{},\"totalLines\":{},", .{ offset, total_lines });
    try writer.writeAll("\"lines\":[");

    var text_buf: [4096]u8 = undefined;
    // Start iteration directly at `offset` — O(1) seek via Point.screen
    var row_iter = screen.pages.rowIterator(
        .right_down,
        .{ .screen = .{ .y = @intCast(offset) } },
        null,
    );
    var output_idx: usize = 0;

    while (row_iter.next()) |pin| {
        if (limit) |lim| {
            if (output_idx >= lim) break;
        }

        if (output_idx > 0) try writer.writeByte(',');
        try writer.writeByte('[');

        const cells = pin.cells(.all);

        // First pass: find the last column with actual content (non-null codepoint)
        // This allows us to trim trailing spaces while preserving internal spaces (e.g., from tabs)
        var last_content_col: usize = 0;
        for (cells, 0..) |*cell, col_idx| {
            if (cell.wide == .spacer_tail) continue;
            if (cell.codepoint() != 0) {
                last_content_col = col_idx + 1; // +1 because we want to include this column
            }
        }

        // Extend to include trailing styled empty cells (e.g., from EL with an explicit
        // background color). Terminal programs sometimes use "\x1b[48;2;r;g;bm\x1b[K" or
        // "\x1b[48;5;Nm\x1b[K" to create full-width colored bands. Without this, those
        // erased-but-styled cells get trimmed because they have codepoint=0.
        if (last_content_col < cells.len) {
            var scan: usize = cells.len;
            while (scan > last_content_col) {
                scan -= 1;
                const cell = &cells[scan];
                if (cell.wide == .spacer_tail) continue;
                if (cell.codepoint() != 0) break; // Content cell, already handled
                const style = getStyleFromCell(cell, pin, palette, terminal_bg);
                if (style.bg != null) {
                    last_content_col = scan + 1;
                    break;
                }
            }
        }

        var span_start: usize = 0;
        var span_len: usize = 0;
        var current_style: ?CellStyle = null;
        var text_len: usize = 0;
        var span_idx: usize = 0;

        for (cells, 0..) |*cell, col_idx| {
            if (cell.wide == .spacer_tail) continue;
            // Stop at the last content column (trim trailing nulls/spaces)
            if (col_idx >= last_content_col) break;

            const raw_cp = cell.codepoint();
            // Treat null cells as spaces (important for tab expansion)
            // Null cells occur when cursor moves (e.g., tab) without writing characters
            const cp: u32 = if (raw_cp == 0) ' ' else raw_cp;

            const style = getStyleFromCell(cell, pin, palette, terminal_bg);
            const style_changed = if (current_style) |cs| !cs.eql(style) else true;

            if (style_changed and text_len > 0) {
                if (span_idx > 0) try writer.writeByte(',');
                try writer.writeByte('[');
                try writeJsonString(writer, text_buf[0..text_len]);
                try writer.writeByte(',');
                try writeColor(writer, current_style.?.fg);
                try writer.writeByte(',');
                try writeColor(writer, current_style.?.bg);
                try writer.print(",{},{}", .{ current_style.?.flags.toInt(), span_len });
                try writer.writeByte(']');
                span_idx += 1;
                text_len = 0;
                span_len = 0;
            }

            if (style_changed) {
                span_start = col_idx;
                current_style = style;
            }

            const cp21: u21 = @intCast(cp);
            const len = std.unicode.utf8CodepointSequenceLength(cp21) catch 1;
            if (text_len + len <= text_buf.len) {
                _ = std.unicode.utf8Encode(cp21, text_buf[text_len..]) catch 0;
                text_len += len;
            }

            span_len += if (cell.wide == .wide) 2 else 1;
        }

        if (text_len > 0) {
            if (span_idx > 0) try writer.writeByte(',');
            try writer.writeByte('[');
            try writeJsonString(writer, text_buf[0..text_len]);
            try writer.writeByte(',');
            try writeColor(writer, current_style.?.fg);
            try writer.writeByte(',');
            try writeColor(writer, current_style.?.bg);
            try writer.print(",{},{}", .{ current_style.?.flags.toInt(), span_len });
            try writer.writeByte(']');
        }

        try writer.writeByte(']');
        output_idx += 1;
    }

    try writer.writeAll("]}");
}

// =============================================================================
// Binary cell export
// =============================================================================

/// Write a binary span: [u16 width][3×u8 fg_rgb][u8 fg_present][3×u8 bg_rgb][u8 bg_present][u8 flags][u8 pad][u16 text_len][text_bytes...]
fn writeBinarySpan(writer: anytype, style: CellStyle, text: []const u8, width: u16) !void {
    try writer.writeInt(u16, width, .little);
    // fg
    if (style.fg) |c| {
        try writer.writeByte(c.r);
        try writer.writeByte(c.g);
        try writer.writeByte(c.b);
        try writer.writeByte(1);
    } else {
        try writer.writeByteNTimes(0, 4);
    }
    // bg
    if (style.bg) |c| {
        try writer.writeByte(c.r);
        try writer.writeByte(c.g);
        try writer.writeByte(c.b);
        try writer.writeByte(1);
    } else {
        try writer.writeByteNTimes(0, 4);
    }
    try writer.writeByte(style.flags.toInt());
    try writer.writeByte(0); // pad
    try writer.writeInt(u16, @intCast(text.len), .little);
    try writer.writeAll(text);
}

/// Write binary terminal output into an ArrayList so we can patch num_spans per row.
pub fn writeBinaryOutput(
    output: *std.ArrayListAligned(u8, null),
    alloc: std.mem.Allocator,
    t: *ghostty_vt.Terminal,
    offset: usize,
    limit: ?usize,
    cursor_style_set: bool,
    total_lines: usize,
) !void {
    const screen = t.screens.active;
    const palette = &t.colors.palette.current;
    const terminal_bg = t.colors.background.get();
    const cursor_visible = t.modes.get(.cursor_visible);

    // Encode cursor style: 0=default, 1=block, 2=bar, 3=underline, 4=block_hollow
    const cursor_style: u8 = if (!cursor_style_set) 0 else switch (screen.cursor.cursor_style) {
        .block => 1,
        .bar => 2,
        .underline => 3,
        .block_hollow => 4,
    };

    const writer = output.writer(alloc);

    // Header (24 bytes) — num_rows placeholder patched after the loop
    try writer.writeInt(u16, @intCast(screen.pages.cols), .little);
    try writer.writeInt(u16, @intCast(screen.pages.rows), .little);
    try writer.writeInt(u16, @intCast(screen.cursor.x), .little);
    try writer.writeInt(u16, @intCast(screen.cursor.y), .little);
    try writer.writeByte(if (cursor_visible) 1 else 0);
    try writer.writeByte(cursor_style);
    try writer.writeByteNTimes(0, 2); // pad
    try writer.writeInt(u32, @intCast(offset), .little);
    try writer.writeInt(u32, @intCast(total_lines), .little);
    const num_rows_pos = output.items.len;
    try writer.writeInt(u16, 0, .little); // placeholder — patched below
    try writer.writeByteNTimes(0, 2); // pad

    // Start iteration directly at `offset` using Point.screen — O(1) seek
    var text_buf: [4096]u8 = undefined;
    var row_iter = screen.pages.rowIterator(
        .right_down,
        .{ .screen = .{ .y = @intCast(offset) } },
        null,
    );
    var num_rows: u16 = 0;

    while (row_iter.next()) |pin| {
        if (limit) |lim| {
            if (num_rows >= lim) break;
        }

        // Reserve 2 bytes for num_spans, will patch after processing row
        const count_pos = output.items.len;
        try writer.writeInt(u16, 0, .little); // placeholder

        const cells = pin.cells(.all);

        // Find last content column (same logic as writeJsonOutput)
        var last_content_col: usize = 0;
        for (cells, 0..) |*cell, col_idx| {
            if (cell.wide == .spacer_tail) continue;
            if (cell.codepoint() != 0) {
                last_content_col = col_idx + 1;
            }
        }

        // Extend for trailing styled empty cells (EL with background)
        if (last_content_col < cells.len) {
            var scan: usize = cells.len;
            while (scan > last_content_col) {
                scan -= 1;
                const cell = &cells[scan];
                if (cell.wide == .spacer_tail) continue;
                if (cell.codepoint() != 0) break;
                const style = getStyleFromCell(cell, pin, palette, terminal_bg);
                if (style.bg != null) {
                    last_content_col = scan + 1;
                    break;
                }
            }
        }

        var span_len: u16 = 0;
        var current_style: ?CellStyle = null;
        var text_len: usize = 0;
        var span_count: u16 = 0;

        for (cells, 0..) |*cell, col_idx| {
            if (cell.wide == .spacer_tail) continue;
            if (col_idx >= last_content_col) break;

            const raw_cp = cell.codepoint();
            const cp: u32 = if (raw_cp == 0) ' ' else raw_cp;

            const style = getStyleFromCell(cell, pin, palette, terminal_bg);
            const style_changed = if (current_style) |cs| !cs.eql(style) else true;

            if (style_changed and text_len > 0) {
                try writeBinarySpan(writer, current_style.?, text_buf[0..text_len], span_len);
                span_count += 1;
                text_len = 0;
                span_len = 0;
            }

            if (style_changed) {
                current_style = style;
            }

            const cp21: u21 = @intCast(cp);
            const len = std.unicode.utf8CodepointSequenceLength(cp21) catch 1;
            if (text_len + len <= text_buf.len) {
                _ = std.unicode.utf8Encode(cp21, text_buf[text_len..]) catch 0;
                text_len += len;
            }

            span_len += if (cell.wide == .wide) 2 else 1;
        }

        // Flush last span
        if (text_len > 0) {
            try writeBinarySpan(writer, current_style.?, text_buf[0..text_len], span_len);
            span_count += 1;
        }

        // Patch num_spans
        std.mem.writeInt(u16, output.items[count_pos..][0..2], span_count, .little);

        num_rows += 1;
    }

    // Patch num_rows in header
    std.mem.writeInt(u16, output.items[num_rows_pos..][0..2], num_rows, .little);
}

// Thread-local allocator for NAPI functions
// The arena is reset at the START of each NAPI call, allowing the previous call's
// return value to survive until napigen copies it to a JS string.
threadlocal var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn getArenaAllocator() std.mem.Allocator {
    // Reset arena at the start of each call - this frees memory from the previous call
    // AFTER napigen has already copied the return value to JS
    _ = arena.reset(.retain_capacity);
    return arena.allocator();
}

// =============================================================================
// Persistent Terminal Management
// =============================================================================

/// The stream type returned by Terminal.vtStream()
const ReadonlyStream = @typeInfo(@TypeOf(ghostty_vt.Terminal.vtStream)).@"fn".return_type.?;

/// A persistent terminal instance
const PersistentTerminal = struct {
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,
    /// Persistent stream that maintains parser state across feed() calls.
    /// This is critical for handling ANSI escape sequences that may be split
    /// across multiple data chunks from the PTY.
    stream: ?ReadonlyStream,
    /// Whether the inner application has explicitly set a cursor style via
    /// DECSCUSR. When false, the cursor style is still the VT default (block)
    /// and consumers should treat it as "default" (preserve the outer
    /// terminal's native cursor).
    cursor_style_set: bool = false,

    /// Generation counter for dirty tracking — increments on every feed().
    generation: u64 = 0,
    /// Generation at which data was last read (via getJson/getBinary).
    last_read_gen: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !PersistentTerminal {
        var terminal = try ghostty_vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = std.math.maxInt(usize),
        });

        // Enable linefeed mode so LF (\n) also performs carriage return
        terminal.modes.set(.linefeed, true);

        return .{
            .terminal = terminal,
            .allocator = alloc,
            // Stream is created lazily in initStream() after the struct is at its final location.
            // This is necessary because the stream holds a pointer to the terminal.
            .stream = null,
        };
    }

    /// Initialize the stream after the struct has been placed at its final heap location.
    /// Must be called once after init() before any feed() calls.
    pub fn initStream(self: *PersistentTerminal) void {
        self.stream = self.terminal.vtStream();
    }

    pub fn deinit(self: *PersistentTerminal) void {
        if (self.stream) |*s| {
            s.deinit();
        }
        self.terminal.deinit(self.allocator);
    }

    pub fn feed(self: *PersistentTerminal, data: []const u8) !void {
        var timer = std.time.Timer.start() catch unreachable;

        const style_before = self.terminal.screens.active.cursor.cursor_style;

        // Use the persistent stream to maintain parser state across calls.
        // This ensures that escape sequences split across multiple chunks
        // are parsed correctly.
        const t_before_parse = timer.read();
        try self.stream.?.nextSlice(data);
        const t_after_parse = timer.read();

        // Detect if the inner application sent a DECSCUSR to change cursor style.
        if (!self.cursor_style_set) {
            if (self.terminal.screens.active.cursor.cursor_style != style_before) {
                self.cursor_style_set = true;
            }
        }
        self.generation +%= 1;
        const t_end = timer.read();

        const parse_ms = @as(f64, @floatFromInt(t_after_parse - t_before_parse)) / 1_000_000.0;
        const total_ms = @as(f64, @floatFromInt(t_end)) / 1_000_000.0;

        if (total_ms > 1.0) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[zig feed] {d}b total={d:.1}ms parse={d:.1}ms\n", .{ data.len, total_ms, parse_ms }) catch return;
            const file = std.fs.cwd().openFile("/tmp/zig-perf.log", .{ .mode = .write_only }) catch return;
            defer file.close();
            file.seekFromEnd(0) catch return;
            _ = file.write(msg) catch {};
        }
    }

    /// Return total line count — O(1) via Ghostty's maintained total_rows.
    pub fn getTotalLines(self: *PersistentTerminal) usize {
        return countLines(self.terminal.screens.active);
    }

    /// Returns true if terminal content has changed since the last read.
    pub fn isDirty(self: *const PersistentTerminal) bool {
        return self.generation != self.last_read_gen;
    }

    /// Mark the terminal as clean (called after reading data).
    pub fn markClean(self: *PersistentTerminal) void {
        self.last_read_gen = self.generation;
    }

    /// Returns true if the parser is in ground state, meaning all escape
    /// sequences have been fully processed and it's safe to read terminal content.
    pub fn isReady(self: *const PersistentTerminal) bool {
        if (self.stream) |s| {
            return s.parser.state == .ground;
        }
        return true;
    }

    pub fn resize(self: *PersistentTerminal, cols: u16, rows: u16) !void {
        try self.terminal.resize(self.allocator, cols, rows);
        self.generation +%= 1;
    }

    pub fn reset(self: *PersistentTerminal) void {
        self.terminal.fullReset();
        self.cursor_style_set = false;
        // Recreate the stream to reset parser state
        if (self.stream) |*s| {
            s.deinit();
        }
        self.stream = self.terminal.vtStream();
        self.generation = 0;
        self.last_read_gen = 0;
    }
};

/// Global storage for persistent terminals
/// Uses a mutex for thread-safety since NAPI can call from different threads
var terminals_mutex: std.Thread.Mutex = .{};
var terminals: ?std.AutoHashMap(u32, *PersistentTerminal) = null;

fn getTerminalsMap() *std.AutoHashMap(u32, *PersistentTerminal) {
    if (terminals == null) {
        terminals = std.AutoHashMap(u32, *PersistentTerminal).init(std.heap.page_allocator);
    }
    return &terminals.?;
}

/// Create a new persistent terminal with the given ID
fn createTerminal(id: u32, cols: u32, rows: u32) !void {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();

    // If terminal with this ID already exists, destroy it first
    if (map.get(id)) |existing| {
        existing.deinit();
        std.heap.page_allocator.destroy(existing);
        _ = map.remove(id);
    }

    // Create new terminal
    const term_ptr = try std.heap.page_allocator.create(PersistentTerminal);
    errdefer std.heap.page_allocator.destroy(term_ptr);

    term_ptr.* = try PersistentTerminal.init(
        std.heap.page_allocator,
        @intCast(cols),
        @intCast(rows),
    );

    // Initialize the stream after the struct is at its final heap location.
    // This is critical because the stream holds a pointer to the terminal.
    term_ptr.initStream();

    try map.put(id, term_ptr);
}

/// Destroy a persistent terminal
fn destroyTerminal(id: u32) void {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    if (map.get(id)) |term| {
        term.deinit();
        std.heap.page_allocator.destroy(term);
        _ = map.remove(id);
    }
}

/// Feed data to a persistent terminal (string path — napigen converts JS string to []const u8)
fn feedTerminal(id: u32, data: []const u8) !void {
    var timer = std.time.Timer.start() catch unreachable;

    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const t_after_lock = timer.read();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;
    const t_after_lookup = timer.read();

    try term.feed(data);
    const t_end = timer.read();

    const total_ms = @as(f64, @floatFromInt(t_end)) / 1_000_000.0;
    if (total_ms > 1.0) {
        const lock_ms = @as(f64, @floatFromInt(t_after_lock)) / 1_000_000.0;
        const lookup_ms = @as(f64, @floatFromInt(t_after_lookup - t_after_lock)) / 1_000_000.0;
        const feed_ms = @as(f64, @floatFromInt(t_end - t_after_lookup)) / 1_000_000.0;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[feedTerminal] {d}b total={d:.1}ms lock={d:.1}ms lookup={d:.1}ms feed={d:.1}ms\n", .{ data.len, total_ms, lock_ms, lookup_ms, feed_ms }) catch return;
        const file = std.fs.cwd().openFile("/tmp/zig-perf.log", .{ .mode = .write_only }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        _ = file.write(msg) catch {};
    }
}

/// Feed raw binary data (Buffer or Uint8Array) to a persistent terminal.
/// Uses napigen escape hatch to read the buffer's backing memory directly,
/// avoiding the JS string → UTF-8 round-trip that feedTerminal requires.
fn feedTerminalBuffer(js: *napigen.JsContext, id: u32, buffer_val: napigen.napi_value) !void {
    var timer = std.time.Timer.start() catch unreachable;

    var data_ptr: ?*anyopaque = null;
    var data_len: usize = 0;

    // Try Node.js Buffer first (napi_get_buffer_info).
    var is_buffer: bool = false;
    if (napigen.napi.napi_is_buffer(js.env, buffer_val, &is_buffer) != 0)
        return error.NapiCheckFailed;

    if (is_buffer) {
        if (napigen.napi.napi_get_buffer_info(js.env, buffer_val, &data_ptr, &data_len) != 0)
            return error.NapiBufferReadFailed;
    } else {
        // Fall back to TypedArray (plain Uint8Array that isn't a Buffer).
        var is_typedarray: bool = false;
        if (napigen.napi.napi_is_typedarray(js.env, buffer_val, &is_typedarray) != 0)
            return error.NapiCheckFailed;
        if (!is_typedarray)
            return error.ExpectedBufferOrTypedArray;
        if (napigen.napi.napi_get_typedarray_info(js.env, buffer_val, null, &data_len, &data_ptr, null, null) != 0)
            return error.NapiTypedArrayReadFailed;
    }

    if (data_ptr == null or data_len == 0) return;

    const data: []const u8 = @as([*]const u8, @ptrCast(data_ptr.?))[0..data_len];
    const t_after_extract = timer.read();

    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;
    try term.feed(data);
    const t_end = timer.read();

    const total_ms = @as(f64, @floatFromInt(t_end)) / 1_000_000.0;
    if (total_ms > 1.0) {
        const extract_ms = @as(f64, @floatFromInt(t_after_extract)) / 1_000_000.0;
        const feed_ms = @as(f64, @floatFromInt(t_end - t_after_extract)) / 1_000_000.0;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[feedTerminalBuffer] {d}b total={d:.1}ms extract={d:.1}ms feed={d:.1}ms\n", .{ data.len, total_ms, extract_ms, feed_ms }) catch return;
        const file = std.fs.cwd().openFile("/tmp/zig-perf.log", .{ .mode = .write_only }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        _ = file.write(msg) catch {};
    }
}

/// Resize a persistent terminal
fn resizeTerminal(id: u32, cols: u32, rows: u32) !void {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;
    try term.resize(@intCast(cols), @intCast(rows));
}

/// Reset a persistent terminal to initial state
fn resetTerminal(id: u32) !void {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;
    term.reset();
}

/// Get JSON output from a persistent terminal
fn getTerminalJson(id: u32, offset: u32, limit: u32) ![]const u8 {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    const alloc = getArenaAllocator();
    // Note: arena is reset at the START of the next call, not here.
    // This allows napigen to copy the returned slice to JS before memory is reused.

    const lim: ?usize = if (limit == 0) null else @intCast(limit);

    var output: std.ArrayListAligned(u8, null) = .empty;
    try writeJsonOutput(output.writer(alloc), &term.terminal, @intCast(offset), lim, term.cursor_style_set, term.getTotalLines());

    return output.items;
}

/// Get plain text output from a persistent terminal
fn getTerminalText(id: u32) ![]const u8 {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    const alloc = getArenaAllocator();
    // Note: arena is reset at the START of the next call, not here.

    var builder: std.Io.Writer.Allocating = .init(alloc);
    var fmt: formatter.TerminalFormatter = formatter.TerminalFormatter.init(&term.terminal, .plain);
    try fmt.format(&builder.writer);

    return builder.writer.buffered();
}

/// Get cursor position from a persistent terminal as [x, y] JSON
fn getTerminalCursor(id: u32) ![]const u8 {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    const screen = term.terminal.screens.active;

    const alloc = getArenaAllocator();
    // Note: arena is reset at the START of the next call, not here.

    return std.fmt.allocPrint(alloc, "[{},{}]", .{ screen.cursor.x, screen.cursor.y });
}

/// Get cursor position as a packed u32: (x << 16) | y.
/// Avoids string allocation + JSON.parse overhead of getTerminalCursor.
fn getTerminalCursorPacked(id: u32) !u32 {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    const screen = term.terminal.screens.active;
    const x: u16 = @intCast(screen.cursor.x);
    const y: u16 = @intCast(screen.cursor.y);
    return (@as(u32, x) << 16) | @as(u32, y);
}

fn getTerminalTotalLines(id: u32) !u32 {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    return @intCast(term.getTotalLines());
}

fn isTerminalReady(id: u32) !bool {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    return term.isReady();
}

/// Check if terminal content has changed since last markClean
fn isTerminalDirty(id: u32) !bool {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    return term.isDirty();
}

/// Mark terminal as clean (content has been read)
fn markTerminalClean(id: u32) !void {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    term.markClean();
}

/// Convert PTY input to JSON format
/// Returns JSON string with terminal data (cols, rows, cursor, lines with styled spans)
/// When limit is set, uses chunked parsing with early exit for better performance.
fn ptyToJson(input: []const u8, cols: u32, rows: u32, offset: u32, limit: u32) ![]const u8 {
    const alloc = getArenaAllocator();
    // Note: arena is reset at the START of the next call, not here.
    // This allows napigen to copy the returned slice to JS before memory is reused.

    const lim: ?usize = if (limit == 0) null else @intCast(limit);

    // Use unlimited scrollback so we don't lose content
    var t: ghostty_vt.Terminal = try ghostty_vt.Terminal.init(alloc, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    // Enable linefeed mode so LF (\n) also performs carriage return (moves to column 0)
    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    const style_before = t.screens.active.cursor.cursor_style;

    // When limit is set, use chunked parsing with early exit
    // This allows us to stop parsing once we have enough lines
    if (lim) |line_limit| {
        const chunk_size: usize = 4096; // Process 4KB at a time
        const threshold = line_limit + offset + 20; // Extra buffer for safety
        var pos: usize = 0;

        while (pos < input.len) {
            const end = @min(pos + chunk_size, input.len);
            try stream.nextSlice(input[pos..end]);
            pos = end;

            // Check if we have enough lines and parser is in ground state
            // (not in the middle of an escape sequence)
            if (stream.parser.state == .ground) {
                if (hasEnoughLines(t.screens.active, threshold)) {
                    break; // Early exit!
                }
            }
        }
    } else {
        // No limit - parse everything
        try stream.nextSlice(input);
    }

    const cursor_style_set = t.screens.active.cursor.cursor_style != style_before;

    var output: std.ArrayListAligned(u8, null) = .empty;
    try writeJsonOutput(output.writer(alloc), &t, @intCast(offset), lim, cursor_style_set, countLines(t.screens.active));

    return output.items;
}

/// Convert PTY input to plain text (strips ANSI escape codes)
fn ptyToText(input: []const u8, cols: u32, rows: u32) ![]const u8 {
    const alloc = getArenaAllocator();
    // Note: arena is reset at the START of the next call, not here.

    // Use unlimited scrollback so we don't lose content
    var t: ghostty_vt.Terminal = try ghostty_vt.Terminal.init(alloc, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    // Enable linefeed mode so LF (\n) also performs carriage return (moves to column 0)
    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    try stream.nextSlice(input);

    // Use the ghostty formatter with plain format to get just the text
    var builder: std.Io.Writer.Allocating = .init(alloc);
    var fmt: formatter.TerminalFormatter = formatter.TerminalFormatter.init(&t, .plain);
    try fmt.format(&builder.writer);

    return builder.writer.buffered();
}

/// Convert PTY input to styled HTML
fn ptyToHtml(input: []const u8, cols: u32, rows: u32) ![]const u8 {
    const alloc = getArenaAllocator();
    // Note: arena is reset at the START of the next call, not here.

    // Use unlimited scrollback so we don't lose content
    var t: ghostty_vt.Terminal = try ghostty_vt.Terminal.init(alloc, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    // Enable linefeed mode so LF (\n) also performs carriage return (moves to column 0)
    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    try stream.nextSlice(input);

    // Use the ghostty formatter with html format to get styled HTML
    var builder: std.Io.Writer.Allocating = .init(alloc);
    var fmt: formatter.TerminalFormatter = formatter.TerminalFormatter.init(&t, .html);
    try fmt.format(&builder.writer);

    return builder.writer.buffered();
}

// Define the NAPI module (only when not testing)
comptime {
    if (!builtin.is_test) {
        napigen.defineModule(initModule);
    }
}

/// Get binary cell data from a persistent terminal, returned as a Node.js Buffer.
/// Uses napigen escape hatch: accepts *JsContext (auto-injected), returns raw napi_value.
/// The JS caller passes (id, offset, limit) — three args.
fn getTerminalCells(js: *napigen.JsContext, id: u32, offset: u32, limit: u32) !napigen.napi_value {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    const alloc = getArenaAllocator();
    const lim: ?usize = if (limit == 0) null else @intCast(limit);

    var output: std.ArrayListAligned(u8, null) = .empty;
    try writeBinaryOutput(&output, alloc, &term.terminal, @intCast(offset), lim, term.cursor_style_set, term.getTotalLines());

    // Return as Node.js Buffer via napi_create_buffer_copy.
    // This copies our bytes into V8-managed memory. The arena memory is freed
    // on the next N-API call as usual.
    var result: napigen.napi_value = undefined;
    const status = napigen.napi.napi_create_buffer_copy(
        js.env,
        output.items.len,
        @ptrCast(output.items.ptr),
        null,
        &result,
    );
    if (status != 0) return error.NapiBufferCreateFailed;
    return result;
}

/// Batched version: gets cells + marks clean in one N-API crossing.
/// scroll_offset < 0 means auto-scroll to bottom.
/// Replaces the getTotalLines() + getTerminalCells() + markClean() triple.
fn getTerminalCellsBatched(js: *napigen.JsContext, id: u32, scroll_offset: i32, limit: u32) !napigen.napi_value {
    terminals_mutex.lock();
    defer terminals_mutex.unlock();

    const map = getTerminalsMap();
    const term = map.get(id) orelse return error.TerminalNotFound;

    // Use page_allocator (not arena) so the buffer outlives this call.
    // V8 will own the memory via napi_create_external_buffer and free it on GC.
    const alloc = std.heap.page_allocator;
    const lim: usize = if (limit == 0) @intCast(term.terminal.rows) else @intCast(limit);
    const total = term.getTotalLines();
    const max_offset: usize = if (total > lim) total - lim else 0;

    // Compute effective offset: negative means auto-scroll to bottom
    const effective_offset: usize = if (scroll_offset < 0)
        max_offset
    else
        @min(@as(usize, @intCast(scroll_offset)), max_offset);

    var output: std.ArrayListAligned(u8, null) = .empty;
    try writeBinaryOutput(&output, alloc, &term.terminal, effective_offset, lim, term.cursor_style_set, total);

    // Mark clean within the same lock
    term.markClean();

    // Return as external buffer — V8 uses our memory directly, no copy.
    // freeExternalBuffer is called when V8 GCs the Buffer.
    var result: napigen.napi_value = undefined;
    const status = napigen.napi.napi_create_external_buffer(
        js.env,
        output.items.len,
        @ptrCast(output.items.ptr),
        freeExternalBuffer,
        @ptrFromInt(output.capacity),
        &result,
    );
    if (status != 0) {
        output.deinit(alloc);
        return error.NapiBufferCreateFailed;
    }
    return result;
}

/// Release callback for napi_create_external_buffer.
/// Called by V8 GC when the JS Buffer is collected.
fn freeExternalBuffer(_: napigen.napi.napi_env, data: ?*anyopaque, hint: ?*anyopaque) callconv(.c) void {
    const capacity = @intFromPtr(hint);
    if (capacity > 0 and data != null) {
        const ptr: [*]u8 = @ptrCast(data.?);
        std.heap.page_allocator.free(ptr[0..capacity]);
    }
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) anyerror!napigen.napi_value {
    // Stateless functions (create terminal each call)
    try js.setNamedProperty(exports, "ptyToJson", try js.createFunction(ptyToJson));
    try js.setNamedProperty(exports, "ptyToText", try js.createFunction(ptyToText));
    try js.setNamedProperty(exports, "ptyToHtml", try js.createFunction(ptyToHtml));

    // Persistent terminal management functions
    try js.setNamedProperty(exports, "createTerminal", try js.createFunction(createTerminal));
    try js.setNamedProperty(exports, "destroyTerminal", try js.createFunction(destroyTerminal));
    try js.setNamedProperty(exports, "feedTerminal", try js.createFunction(feedTerminal));
    try js.setNamedProperty(exports, "feedTerminalBuffer", try js.createFunction(feedTerminalBuffer));
    try js.setNamedProperty(exports, "resizeTerminal", try js.createFunction(resizeTerminal));
    try js.setNamedProperty(exports, "resetTerminal", try js.createFunction(resetTerminal));
    try js.setNamedProperty(exports, "getTerminalJson", try js.createFunction(getTerminalJson));
    try js.setNamedProperty(exports, "getTerminalText", try js.createFunction(getTerminalText));
    try js.setNamedProperty(exports, "getTerminalCursor", try js.createFunction(getTerminalCursor));
    try js.setNamedProperty(exports, "getTerminalCursorPacked", try js.createFunction(getTerminalCursorPacked));
    try js.setNamedProperty(exports, "getTerminalTotalLines", try js.createFunction(getTerminalTotalLines));
    try js.setNamedProperty(exports, "isTerminalReady", try js.createFunction(isTerminalReady));
    try js.setNamedProperty(exports, "getTerminalCells", try js.createFunction(getTerminalCells));
    try js.setNamedProperty(exports, "getTerminalCellsBatched", try js.createFunction(getTerminalCellsBatched));
    try js.setNamedProperty(exports, "isTerminalDirty", try js.createFunction(isTerminalDirty));
    try js.setNamedProperty(exports, "markTerminalClean", try js.createFunction(markTerminalClean));

    return exports;
}

const testing = std.testing;

test "basic JSON output" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    try stream.nextSlice("Hello");

    var output: std.ArrayListAligned(u8, null) = .empty;
    defer output.deinit(alloc);

    try writeJsonOutput(output.writer(alloc), &t, 0, null, false, countLines(t.screens.active));

    const json = output.items;
    try testing.expect(std.mem.indexOf(u8, json, "\"cols\":80") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"totalLines\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Hello\"") != null);
}

test "ptyToText strips ANSI and returns plain text" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    // Enable linefeed mode to match ptyToText behavior
    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    // Input with ANSI color codes: red "Hello" and green "World"
    try stream.nextSlice("\x1b[31mHello\x1b[0m \x1b[32mWorld\x1b[0m");

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var fmt: formatter.TerminalFormatter = formatter.TerminalFormatter.init(&t, .plain);
    try fmt.format(&builder.writer);

    const output = builder.writer.buffered();
    try testing.expectEqualStrings("Hello World", output);
}

test "ptyToText handles multiline with ANSI" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    // Input with ANSI codes across multiple lines
    try stream.nextSlice("\x1b[1mBold\x1b[0m\n\x1b[4mUnderline\x1b[0m");

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var fmt: formatter.TerminalFormatter = formatter.TerminalFormatter.init(&t, .plain);
    try fmt.format(&builder.writer);

    const output = builder.writer.buffered();
    try testing.expectEqualStrings("Bold\nUnderline", output);
}

test "ptyToHtml returns styled HTML" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    // Input with ANSI color codes: red "Hello"
    try stream.nextSlice("\x1b[31mHello\x1b[0m");

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var fmt: formatter.TerminalFormatter = formatter.TerminalFormatter.init(&t, .html);
    try fmt.format(&builder.writer);

    const output = builder.writer.buffered();
    // HTML output should contain style tags and the text
    try testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, output, "<") != null);
}

// =============================================================================
// Persistent Terminal Tests
// =============================================================================

test "PersistentTerminal init and deinit" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Verify terminal was created with correct dimensions
    try testing.expectEqual(@as(u16, 80), term.terminal.cols);
    try testing.expectEqual(@as(u16, 24), term.terminal.rows);
}

test "PersistentTerminal feed data" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Feed some data
    try term.feed("Hello World");

    // Verify cursor moved
    try testing.expectEqual(@as(usize, 11), term.terminal.screens.active.cursor.x);
}

test "PersistentTerminal feed multiple times" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Feed data in multiple chunks (simulating streaming)
    try term.feed("Hello ");
    try term.feed("World");
    try term.feed("\n");
    try term.feed("Line 2");

    // Verify cursor is on line 2
    try testing.expectEqual(@as(usize, 1), term.terminal.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 6), term.terminal.screens.active.cursor.x);
}

test "PersistentTerminal reset" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Feed some data
    try term.feed("Hello World\nLine 2\nLine 3");

    // Verify cursor moved
    try testing.expect(term.terminal.screens.active.cursor.y > 0);

    // Reset terminal
    term.reset();

    // Verify cursor is back at origin
    try testing.expectEqual(@as(usize, 0), term.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), term.terminal.screens.active.cursor.y);
}

test "PersistentTerminal resize" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Feed some data
    try term.feed("Hello World");

    // Resize to smaller terminal
    try term.resize(40, 10);

    // Verify new dimensions
    try testing.expectEqual(@as(u16, 40), term.terminal.cols);
    try testing.expectEqual(@as(u16, 10), term.terminal.rows);
}

test "PersistentTerminal preserves state across feeds" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Feed ANSI with color that sets state
    try term.feed("\x1b[32m"); // Set green color
    try term.feed("Green Text");
    try term.feed("\x1b[0m"); // Reset

    // Get output to verify
    var output: std.ArrayListAligned(u8, null) = .empty;
    defer output.deinit(alloc);

    try writeJsonOutput(output.writer(alloc), &term.terminal, 0, null, false, countLines(term.terminal.screens.active));

    const json = output.items;
    try testing.expect(std.mem.indexOf(u8, json, "Green Text") != null);
}

test "PersistentTerminal handles cursor movement" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Move cursor to position 5,5
    try term.feed("\x1b[6;6H"); // CSI row;col H (1-indexed)

    // Verify cursor position (0-indexed)
    try testing.expectEqual(@as(usize, 5), term.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 5), term.terminal.screens.active.cursor.y);

    // Write some text
    try term.feed("X");

    // Cursor should have moved right
    try testing.expectEqual(@as(usize, 6), term.terminal.screens.active.cursor.x);
}

test "PersistentTerminal getTotalLines is O(1)" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Initial state: 24 rows (empty terminal has screen-height rows)
    try testing.expectEqual(@as(usize, 24), term.getTotalLines());

    // Consistent across calls
    try testing.expectEqual(term.getTotalLines(), term.getTotalLines());

    // Feed data — line count grows
    try term.feed("Line 1\nLine 2\nLine 3\n");
    try testing.expect(term.getTotalLines() >= 24);

    // Resize
    try term.resize(40, 10);
    try testing.expect(term.getTotalLines() >= 10);
}

test "PersistentTerminal dirty tracking" {
    const alloc = testing.allocator;

    var term = try PersistentTerminal.init(alloc, 80, 24);
    term.initStream();
    defer term.deinit();

    // Initially dirty (generation 0, last_read_gen 0 — but no feeds yet)
    try testing.expect(!term.isDirty()); // gen == last_read_gen == 0

    // Feed data — marks dirty
    try term.feed("Hello");
    try testing.expect(term.isDirty());

    // Mark clean
    term.markClean();
    try testing.expect(!term.isDirty());

    // Feed again — dirty again
    try term.feed(" World");
    try testing.expect(term.isDirty());

    // Resize also marks dirty
    term.markClean();
    try term.resize(40, 10);
    try testing.expect(term.isDirty());

    // Reset clears dirty state
    term.reset();
    try testing.expect(!term.isDirty());
}

test "normal text does not get trailing padding" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    // Plain text without any styling
    try stream.nextSlice("Hello");

    var output: std.ArrayListAligned(u8, null) = .empty;
    defer output.deinit(alloc);

    try writeJsonOutput(output.writer(alloc), &t, 0, null, false, countLines(t.screens.active));

    const json = output.items;
    // Should have "Hello" with width 5, NOT padded to 80
    try testing.expect(std.mem.indexOf(u8, json, "\"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, ",5]") != null);
}

test "background color with EL extends to full line width" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    // Set blue background and erase to end of line
    try stream.nextSlice("\x1b[44m\x1b[K");

    var output: std.ArrayListAligned(u8, null) = .empty;
    defer output.deinit(alloc);

    try writeJsonOutput(output.writer(alloc), &t, 0, null, false, countLines(t.screens.active));

    const json = output.items;

    // Should have a span extending to 20 columns with a background color
    try testing.expect(std.mem.indexOf(u8, json, ",80]") != null);
}

// =============================================================================
// Binary output tests
// =============================================================================

test "writeBinaryOutput header fields match writeJsonOutput" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    try stream.nextSlice("Hello World");

    const total = countLines(t.screens.active);

    // Get binary output
    var bin: std.ArrayListAligned(u8, null) = .empty;
    defer bin.deinit(alloc);
    try writeBinaryOutput(&bin, alloc, &t, 0, null, false, total);

    // Parse binary header (24 bytes)
    const view = bin.items;
    try testing.expect(view.len >= 24);

    const cols = std.mem.readInt(u16, view[0..2], .little);
    const rows = std.mem.readInt(u16, view[2..4], .little);
    const cursor_x = std.mem.readInt(u16, view[4..6], .little);
    const cursor_y = std.mem.readInt(u16, view[6..8], .little);
    const visible = view[8];
    const offset_val = std.mem.readInt(u32, view[12..16], .little);
    const total_val = std.mem.readInt(u32, view[16..20], .little);
    const num_rows = std.mem.readInt(u16, view[20..22], .little);

    try testing.expectEqual(@as(u16, 80), cols);
    try testing.expectEqual(@as(u16, 24), rows);
    try testing.expectEqual(@as(u16, 11), cursor_x); // "Hello World" = 11 chars
    try testing.expectEqual(@as(u16, 0), cursor_y);
    try testing.expectEqual(@as(u8, 1), visible); // cursor visible by default
    try testing.expectEqual(@as(u32, 0), offset_val);
    try testing.expectEqual(@as(u32, @intCast(total)), total_val);
    try testing.expectEqual(@as(u16, @intCast(total)), num_rows);
}

test "writeBinaryOutput span text matches" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    try stream.nextSlice("Hello");

    const total = countLines(t.screens.active);

    var bin: std.ArrayListAligned(u8, null) = .empty;
    defer bin.deinit(alloc);
    try writeBinaryOutput(&bin, alloc, &t, 0, null, false, total);

    const view = bin.items;
    // Skip 24-byte header, first row starts with num_spans (u16)
    var pos: usize = 24;
    const num_spans = std.mem.readInt(u16, view[pos..][0..2], .little);
    pos += 2;

    // First row should have exactly 1 span with "Hello"
    try testing.expectEqual(@as(u16, 1), num_spans);

    // Read first span: width (u16) + fg(3+1) + bg(3+1) + flags(1) + pad(1) + text_len(u16) + text
    const width = std.mem.readInt(u16, view[pos..][0..2], .little);
    pos += 2;
    try testing.expectEqual(@as(u16, 5), width);

    // Skip fg(4) + bg(4) + flags(1) + pad(1) = 10 bytes
    pos += 10;

    const text_len = std.mem.readInt(u16, view[pos..][0..2], .little);
    pos += 2;
    try testing.expectEqual(@as(u16, 5), text_len);

    try testing.expectEqualStrings("Hello", view[pos .. pos + text_len]);
}

test "writeBinaryOutput preserves RGB color bytes" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    // Set fg to RGB(200, 128, 255) — tests high-byte values that would corrupt via UTF-8
    try stream.nextSlice("\x1b[38;2;200;128;255mX\x1b[0m");

    const total = countLines(t.screens.active);

    var bin: std.ArrayListAligned(u8, null) = .empty;
    defer bin.deinit(alloc);
    try writeBinaryOutput(&bin, alloc, &t, 0, null, false, total);

    const view = bin.items;
    // Header (24) + num_spans (2) = 26, then first span: width (2) + fg_r, fg_g, fg_b, fg_present
    const pos: usize = 24 + 2 + 2; // header + num_spans + width

    try testing.expectEqual(@as(u8, 200), view[pos]); // fg_r
    try testing.expectEqual(@as(u8, 128), view[pos + 1]); // fg_g
    try testing.expectEqual(@as(u8, 255), view[pos + 2]); // fg_b
    try testing.expectEqual(@as(u8, 1), view[pos + 3]); // fg_present
}

test "writeBinaryOutput with offset and limit" {
    const alloc = testing.allocator;

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    t.modes.set(.linefeed, true);

    var stream = t.vtStream();
    defer stream.deinit();

    try stream.nextSlice("Line0\nLine1\nLine2\nLine3\n");

    const total = countLines(t.screens.active);

    // Request rows 1..3 (offset=1, limit=2)
    var bin: std.ArrayListAligned(u8, null) = .empty;
    defer bin.deinit(alloc);
    try writeBinaryOutput(&bin, alloc, &t, 1, 2, false, total);

    const view = bin.items;
    const offset_val = std.mem.readInt(u32, view[12..16], .little);
    const num_rows = std.mem.readInt(u16, view[20..22], .little);

    try testing.expectEqual(@as(u32, 1), offset_val);
    try testing.expectEqual(@as(u16, 2), num_rows);
}
