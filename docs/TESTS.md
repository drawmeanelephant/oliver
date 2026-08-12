# Oliver tests and fixtures

Tests are product contracts. `zig build test` runs three suites:

1. **Library module tests** — 114 `test` blocks inside `src/*.zig` covering
   source lines/spans, the normalized document, diagnostics, both dialect
   frontends, Unicode case folding, the HTML renderer, and the public API.
   Markdown tests pin the container stack, thematic-break/list precedence,
   multiline Setext transformation, reference-definition interaction,
   terminal-backslash behavior, fenced-code payload/spans, every implemented
   inline family, exact AST shapes, and exact spans. Textile tests pin
   `p.`/`hN.`/`bq.` structure, hard-break terminators, and `@code@` payloads.
   Renderer tests construct documents directly so renderer behavior is
   verified without a dialect parser.
2. **Fixture and adversarial tests** — 9 tests in `tests/fixtures_test.zig`.
   The explicit index contains 242 Markdown and 24 Textile fixture pairs.
   The Markdown wall includes byte-exact CommonMark 0.31.2 coverage of
   emphasis/strong, code spans, inline links, inline/reference-style images,
   block quotes, list items and lists (§§5.2–5.3: marker-width indentation,
   ordered starts and near misses, empty items, interruption, nesting,
   marker/delimiter separation, tight/loose propagation, and quote/list
   composition), reference links, autolinks, raw HTML, thematic breaks,
   Setext headings, and fenced code blocks; the Textile wall covers `bq.`
   quotes and `@code@` spans. It also verifies shared-model convergence,
   hostile-input completion and leak freedom, NUL policy, diagnostics, and
   deterministic repeat rendering (list stress: 2k nested items, 10k
   same-marker items, 15k alternating markers, 12k variably indented
   markers, and 8k valid plus 8k near-miss ordered markers, each rendered
   twice).
3. **Conformance-harness tests** — 7 tests in `tools/spec_conformance.zig`:
   synthetic corpus extraction (CRLF, tab arrows), malformed-corpus
   rejection, official byte/example-count and SHA-256 identity checks,
   complete/nonoverlapping manifest validation, malformed divergence-record
   rejection, outcome classification, and the single-trailing-newline
   comparison. These tests need no downloaded corpus.

The current complete result is **130/130 tests passing** with Zig 0.16.0.

## Fixture convention

Every fixture has exactly two files:

```text
tests/fixtures/<dialect>/<name>.<ext>   # input
tests/fixtures/<dialect>/<name>.html    # exact expected output
```

- `<ext>` is `.md` for Markdown and `.textile` for Textile.
- Expected output is compared byte for byte. Generated block output ends in
  `\n`; raw HTML may preserve source line-ending bytes inside its span.
- Dialects have separate directories even when their normalized documents
  converge.
- Files are embedded at compile time with `@embedFile`, so fixture execution
  does not give the library core a filesystem dependency.
- `tests/fixtures_test.zig` is the explicit index. An unindexed pair is not a
  test and must not be treated as coverage.

To add a fixture:

1. Add the input and `.html` files.
2. Add one entry to the appropriate fixture table.
3. Run `zig build test --summary all`.

## Coverage requirements

A completed syntax feature should include, where meaningful:

- simplest valid form;
- nesting and interaction with already-landed syntax;
- ambiguous/precedence cases;
- malformed literal fallback;
- Unicode and line-ending cases;
- exact source-span assertions;
- byte-exact deterministic HTML;
- an adversarial shape capable of exposing accidental quadratic work.

The current Markdown wall covers emphasis/strong, code spans, inline and
reference links/images, definitions, autolinks, inline raw HTML, block quotes,
fenced code blocks, thematic breaks, Setext headings, escapes, breaks, paragraphs, and ATX
headings. The leaf-block slice adds four thematic-break fixture groups, eight
Setext groups, a terminal-backslash fixture, exact AST/span tests, renderer
profile tests, and a deterministic 10,000-cycle heading/break workload. The
fenced-code slice adds 13 fixture groups spanning the normative rule families,
exact normalized-payload/span tests, and direct container-boundary coverage.

## Direct document-to-HTML tests

