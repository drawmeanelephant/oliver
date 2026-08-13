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

Session 8 (T13 footnotes) consulted:

- Hobix Textile Reference "Footnotes" <https://hobix.com/textile/> —
  "footnote references are like this[1]... you begin a new paragraph
  with fn and the footnote's number, followed by a dot and a space",
  with the rendered example `[1]` → `<sup><a href="#fn1">1</a></sup>`
  and `fn1.` → `<p id="fn1"><sup>1</sup> Down here, in fact.</p>`.
- Movable Type "Textile 2 Syntax" "Footnotes"
  <https://movabletype.org/documentation/author/textile-2-syntax.html> —
  the same structure with `class="footnote"` added on both the
  reference's `<sup>`/`<a>` and the block's `<p>`.

No Textile parser implementation source was consulted for the T13
work; the pinned behaviors in docs/TEXTILE-PARITY.md §11 are derived
from the user-facing prose above (Oliver renders the Textile 2 classed
form, and the §8 block-modifier set applies to `fnN.` signatures like
any other block signature, with the structural class/id winning).

Session 9 (T14 block-quote citations) consulted:

- Textile Markup Language Documentation "Block quotations"
  <https://textile-lang.com/doc/block-quotations> — "Block quotes may
  include a citation URL immediately following the period:
  `bq.:http://textpattern.com/ A cited quotation.`" (the current docs
  are already an allowed reference).
- Learn X in Y Minutes <https://learnxinyminutes.com/textile/> —
  "Block quotes use the tag 'bq.'... `bq.:http://someurl.com` You can
  include a citation URL immediately after the '.'".

No Textile parser implementation source was consulted for the T14
work. Neither Hobix nor Textile 2 documents the citation form; the
pinned behaviors in docs/TEXTILE-PARITY.md §12 are derived from the
user-facing prose above, with the rendering (the `cite` attribute on
the blockquote, the standard HTML citation) per the user's
specification.

Session 10 (T15 character replacements) consulted:

- Hobix Textile Reference "Entities" <https://hobix.com/textile/> —
  curly single/double quotes, `--` → em dash, ` - ` → en dash,
  `...` → ellipsis, `x` → dimension sign, and `one(TM), two(R),
  three(C).` → ™/®/©, with the rendered examples.
- Movable Type "Textile 2 Syntax" "Character Replacements"
  <https://movabletype.org/documentation/author/textile-2-syntax.html>
  — "A few simple, common symbols are automatically replaced:
  (c) (r) (tm)", plus the `--` → em-dash note and the `{...}`
  character-macro table (which Oliver defers).
- Textile Markup Language Documentation "Automatic conversions"
  <https://textile-lang.com/> — curly quotes/apostrophes, ` - ` → en
  dash, ` -- ` → em dash, `...` → ellipsis, digit-adjacent `x` →
  dimension sign, and `(tm)`/`(R)`/`(C)`/`(1/4)`/`(1/2)`/`(3/4)`/
  `(o)`/`(+/-)` → their Unicode equivalents.

No Textile parser implementation source was consulted for the T15
work; the pinned behaviors in docs/TEXTILE-PARITY.md §13 are derived
from the user-facing prose above (the quote-direction rules are
Oliver's deterministic local rules pinned by fixtures; Textile 2's
`{...}` macro table is deferred because only the paren forms are
documented by the other two references).

Session 11 (T16 `==` escaping) consulted:

