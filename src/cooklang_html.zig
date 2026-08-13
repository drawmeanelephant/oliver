//! Cooklang HTML rendering policy.
//!
//! This is Oliver's own deterministic HTML vocabulary for generic
//! publication — **not** a "Cooklang-conformant" output: the Cooklang
//! specification defines recipe semantics, not an HTML vocabulary, and no
//! conformance claim is made (docs/COOKLANG.md §C).
//!
//! The policy preserves the Recipe's semantic distinctions with semantic
//! elements, classes, and data attributes:
//!
//!     <article class="recipe">
//!       <section><h2>Dough</h2>…</section>     sections
//!       <ol class="steps"><li>…</li></ol>      steps; <br> for breaks
//!       <aside class="note">…</aside>          notes
//!       <span class="ingredient" data-quantity="200" data-units="g">flour</span>
//!       <span class="cookware" data-quantity="2">pot</span>
//!       <span class="timer" data-quantity="25" data-units="minutes">25 minutes</span>
//!       <span class="recipe-ref" data-ref="./sauces/Hollandaise">./sauces/Hollandaise</span>
//!
//! Text and attribute values are HTML-escaped (`&`, `<`, `>`, `"`).
//! Quantities render as their trimmed source text; `data-quantity` is
//! emitted only when the token carried an explicit non-empty quantity, and
//! `data-units` only when units are present. Preparations render as a
//! visible `<span class="preparation">` inside their ingredient. Recipe
//! references stay unresolvable data (`data-ref`) — Oliver never resolves
//! paths. YAML front matter is not rendered here; metadata presentation is
//! a consumer concern.

const std = @import("std");
const cooklang = @import("cooklang.zig");

pub const RenderOptions = struct {};

pub fn render(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, options: RenderOptions) !void {
    _ = gpa;
    _ = options;
    try writer.writeAll("<article class=\"recipe\">\n");
    try renderBlocks(writer, recipe.blocks);
    try writer.writeAll("</article>\n");
}

/// Renders a run of blocks, opening one `<ol class="steps">` for each
/// contiguous run of steps (notes and sections interrupt the run).
fn renderBlocks(writer: anytype, blocks: []const cooklang.Block) !void {
    var ol_open = false;
    for (blocks) |block| {
        switch (block) {
            .step => |step| {
                if (!ol_open) {
                    try writer.writeAll("<ol class=\"steps\">\n");
                    ol_open = true;
                }
                try writer.writeAll("<li>");
                // Text parts carry their own source spacing, so parts
                // render adjacent without a synthetic separator.
                for (step.parts) |part| try renderPart(writer, part);
                try writer.writeAll("</li>\n");
            },
            .note => |note| {
                if (ol_open) {
                    try writer.writeAll("</ol>\n");
                    ol_open = false;
                }
                try writer.writeAll("<aside class=\"note\">");
                try escapeInto(writer, note.text, false);
                try writer.writeAll("</aside>\n");
            },
            .section => |section| {
                if (ol_open) {
                    try writer.writeAll("</ol>\n");
                    ol_open = false;
                }
                try writer.writeAll("<section>\n<h2>");
                try escapeInto(writer, section.name, false);
                try writer.writeAll("</h2>\n");
                try renderBlocks(writer, section.blocks);
                try writer.writeAll("</section>\n");
            },
        }
    }
    if (ol_open) try writer.writeAll("</ol>\n");
}

fn renderPart(writer: anytype, part: cooklang.Part) !void {
    switch (part) {
        .text => |t| try escapeInto(writer, t.text, false),
        .line_break => try writer.writeAll("<br>"),
        .ingredient => |ig| {
            if (ig.is_recipe_reference) {
                try writer.writeAll("<span class=\"recipe-ref\" data-ref=\"");
                try escapeInto(writer, ig.name, true);
                try writer.writeAll("\">");
                try escapeInto(writer, ig.name, false);
                try writer.writeAll("</span>");
                return;
            }
            try writer.writeAll("<span class=\"ingredient\"");
            try writeQuantity(writer, ig.quantity, ig.units);
            try writer.writeAll(">");
            try escapeInto(writer, ig.name, false);
            if (ig.preparation) |prep| {
                try writer.writeAll(" <span class=\"preparation\">");
                try escapeInto(writer, prep, false);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("</span>");
        },
        .cookware => |cw| {
            try writer.writeAll("<span class=\"cookware\"");
            try writeQuantity(writer, cw.quantity, null);
            try writer.writeAll(">");
            try escapeInto(writer, cw.name, false);
            try writer.writeAll("</span>");
        },
        .timer => |tm| {
            try writer.writeAll("<span class=\"timer\"");
            try writeQuantity(writer, tm.quantity, tm.units);
            try writer.writeAll(">");
            if (tm.name.len > 0) {
                try escapeInto(writer, tm.name, false);
            } else {
                // Unnamed timer: show the quantity and units as text.
                if (tm.quantity) |q| {
                    if (q.len > 0) {
                        try escapeInto(writer, q, false);
                        try writer.writeAll(" ");
                    }
                }
                if (tm.units) |u| {
                    if (u.len > 0) try escapeInto(writer, u, false);
                }
            }
            try writer.writeAll("</span>");
        },
    }
}

/// Writes the `data-quantity`/`data-units` attributes for a token,
/// omitting empty values (no braces, or empty braces).
fn writeQuantity(writer: anytype, quantity: ?[]const u8, units: ?[]const u8) !void {
    if (quantity) |q| {
        if (q.len > 0) {
            try writer.writeAll(" data-quantity=\"");
            try escapeInto(writer, q, true);
            try writer.writeAll("\"");
        }
    }
    if (units) |u| {
        if (u.len > 0) {
            try writer.writeAll(" data-units=\"");
            try escapeInto(writer, u, true);
            try writer.writeAll("\"");
        }
    }
}

/// Escapes `&`, `<`, `>` (and `"` for attribute contexts) into `writer`.
fn escapeInto(writer: anytype, text: []const u8, attribute: bool) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const rep: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => if (attribute) "&quot;" else null,
            else => null,
        };
        if (rep) |r| {
            try writer.writeAll(text[start..i]);
            try writer.writeAll(r);
            start = i + 1;
        }
    }
    try writer.writeAll(text[start..]);
}
