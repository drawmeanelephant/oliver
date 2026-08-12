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

Implemented so far: paragraphs, ATX and Setext headings, thematic breaks,
fenced code blocks (§4.5, backtick/tilde fences, literal normalized content,
info strings and container composition), backslash escapes, hard and soft
line breaks, emphasis and strong emphasis (full CommonMark §6.2 rule set,
including the mod-3 rule and `openers_bottom` pruning), code spans (§6.1,
run-length matching with delimiter opacity), inline links (§6.3, bracket
opacity, destination/title syntax, href percent-encoding), inline images
(§6.4, `![alt](src "title")` with alt flattening and `<img>` rendering),
reference links and reference-style images (§4.7 link reference
definitions collected in the block pass; full, collapsed, and shortcut
forms resolved against a Unicode case-folded label map — for `[text]`
links and `![alt]` images alike), block quotes (§5.1) and list items/lists
(§5.2/§5.3) on the container-block stack with nesting, content indentation,
same-type merging, tight/loose tracking, and deterministic `<ul>`/`<ol>`
rendering, autolinks (§6.5, URI and email forms with `mailto:` hrefs,
escapes inert, linear recognition), raw HTML (§6.6,
tags/comments/instructions/declarations/CDATA rendered verbatim), plain
inline text, a shared document model, a deterministic HTML renderer,
Markdown (ATX) and Textile (`hN.`)
frontends, structured diagnostics, and a provisional CLI.
See [docs/SESSION-1-REPORT.md](docs/SESSION-1-REPORT.md) for the founding
handoff and [docs/FEATURE-MATRIX.md](docs/FEATURE-MATRIX.md) for what is
implemented, planned, and deferred. The emphasis/strong algorithm contract
is [docs/INLINE-PARSING.md](docs/INLINE-PARSING.md), derived from the
CommonMark spec's flanking rules (§6.2); the image algorithm contract is
[docs/IMAGES-PARSING.md](docs/IMAGES-PARSING.md); the reference-style
image contract is [docs/REFERENCE-IMAGES.md](docs/REFERENCE-IMAGES.md);
the autolink contract is [docs/AUTOLINKS.md](docs/AUTOLINKS.md); the raw HTML
contract is [docs/RAW-HTML.md](docs/RAW-HTML.md).
The thematic-break/Setext precedence contract is
[docs/LEAF-BLOCKS.md](docs/LEAF-BLOCKS.md).
The fenced-code open-leaf/model/rendering contract is
[docs/FENCED-CODE.md](docs/FENCED-CODE.md).
Code spans, links, images, autolinks, and raw HTML ride the same
scan → match → emit seam.

## Building and testing

Requires Zig 0.16.0. `zig build test` runs the unit and fixture suites;
`zig build spec-conformance -- spec.txt` scores Oliver against every
normative example in a CommonMark spec (see docs/TESTS.md for the current
546/652 CommonMark 0.31.2 scorecard and how to fetch the spec).

```bash
zig build test    # run all tests (113 tests)
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