- Movable Type "Textile 2 Syntax" "Escaping"
  <https://movabletype.org/documentation/author/textile-2-syntax.html>
  — the lone-`==` block region ("let you put some regular HTML markup
  in your document", "will not be formatted by Textile at all") and
  the inline span (`p. This is ==*a test*== of escaping.`), with the
  full example.
- Textile Markup Language Documentation "Character conversions"
  <https://textile-lang.com/doc/special-characters> — "When automatic
  character conversion is not wanted, the Textile formatting can be
  temporarily suspended by wrapping the text passage into ==.
  Straight quotation marks are =="left alone"== in this example."

Hobix does not document `==` (its only escape mechanism is raw HTML),
so the T16 behaviors follow the Textile 2 + current-docs majority
(block region → raw passthrough via the shared `.html_block` leaf;
inline span → literal text, HTML-escaped at render like any text). No
Textile parser implementation source was consulted; the boundary and
fallback pins in docs/TEXTILE-PARITY.md §14 are Oliver's conservative
deterministic rules, derived from the user-facing prose above.

Session 12 (T17 line attributes) finding:

- Movable Type "Textile 2 Syntax" "Block Formatting"
  <https://movabletype.org/documentation/author/textile-2-syntax.html>
  — the only pipe-delimited block parameter is the **`|filter|`**
  filter form ("A filter may be invoked to further format the text for
  this signature"); there is no pipe-attribute paragraph form.
- Checked and confirmed absent in: Hobix Textile Reference
  <https://hobix.com/textile/>, the current Textile docs
  <https://textile-lang.com/> (including the paragraphs and category
  pages), the original Dean Allen reference (archived textism.com),
  the RedCloth reference manual, Learn X in Y Minutes
  <https://learnxinyminutes.com/textile/>, and the php-textile
  README/reference.

Finding: the `|...|.` pipe-attribute line form is **not** documented by
any consulted user-facing source, so the T17 implementation follows the
user's specification — the pipe wrapping is per-spec — while every
modifier token and its composition is the reference-documented §8 block
set from all three references (Hobix "Block Attributes"; Textile 2
"Block Formatting"; the current docs "Formatting modifiers"). No
Textile parser implementation source was consulted; the pins in
docs/TEXTILE-PARITY.md §15 are Oliver's conservative deterministic
rules on the user-defined grammar.

Session 13 (T18 image modifiers) finding:

- Movable Type "Textile 2 Syntax" "Images"
  <https://movabletype.org/documentation/author/textile-2-syntax.html>
  — "You can also align images in your text, much like HTML: `!<x!`,
  `!>x!`, `!=x!`, `!-x!`, `!^x!`, `!~x!`"; sizing — "`10x20` (10
  pixels wide and 20 pixels high), `10w 20h` (the words form), `20%x40%`
  (the percentage form)" and "a single `20%` ... proportional sizing"
  — and "you can also add the standard block-attribute syntax"
  (`{style}`/`(class)`).
- Textile Markup Language Documentation "Images"
  <https://textile-lang.com/doc/images> — the `=` centered form
  ("horizontal alignment") and the `(class)` / `{style}` forms.

Finding: the two references agree on the image-modifier family (both
carry alignment plus the block-attribute set; Textile 2 adds the size
forms). Oliver implements Textile 2 plus the current docs — the
`vertical-align` mapping for `-`/`^`/`~` follows Textile 2's prose
("like HTML"), the `=` mapping (block + auto side margins) follows
both references, and the size grammar is Textile 2's four documented
forms. No Textile parser implementation source was consulted; the
alignment-fragment and literal-fallback pins in docs/TEXTILE-PARITY.md
§16 are Oliver's conservative deterministic rules on the user-facing
prose above.

Session 14 (T19 big/small phrases) finding:

- Movable Type "Textile 2 Syntax" "Inline Formatting"
  <https://movabletype.org/documentation/author/textile-2-syntax.html>
  — "`++bigger++` Translates into `<big>bigger</big>`" and
  "`--smaller--` Translates into: `<small>smaller</small>`".

Finding: Textile 2 is the **only** clean-room reference documenting
big/small — Hobix and the current Textile docs do not — which is why
the earlier milestone deferred them per the "implement once from the
majority" rule (recorded ambiguity #18). The user's explicit request
lifts the deferral. The implementation adds no new grammar: a doubled
run of `-`/`+` is a phrase operator like `**`/`__`, and the documented
`--` → em dash replacement (all three references) still applies to any
`--` that cannot form a phrase pair — the interaction is pinned in
docs/TEXTILE-PARITY.md §17. No Textile parser implementation source
was consulted.

Session 15 (T20 span attributes + `{...}` character macros) finding:

- Hobix Textile Reference "Attributes: Phrase Attributes"
  <https://hobix.com/textile/> — "All block attributes can be applied
  to phrases as well by placing them just inside the opening
  modifier", with the examples `*{color:red}blushed*` →
  `<strong style="color:red;">blushed</strong>`, `_(big)sprouted_` →
  `<em class="big">sprouted</em>`, and `%[es]cabeza%` →
  `<span lang="es">cabeza</span>`.
- Movable Type "Textile 2 Syntax" "Inline Formatting"
  <https://movabletype.org/documentation/author/textile-2-syntax.html>
  — "Inline formatting operators accept the following modifiers:
  `{style rule}`, `[ll]`, `(class) or (#id) or (class#id)`" — and
  "Character Replacements": "there are a whole set of character
  macros that are defined by default. All macros are enclosed in
  curly braces. These include: `{c|}` or `{|c}` cent sign, `{L-}` or
  `{-L}` pound sign, `{Y=}` or `{=Y}` yen sign. Many of these macros
  can be guessed. For example: `{A'}` or `{'A}`, `{a"}` or `{"a}`,
  `{1/4}`, `{*}`, `{:)}`, `{:(}`."

Finding: the span's attribute forms follow Hobix's documented example
plus Textile 2's inline modifier list (style/lang/class-id — padding
and alignment are blocks-only); the other phrase operators' attribute
forms (`*{color:red}x*`, `_(big)x_`) are documented by Hobix but stay
deferred. The `{...}` macro table is implemented for exactly the
documented forms and mirrored orders — the "many of these macros can
be guessed" sentence documents a general letter+accent pattern whose
full table is the reference implementations' data, so the pattern is
recorded as deferred under the clean-room rule (docs/TEXTILE-PARITY.md
§18). The brace-edge phrase rule (operators adjacent to `{`/`}` are
not recognized) is Oliver's conservative deterministic choice so the
`{*}`/`{-L}` macros stay whole; no Textile parser implementation
source was consulted.

Session 16 (T21 phrase attributes on every operator) finding:
Hobix "Phrase Attributes" — "All block attributes can be applied to
phrases as well by placing them just inside the opening modifier",
with the examples `*{color:red}blushed*` →
`<strong style="color:red;">blushed</strong>`, `_(big)sprouted_` →
`<em class="big">sprouted</em>`, and `%[es]cabeza%` →
`<span lang="es">cabeza</span>` — extends the T20 span machinery to
the whole phrase family, with the same Textile 2 inline modifier list
(style, lang, class/id). The `{`-after-opener reading (`*{c|}bold*`
is a style token, not a macro) is the deterministic consequence of
"all block attributes ... just inside the opening modifier"; no
Textile parser implementation source was consulted.

No Markdown or Textile parser implementation source was consulted.
