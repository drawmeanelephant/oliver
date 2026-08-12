# Oliver Architecture

Oliver is a small, freestanding markup parsing and rendering library. It is
markup infrastructure, not a publishing framework.

## Pipeline

```text
source bytes
    |
    v
dialect parser (markdown | textile)
    |
    v
normalized typed document
    |
    v
renderer (html)
    |
    v
output bytes
```

The two boundaries that matter:

- **Parser → document**: dialects converge into one typed model. Textual
  payloads are spans/slices into the source; nothing is copied.
- **Document → renderer**: rendering is dialect-independent and never
  reparses source. The renderer is the only place HTML bytes are decided.

## Module map

| file | role |
| --- | --- |
| `src/oliver.zig` | public API root: `parse`, `ParseResult`, `Dialect`, `ParseOptions` |
| `src/source.zig` | `Source`, `Span` (u32 half-open ranges), line iteration, line/column |
| `src/document.zig` | normalized model: `Document`, `Node`, `Tag`, `Data`, traversal |
| `src/diagnostic.zig` | structured diagnostics (severity, code, offset, line, column, span, message) |
| `src/markdown.zig` | Markdown frontend (block pass + inline pass) |
| `src/textile.zig` | Textile frontend (block pass + inline pass) |
| `src/html.zig` | deterministic HTML renderer |
| `src/main.zig` | provisional CLI: arguments + stdio only; no parser semantics |
| `tests/fixtures_test.zig` | fixture-driven tests + adversarial smoke tests |

Frontends are deliberately independent files: they share the document model
and the renderer, but each owns its syntax. Common structure is *not* forced
into shared parsing code until there is a real reason.

## Ownership and memory model

- The caller supplies the allocator (`oliver.parse(allocator, ...)`).
- A `ParseResult` owns a `Document`; the `Document` owns an arena. All nodes
  and the diagnostics array are arena-allocated. `result.deinit()` frees
  everything in one step.
- Text payloads (`Data.text`) are **borrowed slices of the input**. The input
  must outlive the result. No source text is copied during parsing.
- The renderer allocates only a temporary traversal stack (explicit
  `gpa` parameter); nothing is retained.
- No global mutable state, no hidden caches, no internal allocations outside
  the arena and the renderer's stack.

## Determinism

Same input + same options → same document → same output, every time.

- Attribute emission: link attributes are emitted in the fixed order
  `href` then `title`, always double-quoted (see HTML output policy below).
  Future attributes (Textile classes/ids/styles) will join in a documented
  fixed order.
- No hash-map iteration order is ever part of output.
- Generated output line endings are always `\n`, regardless of input line
  endings (`\r\n`, `\r`, `\n` are all recognized and normalized away by
  the line scanner; the renderer emits its own `\n`). Raw HTML leaves are
  the deliberate exception: their source spans, including embedded line
  endings, are written verbatim.

## HTML output policy (`src/html.zig`)

Explicit, documented policies:

- Text escaping: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`;
  NUL (U+0000) → U+FFFD. The CommonMark reference output escapes the same
  set. (CommonMark replaces NUL during parsing; Oliver defers replacement to
  rendering and documents the divergence.)
- Link `href` percent-encoding: a deliberate renderer policy derived from
  the spec examples (the spec leaves URL rendering policy open). Safe
  characters are alphanumerics plus `-_.~!*'(),;:&=+$#@/%?`; everything
  else — space, `"`, `\`, `<`, `>`, backtick, brackets, control
  characters, and all non-ASCII bytes — is percent-encoded as `%XX`
  (uppercase hex). The encoded href is then HTML-escaped (`&` → `&amp;`).
  Titles are HTML-escaped without percent-encoding.
- Raw HTML: Markdown raw-HTML leaves are allowed and written verbatim from
  their source spans; they are not reparsed or escaped. This is the chosen
  policy for the inline §6.6 slice. HTML blocks (§4.6) and a configurable
  escaped/rejected mode remain future work.
- Headings: `<h1>`..`<h6>`; levels outside 1..6 are clamped (defensive for
  hand-built documents; frontends never produce them).
- Lists: `<ul>`/`<ol>` and `<li>` are emitted from the normalized list
  nodes; tight-list direct paragraphs omit `<p>`, while loose-list
  paragraphs retain it. Code blocks and tables remain unimplemented.
- Line endings: `\n` only. Every block-level element is followed by exactly
  one `\n`; nonempty output always ends with `\n`. Empty input → empty output.
- Void elements: `<br />` (CommonMark reference style) by default; toggle
  `RenderOptions.void_trailing_slash` for HTML5 `<br>`.
- Attributes: none emitted in this slice. When they arrive: fixed emission
  order (e.g. `id`, `class`, `style`, `lang`, then others) — never
  map-iteration order.

## Fuzzability and robustness

- The public entry point takes arbitrary bytes: `parse(allocator, bytes,
  dialect, options)`. No file, environment, or network access anywhere in the
  core.
- Offsets are `u32`; inputs over `source.max_input_len` (4 GiB) are rejected
  with `error.InputTooLarge` before any parsing — an API error, never a
  diagnostic, never a wrap.
- Rendering and traversal use explicit stacks, not recursion, so untrusted
  nesting cannot overflow the call stack.
- The parsers are single-pass over lines with an incremental cursor; no
  pathological rescanning of the whole document.
- Adversarial smoke tests exercise empty input, huge delimiter runs, NUL
  bytes, mixed line endings, and 100 KB single lines (see
  `tests/fixtures_test.zig`). A real fuzz target is a later milestone; the
  API already supports it.

## Performance shape (expectations, not benchmarks)

- No repeated whole-document rescans; incremental line cursor; spans instead
  of copied substrings.
- Streaming HTML output from a completed document (the CLI renders straight
  to a buffered stdout writer).
- Allocation is arena-based (one growth pattern, freed in one shot).
- No premature optimization; benchmark corpora come later.

## WebAssembly friendliness

The core (`source`, `document`, `diagnostic`, `markdown`, `textile`, `html`)
requires no filesystem, environment, process, clock, network, or threads.
`std.Io.Writer` is a pure vtable struct, so the renderer works with memory
writers on freestanding targets. The only host-touching file is the CLI,
which is not part of the library.

## Non-goals (consumers build these)

Filesystem discovery, project graphs, site navigation, templates, content
databases, publication workflows, network access, subprocess execution,
plugin discovery, environment inspection, application state, static-site
generation, source repositories, frontmatter semantics, wiki links,
includes/transclusion, syntax-highlighting subprocesses.

## Provisional decisions (revisit deliberately)

- The renderer takes a plain `*std.Io.Writer`-compatible value (anytype
  `writeAll`), which couples the library to the Zig 0.16 writer shape. The C
  ABI milestone will add a render-to-buffer path.
- `ParseOptions` is empty; fields arrive as policy decisions do.
- Heading levels are `u8`; spans are `u32`. Both are documented bounds.
