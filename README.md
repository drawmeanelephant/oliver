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
info strings and container composition), indented code blocks (§4.4,
chunks separated by blank lines, trailing blanks dropped, list/quote
composition), tab-stop indentation (§2.1, four-column tab stops for block
structure with literal tab bytes preserved in content), backslash escapes,
hard and soft line breaks, emphasis and strong emphasis (full CommonMark
§6.2 rule set, including the mod-3 rule and `openers_bottom` pruning), code
spans (§6.1, run-length matching with delimiter opacity), inline links
(§6.3, bracket opacity, destination/title syntax, href percent-encoding),
inline images (§6.4, `![alt](src "title")` with alt flattening and `<img>`
rendering), reference links and reference-style images (§4.7 link reference
definitions collected in the block pass; full, collapsed, and shortcut
forms resolved against a Unicode case-folded label map — for `[text]`
links and `![alt]` images alike), block quotes (§5.1) and list items/lists
(§5.2/§5.3) on the container-block stack with nesting, content indentation,
same-type merging, tight/loose tracking, and deterministic `<ul>`/`<ol>`
rendering, autolinks (§6.5, URI and email forms with `mailto:` hrefs,
escapes inert, linear recognition), raw HTML (§6.6,
tags/comments/instructions/declarations/CDATA rendered verbatim), HTML
blocks (§4.6, all seven types: script/pre/style/textarea element blocks,
comments, processing instructions, declarations, and CDATA ending at
their matching terminator, plus block-tag lines and whole-line tags
ending at a blank line — all verbatim), GFM pipe tables (the §4.10
extension in the Markdown frontend: header + delimiter rows, alignment
colons, escaped `\|`, inline-parsed cells, `<table><thead><tbody>`
output — docs/TABLES.md), entity and numeric character
references (§2.5,
named via the WHATWG entities table, decoded in text, link
destinations/titles, info strings, and autolinks but never in code
spans/blocks or as structural syntax), plain
inline text, a shared document model, a deterministic HTML renderer,
Markdown (ATX) and Textile
frontends (`hN.` headings, `p.`/`bq.`, `*`/`#` lists, `@code@`, the
phrase-modifier family `_x_`/`*x*`/`__x__`/`**x**`/`-x-`/`+x+`/`^x^`/`~x~`/`%x%`/
`++x++`/`--x--`,
`"text":url` links, `[alias]url` link aliases with `"text":alias`
references, `!url!` images, `|a|b|` tables with `|_. header|`
cells, `table<mods>.` signatures, colspan/rowspan, and header-alignment
propagation, block attributes (`p(...).`/`hN{...}.`/`bq>.` — style,
class/id, lang, alignment, padding — see docs/TEXTILE-PARITY.md),
`bc.`/`pre.` code blocks (escaped `<pre><code>` vs verbatim `<pre>`),
extended `bq..`/`bc..`/`pre..` signatures that stay active across
blank lines, footnotes (`[N]` references + `fnN.` blocks with
`class="footnote"` links), `bq.:URL` block-quote citations
(rendered as the blockquote's `cite` attribute), the character
replacements (curly quotes, em/en dashes, ellipsis, `(c)`/`(r)`/`(tm)`,
fractions, degree, plus/minus, dimension sign, and the `{...}`
character-macro table — cent, pound, yen, accented letters, bullet,
smileys), `==` escaping
(a lone `==` line passes raw HTML through unformatted; inline
`==...==` suspends all formatting and replacements), `|mods|.`
line attributes (the pipe-delimited form of the block-attribute set,
converging byte-identically with `p<mods>.`), image modifiers
(alignment, sizing `10x20`/`10w 20h`/`20%`, and style/class/padding
on `!url!` images), and span phrase attributes
(`%{style}(class#id)[lang]x%` on `%x%` spans),
structured diagnostics, and a provisional CLI.
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
The Textile fixture audit — inventory, gaps vs. Textile 2 semantics, and
chosen behaviors for phrase modifiers, links, images, lists, tables, link
aliases, block attributes, code blocks, extended blocks, footnotes,
block-quote citations, character replacements, `==` escaping, line
attributes, and image modifiers — is
[docs/TEXTILE-PARITY.md](docs/TEXTILE-PARITY.md).
The GFM tables extension contract is
[docs/TABLES.md](docs/TABLES.md).
Code spans, links, images, autolinks, and raw HTML ride the same
scan → match → emit seam.

## Building and testing

Requires Zig 0.16.0. `zig build test` runs the unit, fixture, and
conformance-harness suites; `zig build spec-conformance -- spec.txt` scores
Oliver against every normative example in the exact official CommonMark
0.31.2 corpus (byte count, example count, and SHA-256 are verified first)
and prints a per-section scorecard. Every example is classified in a
reviewed manifest (docs/COMMONMARK-EXPECTATIONS.md) as supported,
not-yet, or a named divergence; `--gate` fails on any supported regression,
unexpected pass, or changed divergence, so the full corpus is a regression
wall (see docs/TESTS.md for how to fetch the spec).

### Current scorecard: 652/652 — full CommonMark 0.31.2 conformance

Every one of the 652 normative examples passes byte-for-byte (0 not-yet,
0 named divergences). Per-section counts are derived from the harness:

```bash
zig build spec-conformance -- spec.txt
```

| CommonMark 0.31.2 section | score |
| --- | --- |
| Tabs | 11/11 |
| Backslash escapes | 13/13 |
| Entity and numeric character references | 17/17 |
| Precedence | 1/1 |
| Thematic breaks | 19/19 |
| ATX headings | 18/18 |
| Setext headings | 27/27 |
| Indented code blocks | 12/12 |
| Fenced code blocks | 29/29 |
| HTML blocks | 44/44 |
| Link reference definitions | 27/27 |
| Paragraphs | 8/8 |
| Blank lines | 1/1 |
| Block quotes | 25/25 |
| List items | 48/48 |
| Lists | 26/26 |
| Inlines | 1/1 |
| Code spans | 22/22 |
| Emphasis and strong emphasis | 132/132 |
| Links | 90/90 |
| Images | 22/22 |
| Autolinks | 19/19 |
| Raw HTML | 20/20 |
| Hard line breaks | 15/15 |
| Soft line breaks | 2/2 |
| Textual content | 3/3 |
| **Total** | **652/652** |

```bash
zig build test    # run all tests (183 tests)
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
.github/                    CI gate (workflow) and the draft main-branch
                            protection ruleset (BRANCH-PROTECTION.md)
```

## Design values

Correctness · deterministic behavior · explicit ownership · small
understandable data structures · bounded memory · precise source locations ·
clean parsing/rendering separation · fuzzability · embeddability ·
performance without premature optimization. The core has no host
dependencies: no filesystem, environment, clock, network, or threads — ready
for later WebAssembly embedding.
