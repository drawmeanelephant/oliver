# Oliver

A small, freestanding markup parsing and rendering library in Zig.

```text
Markdown ──> normalized typed document ──> deterministic HTML / XHTML
Textile ───> normalized typed document ──> deterministic HTML / XHTML
Cooklang ──> typed Recipe (its own model) ─> deterministic HTML / XHTML policy
```

Oliver parses a byte slice into a typed document (or, for Cooklang, a typed
Recipe) and renders it deterministically. No filesystem, templates, site
graphs, plugins, or publication — consumers build that around Oliver. It is a
clean-room implementation of the behavior specified by CommonMark, published
Textile syntax documentation, and the Cooklang specification and canonical
corpus ([docs/CLEANROOM.md](docs/CLEANROOM.md)).

The name honors Oliver, the Weimaraner of Dean Allen, who created Textile
and photographed his dog daily at
[textism.com](http://textism.com/oliver/daily/about.html).

## Status

- **Markdown**: full CommonMark 0.31.2 conformance — 652/652 normative corpus
  examples pass byte-for-byte. GFM tables built in; footnotes, definition
  lists, heading attributes, strikethrough, task lists, wikilinks, callouts,
  smart typography, and front matter available opt-in.
- **Textile**: headings, lists, tables, phrase modifiers, images, attributes,
  footnotes, character replacements, `notextile.` passthrough.
- **Cooklang**: typed Recipe model passing the official canonical corpus
  60/60, plus canonical serialization, exact-rational scaling, and menu views.

Details: [docs/CAPABILITIES.md](docs/CAPABILITIES.md) and
[docs/FEATURE-MATRIX.md](docs/FEATURE-MATRIX.md).

## Building and testing

Requires Zig 0.16.0.

```bash
zig build test                                  # all test suites
zig build                                       # library + CLI into zig-out/
zig build spec-conformance -- spec.txt          # CommonMark scorecard
zig build cooklang-conformance -- canonical.yaml  # Cooklang corpus
```

The spec harness verifies the official corpus by SHA-256 and classifies every
example in a reviewed manifest; `--gate` turns the full corpus into a
regression wall ([docs/TESTS.md](docs/TESTS.md)).

## Library use

The caller supplies the allocator; documents own an arena and borrow the input;
rendering streams to any writer. No global state, deterministic output.

```zig
const oliver = @import("oliver");

const result = try oliver.parse(allocator, source_bytes, .markdown, .{});
defer result.deinit();

var aw = std.Io.Writer.Allocating.init(allocator);
defer aw.deinit();
try oliver.html.render(allocator, &aw.writer, &result.document, .{});        // HTML
try oliver.html.render(allocator, &aw.writer, &result.document, .{ .profile = .xhtml }); // XHTML
```

Cooklang uses its own entry points (`oliver.cooklang.parse`,
`cooklang_html.render`, `cooklang_serialize.serialize`, `cooklang_scale`,
`cooklang_menu`) — see [docs/COOKLANG.md](docs/COOKLANG.md).

A stable C ABI (`include/oliver.h`, explicit error codes, caller frees via
`oliver_free`) supports embedding from any FFI language:
[docs/C-ABI.md](docs/C-ABI.md). A self-checking consumer runs via
`zig build c-example-run`.

## CLI

A thin stdin/stdout adapter — all semantics live in the library.

```bash
oliver render --from markdown < document.md
oliver render --from textile  < document.textile
oliver render --from cooklang < recipe.cook
oliver render --from markdown --wikilinks --callouts --smartypants < document.md
oliver scale --from cooklang --servings 4 < recipe.cook
oliver serialize --from cooklang < recipe.cook   # canonical .cook (--json for typed model)
```

`--to xhtml` produces XML-compatible fragments; run `oliver render --help`
for the full flag set.

## Prebuilt binaries

A rolling `builds` release carries ReleaseSafe, statically linked CLI binaries
for linux/macOS (x86_64, aarch64) and Windows (x86_64), rebuilt and
smoke-tested natively on every push to `main`:

```text
https://github.com/drawmeanelephant/oliver/releases/download/builds/oliver-<os>-<arch>
```

`sha256sums.txt` verifies assets; each binary embeds its source commit
(`oliver --version` prints it) so pinned downloads can be asserted.

## Documentation

Full documentation lives in [docs/index.md](docs/index.md) — capabilities,
architecture, document model, parsing contracts per feature, test
conventions, and the work ledger. It publishes to GitHub Pages
([docs/github-pages.md](docs/github-pages.md)).
