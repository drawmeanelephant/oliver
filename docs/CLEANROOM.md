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

## Sources consulted (session 4 — Textile link aliases)

- Hobix "Textile Reference" "External References: Link Aliases"
  <https://hobix.com/textile> — the `[hobix]https://hobix.com` example
  (definition after its uses, on the line after the paragraph), the
  `"link to":hobix!` trailing-punctuation exclusion, and the rendered
  HTML.
- Movable Type "Textile 2 Syntax" "Links"
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  "place one or more links in a block of it's own (it can be anywhere
  within your document)", the `[excom]http://example.com` / `[exorg]...`
  definition-block example, and `"Text to display":alias` references.

No Textile parser implementation source was consulted for the T9 alias
work; the pinned behaviors in docs/TEXTILE-PARITY.md §7 are derived from
the user-facing prose and examples above (first-definition-wins and
case-sensitive exact matching mirror the Markdown §4.7 machinery as
chosen, deterministic defaults where the references are silent).

## Sources consulted (session 5 — Textile block attributes)

- Hobix "Textile Reference" "Attributes: Block Attributes / Block
  Alignments" <https://hobix.com/textile> — the class/id/class#id/style/
  lang examples (`p(example1).`, `p(#big-red).`, `p(example1#big-red2).`,
  `p{color:blue;margin:30px}.` with its `style="color:blue; margin:30px;"`
  normalization, `p[fr].`), the four alignments (`p<.`/`p>.`/`p=.`/
  `p<>.` → `text-align` styles), the `(`/`)` indentation forms (`p(.`
  through `p))).` — a bare `(` needs no closing paren), and the combined
  heading examples (`h2()>. Bingo.`, `h3()>[no]{color:red}. Bingo`) with
  their exact rendered attributes.
- Movable Type "Textile 2 Syntax" "Block Attributes"
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  the modifier placement between the signature and its period and the
  required space after the period.

No Textile parser implementation source was consulted for the T10 block
attribute work; the pinned behaviors in docs/TEXTILE-PARITY.md §8 are
derived from the user-facing prose and examples above (the `; ` style
normalization and empty-class omission are faithful renderings of the
Hobix examples, and the table-only token restrictions reuse the already-
pinned table machinery).

## Sources consulted (session 6 — `bc.`/`pre.` block code)

- Movable Type "Textile 2 Syntax" "Block Formatting"
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  the `bc` signature definition ("block code": "a preformatted section
  like the 'pre' block, but it also gets a `<code>` tag"), the automatic
  `<`/`>` entity translation within `bc` blocks, and the block
  termination rule ("Normally, a block ends with the first blank line
  encountered").
- Textile Markup Language Documentation
  <https://textile-lang.com/> — the `pre.` ("pre-formatted text") and
  `bc.` ("a block of lines of code") signatures.

Hobix does not document either signature (its pre/code example is raw
HTML), so both follow the Textile 2 + current-docs majority. No Textile
parser implementation source was consulted for the T11 code-block work;
the pinned behaviors in docs/TEXTILE-PARITY.md §9 are derived from the
user-facing prose above (the shared `.code_block` payload and escaping
policy come from the already-pinned Markdown fenced-code machinery).

## Sources consulted (session 7 — extended blocks)

- Movable Type "Textile 2 Syntax" "Extended Blocks"
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  "To cause a given block signature to stay active, use two periods in
  your signature instead of one. This will tell Textile to keep
  processing using that signature until it hits the next signature is
  found", the `bq..` example (two lines, no blank, one quote; a `p.`
  signature terminates), and the note that the form is "especially
  useful for `bc` blocks where your code may have many blank lines
  scattered through it".
- Textile Markup Language Documentation
  <https://textile-lang.com/> — "Extended blocks (with empty lines), are
  marked by two periods, e.g. `bc..` or `bq..` and are terminated with
  any other text block signature".

No Textile parser implementation source was consulted for the T12
work; the pinned behaviors in docs/TEXTILE-PARITY.md §10 are derived
from the user-facing prose above (which signatures count as terminators
follows the references' own "signature" list, and Oliver implements
only the three forms — `bq..`, `bc..`, `pre..` — that the references
discuss; `p..`/`h1..` are not extended signatures).

No Markdown or Textile parser implementation source was consulted.
