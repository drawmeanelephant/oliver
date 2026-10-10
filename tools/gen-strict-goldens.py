#!/usr/bin/env python3
"""Regenerate the HTML 4.01 Strict golden wall (tests/html4_strict_goldens.zig).

Runs the built CLI (zig-out/bin/oliver) over every fixture indexed in
tests/fixtures_test.zig, under the same option family its table uses, and
classifies each fixture's `--to html4-strict` outcome:

  agree     — strict bytes == committed `.html` golden (no extra file)
  divergent — strict bytes differ; a committed `.strict.html` golden pins them
  fail      — the renderer fails closed with a documented Strict error

Then it rewrites the generated test tables and syncs the `.strict.html`
files (writing new divergent goldens, removing stale ones).

Idempotent: run after `zig build` whenever fixtures or serialization deltas
change. The classifier hard-fails on any error it cannot name, so an
unknown outcome never lands silently in the wrong class.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "zig-out" / "bin" / "oliver"
FIXTURES_TEST = ROOT / "tests" / "fixtures_fixtures_test.zig"  # unused; real path below
FIXTURES_TEST = ROOT / "tests" / "fixtures_test.zig"
OUT_TEST = ROOT / "tests" / "html4_strict_goldens.zig"

EXT_FLAGS = [
    "--footnotes", "--definition-lists", "--heading-attributes",
    "--strikethrough", "--wikilinks", "--callouts", "--smartypants",
    "--task-lists", "--heading-ids",
]

EXT_ZIG = """    return .{ .markdown = .{
        .footnotes = true,
        .definition_lists = true,
        .heading_attributes = true,
        .strikethrough = true,
        .wikilinks = true,
        .callouts = true,
        .smartypants = true,
        .task_lists = true,
    } };"""


def table_entries(table: str):
    src = FIXTURES_TEST.read_text()
    m = re.search(rf"const {table} = \[_\]\w+Fixture\{{(.*?)\n\}};", src, re.S)
    if not m:
        sys.exit(f"fixtures table not found: {table}")
    out = []
    for e in re.finditer(r"\.\{\s*\.name = \"([^\"]+)\"(.*?)\},", m.group(1), re.S):
        mm = re.search(r"\.mode = \.(\w+)", e.group(2))
        out.append((e.group(1), mm.group(1) if mm else None))
    return out


def corpus():
    """(dir, family, name, cli_flags, mode) for every indexed fixture."""
    fams = []
    for n, _ in table_entries("markdown_fixtures"):
        fams.append(("markdown", "plain", n, [], None))
    for n, _ in table_entries("markdown_ext_fixtures"):
        fams.append(("markdown", "ext", n, EXT_FLAGS, None))
    for n, mode in table_entries("markdown_fm_fixtures"):
        fams.append(("markdown", "fm", n, ["--frontmatter", mode], mode))
    for n, _ in table_entries("textile_fixtures"):
        fams.append(("textile", "plain", n, [], None))
    for n, _ in table_entries("textile_fm_fixtures"):
        fams.append(("textile", "fm", n, ["--frontmatter", "yaml"], "yaml"))
    for n, _ in table_entries("cooklang_fixtures"):
        fams.append(("cooklang", "plain", n, [], None))
    for n, _ in table_entries("cooklang_fm_fixtures"):
        fams.append(("cooklang", "fm", n, ["--frontmatter", "yaml"], "yaml"))
    return fams


def run(dialect, flags, profile, data):
    cmd = [str(BIN), "render", "--from", dialect, "--to", profile, *flags]
    return subprocess.run(cmd, input=data, capture_output=True)


ERROR_KINDS = [
    ("RawHtmlNotHtml4Strict", "rejects verbatim HTML"),
    ("OrderedListStartNotHtml4Strict", "starting other than 1"),
    ("InvalidHtml4StrictId", "HTML 4.01-compatible id"),
    ("DuplicateHtml4StrictId", "unique id"),
    ("EmptyTableNotHtml4Strict", "table row"),
]


def classify():
    agree, divergent, fail = [], [], []
    for d, family, name, flags, mode in corpus():
        inp = (ROOT / "tests/fixtures" / d / f"{name}.{ {'markdown': 'md', 'textile': 'textile', 'cooklang': 'cook'}[d] }").read_bytes()
        html = run(d, flags, "html", inp)
        golden = (ROOT / "tests/fixtures" / d / f"{name}.html").read_bytes()
        if html.returncode != 0 or html.stdout != golden:
            sys.exit(f"HTML golden mismatch or CLI failure: {d}/{name} (rc={html.returncode})")
        strict = run(d, flags, "html4-strict", inp)
        entry = {"dir": d, "family": family, "name": name, "mode": mode}
        if strict.returncode != 0:
            err = strict.stderr.decode(errors="replace")
            for kind, needle in ERROR_KINDS:
                if needle in err:
                    entry["err"] = kind
                    fail.append(entry)
                    break
            else:
                sys.exit(f"unclassified strict error {d}/{name}: {err!r}")
        elif strict.stdout == golden:
            agree.append(entry)
        else:
            divergent.append(entry)
    return agree, divergent, fail


def sync_goldens(divergent):
    keep = set()
    for e in divergent:
        d, name = e["dir"], e["name"]
        ext = {"markdown": "md", "textile": "textile", "cooklang": "cook"}[d]
        inp = (ROOT / "tests/fixtures" / d / f"{name}.{ext}").read_bytes()
        flags = EXT_FLAGS if e["family"] == "ext" else (
            ["--frontmatter", e["mode"]] if e["family"] == "fm" else [])
        out = run(d, flags, "html4-strict", inp).stdout
        path = ROOT / "tests/fixtures" / d / f"{name}.strict.html"
        path.write_bytes(out)
        keep.add(path)
    stale = [p for p in (ROOT / "tests/fixtures").rglob("*.strict.html") if p not in keep]
    for p in stale:
        p.unlink()
    return len(keep), len(stale)


def emit(entries, kind):
    lines = []
    for e in entries:
        d, family, name, mode = e["dir"], e["family"], e["name"], e["mode"]
        ext = {"markdown": "md", "textile": "textile", "cooklang": "cook"}[d]
        fam = f".family = .{family}"
        if mode:
            fam += f", .mode = .{mode}"
        fields = [
            f'.name = "{name}"',
            f'.dir = "{d}"',
            fam,
            f'.input = @embedFile("fixtures/{d}/{name}.{ext}")',
            f'.html = @embedFile("fixtures/{d}/{name}.html")',
        ]
        if kind == "divergent":
            fields.append(f'.strict = @embedFile("fixtures/{d}/{name}.strict.html")')
        if kind == "fail":
            fields.append(f'.err = error.{e["err"]}')
        lines.append("    .{ " + ", ".join(fields) + " },")
    return "\n".join(lines)


TEMPLATE = '''//! HTML 4.01 Strict profile: golden-file wall over the committed fixture
//! corpus (#130). GENERATED by tools/gen-strict-goldens.py — do not edit
//! the tables by hand; re-run the generator after adding fixtures or
//! changing a serialization delta.
//!
//! Every fixture indexed in tests/fixtures_test.zig runs through the strict
//! profile under the same option family its table there uses, and lands in
//! exactly one asserted class:
//!
//!   agree     — strict output is byte-identical to the committed `.html`
//!               golden. No second file is committed: the `.html` wall is
//!               the golden for both profiles.
//!   divergent — the profile owns a serialization delta (void-tag slashes,
//!               tbody wrapping, Cooklang HTML5-to-div mappings, footnote
//!               and task-list attribute forms). A committed
//!               `.strict.html` golden pins those exact bytes.
//!   fail      — the construct cannot be expressed in Strict, so the
//!               renderer fails closed with the documented error: verbatim
//!               HTML (`RawHtmlNotHtml4Strict`) and ordered lists starting
//!               other than 1 (`OrderedListStartNotHtml4Strict`).
//!
//! The wall doubles as the "HTML output unchanged" guard (#130): each
//! fixture's default-profile render is re-compared to its committed
//! `.html` before the strict run, so a profile change that perturbs HTML
//! bytes fails here first.

const std = @import("std");
const oliver = @import("oliver");
const a = std.testing.allocator;

/// Which option family the fixture's fixtures_test.zig table uses.
const Class = enum { plain, ext, fm };

const Agree = struct {
    name: []const u8,
    dir: []const u8,
    family: Class,
    mode: ?oliver.frontmatter.Option = null,
    input: []const u8,
    html: []const u8,
};

const Divergent = struct {
    name: []const u8,
    dir: []const u8,
    family: Class,
    mode: ?oliver.frontmatter.Option = null,
    input: []const u8,
    html: []const u8,
    strict: []const u8,
};

const Fail = struct {
    name: []const u8,
    dir: []const u8,
    family: Class,
    mode: ?oliver.frontmatter.Option = null,
    err: anyerror,
    input: []const u8,
    html: []const u8,
};

fn extParseOptions() oliver.ParseOptions {
@@EXT_PARSE@@
}

fn dialectOf(dir: []const u8) oliver.Dialect {
    // Only called for the document dialects; cooklang fixtures take the
    // dedicated `oliver.cooklang` branch in `render` below (there is no
    // `.cooklang` Dialect member).
    if (std.mem.eql(u8, dir, "textile")) return .textile;
    return .markdown;
}

/// Render `input` under `profile` with the option family the entry demands.
fn render(input: []const u8, dir: []const u8, family: Class, mode: ?oliver.frontmatter.Option, profile: oliver.OutputProfile) !std.ArrayList(u8) {
    if (std.mem.eql(u8, dir, "cooklang")) {
        var parse_opts = oliver.cooklang.ParseOptions{};
        if (mode) |fm| parse_opts.frontmatter = fm;
        var result = try oliver.cooklang.parse(a, input, parse_opts);
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(a);
        defer aw.deinit();
        try oliver.cooklang_html.render(a, &aw.writer, &result.recipe, .{ .profile = profile });
        return aw.toArrayList();
    }
    var parse_opts: oliver.ParseOptions = .{};
    if (family == .ext) parse_opts = extParseOptions();
    if (mode) |fm| parse_opts = .{ .frontmatter = fm };
    var result = try oliver.parse(a, input, dialectOf(dir), parse_opts);
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    var opts: oliver.html.RenderOptions = .{ .profile = profile };
    if (family == .ext) opts = .{ .profile = profile, .heading_ids = true, .footnotes = true };
    try oliver.html.render(a, &aw.writer, &result.document, opts);
    return aw.toArrayList();
}

// ---------------------------------------------------------------------------
// Generated classes (@@COUNTS@@).
// ---------------------------------------------------------------------------

const agree_cases = [_]Agree{
@@AGREE@@
};

const divergent_cases = [_]Divergent{
@@DIVERGENT@@
};

const fail_cases = [_]Fail{
@@FAIL@@
};

test "html4 strict wall: class counts" {
    // The visible record of the generated classification. tools/gen-strict-
    // goldens.py owns these numbers; a fixture that changes class moves one
    // count to another (the totals must keep summing to the corpus size).
    try std.testing.expectEqual(@as(usize, @@N_AGREE@@), agree_cases.len);
    try std.testing.expectEqual(@as(usize, @@N_DIVERGENT@@), divergent_cases.len);
    try std.testing.expectEqual(@as(usize, @@N_FAIL@@), fail_cases.len);
}

test "html4 strict wall: HTML goldens unchanged; strict agrees on clean content" {
    // The committed `.html` golden is the reference for BOTH profiles: the
    // default render must still match it byte-for-byte (the strict profile
    // must not perturb HTML output), and the strict render of an agree
    // fixture matches those same bytes.
    for (agree_cases) |c| {
        var html = try render(c.input, c.dir, c.family, c.mode, .html);
        defer html.deinit(a);
        try expectBytes(c.name, "html", c.html, html.items);
        var strict = try render(c.input, c.dir, c.family, c.mode, .html4_strict);
        defer strict.deinit(a);
        try expectBytes(c.name, "html4-strict", c.html, strict.items);
    }
}

test "html4 strict wall: divergent goldens pin the profile deltas" {
    for (divergent_cases) |c| {
        var html = try render(c.input, c.dir, c.family, c.mode, .html);
        defer html.deinit(a);
        try expectBytes(c.name, "html", c.html, html.items);
        var strict = try render(c.input, c.dir, c.family, c.mode, .html4_strict);
        defer strict.deinit(a);
        try expectBytes(c.name, "html4-strict", c.strict, strict.items);
        if (std.mem.eql(u8, c.html, c.strict)) {
            std.debug.print("fixture [{s}] listed divergent but bytes match; regenerate (agree class)\\n", .{c.name});
            return error.Misclassified;
        }
    }
}

test "html4 strict wall: unsupported constructs fail closed" {
    for (fail_cases) |c| {
        var html = try render(c.input, c.dir, c.family, c.mode, .html);
        defer html.deinit(a);
        try expectBytes(c.name, "html", c.html, html.items);
        if (render(c.input, c.dir, c.family, c.mode, .html4_strict)) |out| {
            var rendered = out;
            defer rendered.deinit(a);
            std.debug.print("fixture [{s}] listed fail but rendered; regenerate\\n", .{c.name});
            return error.Misclassified;
        } else |err| {
            try std.testing.expectEqual(c.err, err);
        }
    }
}

fn expectBytes(name: []const u8, profile: []const u8, expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print(
            "fixture [{s}] mismatch under {s}\\n--- expected ({d} bytes) ---\\n{s}\\n--- actual ({d} bytes) ---\\n{s}\\n",
            .{ name, profile, expected.len, expected, actual.len, actual },
        );
        return error.FixtureMismatch;
    }
}
'''


def main():
    if not BIN.exists():
        sys.exit("zig-out/bin/oliver missing; run `zig build` first")
    agree, divergent, fail = classify()
    kept, removed = sync_goldens(divergent)
    counts = f"agree={len(agree)} divergent={len(divergent)} fail={len(fail)}"
    text = TEMPLATE
    for token, value in [
        ("@@EXT_PARSE@@", EXT_ZIG),
        ("@@COUNTS@@", counts),
        ("@@AGREE@@", emit(agree, "agree")),
        ("@@DIVERGENT@@", emit(divergent, "divergent")),
        ("@@FAIL@@", emit(fail, "fail")),
        ("@@N_AGREE@@", str(len(agree))),
        ("@@N_DIVERGENT@@", str(len(divergent))),
        ("@@N_FAIL@@", str(len(fail))),
    ]:
        assert token in text, token
        text = text.replace(token, value)
    OUT_TEST.write_text(text)
    print(f"agree={len(agree)} divergent={len(divergent)} fail={len(fail)} | goldens kept={kept} removed={removed}")
    print(f"wrote {OUT_TEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
