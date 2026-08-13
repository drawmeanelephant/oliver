# Oliver Clean-Room Rules

Oliver is a clean-room implementation. This file is the binding contract for
everyone (human or agent) who writes Oliver code. Read it before adding
syntax features.

## The absolute rule

Do **not** inspect, clone, search, browse, copy, translate, imitate, or derive
implementation techniques from existing Markdown or Textile parser source code.

In particular, do not study parser implementations such as:

- cmark / cmark-gfm
- pulldown-cmark
- markdown-it
- goldmark
- Blackfriday
- Pandoc implementation code
- RedCloth
- Textile parser libraries
- Apex implementation code
- any other markup parser implementation

Also forbidden:

- GitHub code search used to answer implementation questions.
- Asking another model to summarize how an existing parser works.
- Porting algorithms from another language.
- Intentionally recreating another project's internal architecture from memory,
  even where prior training makes it tempting.

## Allowed sources

Behavior comes from specifications and user-facing documentation, not from
implementations:

- language syntax specifications (e.g. the CommonMark spec)
- normative examples that are part of a specification
- interoperability documentation
- official Zig language/library documentation
- Unicode standards
- HTML specifications
- public prose documentation describing user-visible Markdown/Textile syntax
  (e.g. the Hobix Textile reference, Movable Type's "Textile 2 Syntax" page)

The line is: **specification text and user-visible syntax documentation are
allowed; source code of parsers is not.**

## What to do when a specification is ambiguous

1. Record the ambiguity in `docs/FEATURE-MATRIX.md` under "recorded
   ambiguities" with the sources that disagree.
2. Choose one Oliver behavior deliberately, and mark it as chosen.
3. Implement exactly that behavior, and test it with a fixture that pins it.
4. Do not silently accumulate multiple incompatible dialects. Compatibility
   modes are a later, deliberate decision, never an accident.

## How to add a syntax feature

1. Consult only allowed sources; cite them in the feature matrix.
2. Decide the behavior; if ambiguous, record + choose as above.
3. Add the smallest fixture set first: simplest valid, nested, ambiguous,
   malformed, Unicode, source spans, exact HTML.
4. Implement it in the shared document model + one frontend, then the other
   frontend where semantics genuinely match; where they differ, preserve the
   difference and document it.
5. Run `zig build test`. Add span assertions where they add value.

## Sources consulted (session 1)

- CommonMark specification 0.31.2 (2024-01-28), `spec.txt`
  <https://spec.commonmark.org/0.31.2/spec.txt> — normative Markdown
  behavior for the features in the slice: lines/line endings, blank lines,
  tabs, NUL replacement, backslash escapes (§2.4), thematic breaks (§4.1),
  ATX headings (§4.2), Setext headings (§4.3), fenced code blocks (§4.5),
  paragraphs, containers, and precedence of block vs inline structure.
- Hobix "Textile Reference" (Dean Allen)
  <https://hobix.com/textile> — user-facing Textile syntax: paragraphs,
  `hN.` headings, `bq.` block quotations, line breaks, phrase modifiers
  including its `@r.to_html@` code-phrase example, attributes, lists, links,
  images, tables.
- Movable Type "Textile 2 Syntax" documentation (Brad Choate)
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  block signatures, `p.`/`hN.`/`bq.` marker rules, block-quote structure,
  `<br />` line-break policy, `==` escaping, inline `@code@`, entity escaping,
  generic phrase-boundary/forcing guidance, tables, character replacements.
- Textile Markup Language Documentation, "Block quotations"
  <https://textile-lang.com/doc/block-quotations> — current user-facing
  documentation for blank-line termination of single-period `bq.`, the
  separate extended `bq..` form, and citation URLs. Only the single-period,
  non-citation form is implemented in this slice.
- Zig 0.16 standard library source (local toolchain, `/opt/homebrew/.../std/`)
  — official library documentation: `std.Io.Writer`, `std.process.Init`,
  `std.ArrayList`, `std.heap.ArenaAllocator`, build API.

## Sources consulted (session 2 — GFM tables)

- GitHub Flavored Markdown Spec 0.29-gfm (2019-04-06),
  §4.10 Tables (extension) <https://github.github.com/gfm/#tables-extension->
  — the normative tables behavior: header + delimiter + body rows, cell
  splitting and trimming, alignment colons, escaped pipes (including the
  `` `\|` `` → `<code>|</code>` code-span example), body-row padding/
  truncation, and termination at blank lines or other block structures.
  The spec's prose ("cells whose only content are hyphens", no count
  stated) and its `:-:` alignment example were reconciled with the issue
  contract ("3+ hyphens per column") as a chosen minimum, recorded in
  docs/TABLES.md §3.

## Sources consulted (session 3 — Textile tables)

- Hobix "Textile Reference" "Tables" section
  <https://hobix.com/textile> — re-consulted for T8: the rendered HTML of
  simple rows, header cells, cell attributes (alignment/valign styles),
  colspan/rowspan, cell styles, the `table{...}.` signature on its own
  line, and row attributes — the byte-level target for the Textile table
  fixtures.
- Movable Type "Textile 2 Syntax" "Tables" section
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  the modifier list (including `<>` cells-only and `\n`/`/n` spans), the
  `table(fig). {color:red}_|Top|Row|` complex example, the row/cell
  `. `-termination rule, the header-alignment propagation rule, and
  table-level `<`/`>`/`=` float/margin semantics.
- Textile Markup Language Documentation <https://textile-lang.com/> —
  the modifier list and table-level alignment semantics.

No Textile parser implementation source was consulted for either the
session-1 Textile work or T8; the pinned behaviors in
docs/TEXTILE-PARITY.md §6 are derived from the user-facing prose and
examples above.

No Markdown or Textile parser implementation source was consulted.