`src/html.zig` builds documents with `Document.init`, `createNode`, and
`appendChild`, then asserts rendered bytes. These tests cover escaping, breaks,
heading clamping, list tightness, raw HTML, thematic breaks, code blocks, both void-element
styles, and empty documents independently of Markdown or Textile.

## Span contract

Spans are first-class behavior. Tests assert, among other things:

- an ATX heading covers its marker line;
- a Setext heading covers its content lines plus underline;
- a thematic break covers its marker line after container markers;
- a fenced code block covers its opening through closing fence while its
  payload contains only normalized literal content and trimmed,
  backslash-resolved info;
- inline children cover only emitted content bytes;
- line-break nodes cover the actual line terminator;
- stripped markers and consumed escape/delimiter bytes are not assigned to
  unrelated nodes.

## Adversarial wall

`tests/fixtures_test.zig` sends hostile bytes through parsing and rendering
under `std.testing.allocator`:

- 100 KB delimiter, backtick, bracket, backslash, and single-line runs;
- deep opener chains and mixed delimiter/code workloads;
- link/image component and unmatched-bracket storms;
- shortcut, collapsed, full, near-miss, and definition-map reference storms;
- very large labels;
- URI/email autolink matches and near misses;
- a 100,000-deep block-quote stack, lazy-continuation flood, and quote/blank
  alternation;
- mixed LF, CRLF, and CR plus NUL bytes;
- 10,000 repeated Setext/thematic transitions rendered twice and compared;
- a 20,000-level list/thematic near-miss that exercises linear suffix
  recognition;
- a 64-byte fence with 10,000 near closers and a 20,000-line unclosed literal
  block, each rendered twice.

The contract is completion without crash, leak, unbounded recursion, or output
nondeterminism. A dedicated fuzz target remains planned; the public
`parse(allocator, bytes, dialect, options)` API is already the fuzz entry point.

## CommonMark 0.31.2 scorecard

`tools/spec_conformance.zig` extracts every normative example from the
official CommonMark `spec.txt`, runs it through Oliver, and prints a per-section
scorecard. Normative examples are an allowed clean-room source.

```bash
curl -O https://spec.commonmark.org/0.31.2/spec.txt

zig build spec-conformance -- spec.txt
zig build spec-conformance -- spec.txt --section "Setext headings"
zig build spec-conformance -- spec.txt --gate
zig build spec-conformance-test
```

The harness is bound to the exact official 0.31.2 corpus (byte count,
example count, and SHA-256, recorded in `tools/commonmark_expectations.zig`)
and rejects a different file before running Oliver. Every example is
classified in a reviewed manifest (`docs/COMMONMARK-EXPECTATIONS.md`):
**supported** (must match byte-for-byte), **not-yet** (a new pass must be
reviewed, not silently counted), or a named **divergence** with pinned
Oliver output. The classified `--gate` fails on a supported regression, an
unexpected not-yet pass, or a changed divergence — in either direction. It
requires the complete corpus: `--section` is report-only and cannot be
combined with `--gate`. The harness converts the spec's tab-arrow marker to
a real tab and ignores exactly one renderer-owned final newline.

Current canonical baseline: **546/652 examples pass** (546 supported,
106 not-yet, 0 named divergences).

- Thematic breaks: 18/19; the remaining example is indented code.
- Setext headings: 25/27; both remaining examples are indented code.
- ATX headings: 17/18; the remaining example is indented code.
- Fenced code blocks: 28/29; the remaining example is indented code.
- Backslash escapes: 11/13; fenced info-string escapes are implemented.
- Link reference definitions: 25/27.
- Block quotes: 22/25.
- List items: 33/48; Lists: 23/26.
- Code spans, emphasis/strong, images, autolinks, inline raw HTML, hard/soft
  breaks, and textual content: 100%.

The former ATX trailing-backslash divergence (example 646) was resolved to
the normative output by the thematic-break/Setext milestone; no named
divergences remain. Failures are not silently skipped: the classified gate
makes the whole 0.31.2 corpus a regression wall.

## Commands

```bash
zig fmt --check build.zig build.zig.zon src tests tools
zig build test --summary all
zig build
```
