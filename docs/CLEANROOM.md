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
  `hN.` headings, `bq.` block quotations, line breaks, phrase modifiers,
  attributes, lists, links, images, tables.
- Movable Type "Textile 2 Syntax" documentation (Brad Choate)
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  block signatures, `p.`/`hN.`/`bq.` marker rules, block-quote structure,
  `<br />` line-break policy, `==` escaping, inline modifiers, tables,
  character replacements.
- Textile Markup Language Documentation, "Block quotations"
  <https://textile-lang.com/doc/block-quotations> — current user-facing
  documentation for blank-line termination of single-period `bq.`, the
  separate extended `bq..` form, and citation URLs. Only the single-period,
  non-citation form is implemented in this slice.
- Zig 0.16 standard library source (local toolchain, `/opt/homebrew/.../std/`)
  — official library documentation: `std.Io.Writer`, `std.process.Init`,
  `std.ArrayList`, `std.heap.ArenaAllocator`, build API.

No Markdown or Textile parser implementation source was consulted.
