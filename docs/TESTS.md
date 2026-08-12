# Oliver Tests and Fixtures

Tests are the contract. `zig build test` runs two suites:

1. **Library module tests** — `test` blocks inside `src/*.zig` (47 tests):
   unit tests for `source`, `document`, `diagnostic`, `markdown`
   (including the emphasis/strong span, mod-3, escape, nesting, code-span
   run-length/trim/opacity, and link precedence/nesting/escape/span
   assertions), `textile`, `html` (including hand-built
   emphasis/strong/code-span/link rendering), and the public API. (The
   html.zig tests also run standalone via `zig test src/html.zig`; see the
   build wiring note below.)
2. **Fixture tests** — `tests/fixtures_test.zig` (6 tests): byte-exact
   fixture rendering for both dialects (74 Markdown fixtures, of which 19
   cover emphasis/strong per docs/INLINE-PARSING.md §15, 12 cover code
   spans per §6.6, and 22 cover inline links per §6.6), the shared-model
   convergence proof, NUL policy, adversarial smoke (100 KB
   delimiter/backtick/bracket runs, 10k-deep open chains, 50k alternating
   `*`/`_` runs, 50k alternating `` ` ``/`*` runs, 20k repeated
   `[a](` / `[a](<` / `[a](u "` link bombs — completion in well under a
   second, no crash/leak; the link bombs are what forced the §6.6
   paren-depth and scan-length DoS guards), and diagnostics.

## Fixture convention

For each fixture `<name>` there are exactly two files:

```text
tests/fixtures/<dialect>/<name>.<ext>   # input
tests/fixtures/<dialect>/<name>.html    # expected output
```

- `<ext>` is `.md` for Markdown, `.textile` for Textile.
- Expected outputs are **exact bytes**: trailing newlines matter (the
  renderer always ends nonempty output with `\n`).
- Markdown and Textile fixtures live in **separate directories** even when
  they produce the same normalized structure.
- Fixtures are embedded at compile time (`@embedFile`), so tests run
  anywhere with no filesystem access — consistent with the library's
  no-filesystem core.

### Adding a fixture

1. Write `tests/fixtures/<dialect>/<name>.<ext>` and
   `tests/fixtures/<dialect>/<name>.html`.
2. Add one entry to the corresponding table (`markdown_fixtures` or
   `textile_fixtures`) in `tests/fixtures_test.zig`. This table is the
   explicit index — keeping it in sync is part of the convention.
3. Run `zig build test`.

## Coverage expectations per feature

When a syntax feature lands, its fixture set should include, where meaningful:

- simplest valid example
- nested example
- ambiguous example
- malformed example (must degrade to text, not crash)
- Unicode example
- source-span assertions (unit tests where useful)
- exact deterministic HTML output

See the fixture list in `tests/fixtures_test.zig` for the current shape.

## Direct document-to-HTML tests

HTML rendering must be testable without any dialect: `src/html.zig` builds
documents by hand (`document.Document.init` + `createNode` + `appendChild`)
and asserts rendered bytes. This covers escaping, break policies, heading
clamping, void-element style, and the empty document — all renderer-owned
behavior, independent of Markdown/Textile.

## Span assertions

Unit tests assert exact `Span` values for structure (e.g. a heading's span
covers the whole line; a text node's span covers the trimmed content).
Spans are a first-class contract, not incidental.

## Adversarial smoke

`tests/fixtures_test.zig` runs hostile inputs through both dialects and the
renderer under `std.testing.allocator` (leak-checking): empty input, blank
runs, huge `#` runs, mixed `\r\n`/`\r`/`\n`, NUL bytes, 100 KB single lines.
Contract: no crash, no hang, no unbounded recursion, deterministic output.
A dedicated fuzz target is a later milestone; the public API
(`parse(allocator, bytes, dialect, options)`) is already the fuzz entry
point.

## Running

```bash
zig build test            # all tests
zig build test --summary all   # per-suite pass counts
```
