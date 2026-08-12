# Oliver

A small, freestanding markup parsing and rendering library in Zig.

```text
Markdown ─┐
          ├─> normalized typed document ─> deterministic HTML
Textile ──┘
```

Oliver is **markup infrastructure**: it parses a byte slice, produces a typed
document, and renders it deterministically. Filesystem, templates, site
graphs, plugins, publication — none of that lives here; consumers build it
around Oliver.

Oliver is a **clean-room implementation** of the *behavior* specified by the
CommonMark specification and the published Textile syntax documentation. It
does not study or imitate existing parser implementations. See
[docs/CLEANROOM.md](docs/CLEANROOM.md).

## Status

Implemented so far: paragraphs, headings, backslash escapes, hard and soft
line breaks, emphasis and strong emphasis (full CommonMark §6.2 rule set,
including the mod-3 rule and `openers_bottom` pruning), code spans (§6.6,
run-length matching with delimiter opacity), inline links (§6.6, bracket
<<<<<<< HEAD
opacity, destination/title syntax, href percent-encoding), inline images
(§6.7, `![alt](src "title")` with alt flattening and `<img>` rendering),
reference links (§4.7 link reference definitions collected in the block
pass; full, collapsed, and shortcut forms resolved against a Unicode
case-folded label map), plain inline text, a shared document model, a
deterministic HTML renderer, Markdown (ATX) and Textile (`hN.`) frontends,
structured diagnostics, and a provisional CLI.
>>>>>>> origin/main
See [docs/SESSION-1-REPORT.md](docs/SESSION-1-REPORT.md) for the founding
handoff and [docs/FEATURE-MATRIX.md](docs/FEATURE-MATRIX.md) for what is
implemented, planned, and deferred. The emphasis/strong algorithm contract
is [docs/INLINE-PARSING.md](docs/INLINE-PARSING.md), derived from the
CommonMark spec's flanking rules (§6.2); the image algorithm contract is
[docs/IMAGES-PARSING.md](docs/IMAGES-PARSING.md). Code spans, links, and
images ride the same scan → match → emit seam.

## Building and testing

Requires Zig 0.16.0.

```bash
zig build test    # run all tests (59 tests)
zig build         # build the static library and CLI into zig-out/
```

## Library use

```zig
const oliver = @import("oliver");

const result = try oliver.parse(allocator, source_bytes, .markdown, .{});
defer result.deinit();

var aw = std.Io.Writer.Allocating.init(allocator);
defer aw.deinit();
try oliver.html.render(allocator, &aw.writer, &result.document, .{});
```

The caller supplies the allocator; the document owns an arena and borrows the
input bytes; rendering streams to any writer. No global state, no hidden
caches, deterministic output.

## CLI (provisional)

```bash
oliver render --from markdown < document.md > document.html
oliver render --from textile  < document.textile
```

A thin stdin/stdout adapter — all semantics live in the library.

## Repository layout

```text
build.zig / build.zig.zon   Zig 0.16 build (lib, CLI, tests)
src/                        the library + provisional CLI
tests/                      fixture-driven tests (fixtures live here too)
docs/                       clean-room rules, architecture, feature matrix,
                            document model, test conventions, session report
```

## Design values

Correctness · deterministic behavior · explicit ownership · small
understandable data structures · bounded memory · precise source locations ·
clean parsing/rendering separation · fuzzability · embeddability ·
performance without premature optimization. The core has no host
dependencies: no filesystem, environment, clock, network, or threads — ready
for later WebAssembly embedding.
