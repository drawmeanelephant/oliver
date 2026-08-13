# Textile parity audit

Oliver's Markdown frontend is held to the 652-example CommonMark 0.31.2
conformance corpus. Textile has no comparable normative corpus, so its
quality bar is a **fixture audit**: every implemented feature is inventoried
against the shared document model, pinned by fixture pairs and unit tests,
and every gap against the published Textile 2 semantics is either closed or
recorded as a deliberate deferral. This document is that audit. It is
derived only from the clean-room sources of docs/CLEANROOM.md: the Hobix
**Textile Reference**, Movable Type's **Textile 2 Syntax**, and the current
Textile Markup Language Documentation. No parser implementation was
consulted.

## 1. Inventory: implemented Textile features vs. the shared model

| Textile syntax | shared node | HTML | status |
| --- | --- | --- | --- |
| `p.` marker / bare paragraph lines | `.paragraph` | `<p>` | implemented (T1) |
| `hN.` headings | `.heading` (level 1..6) | `<h1>`…`<h6>` | implemented (T1) |
| single-period `bq.` | `.block_quote` → `.paragraph` | `<blockquote><p>` | implemented (T1) |
| newline in a paragraph | `.hard_break` | `<br />` | implemented (T1) |
| `@code@` | `.code_span` (verbatim arena payload) | `<code>` | implemented (T2) |
| `*x*` strong | `.strong` | `<strong>` | implemented (T4) |
| `_x_` emphasis | `.emphasis` | `<em>` | implemented (T4) |
| `**x**` bold | `.bold` | `<b>` | implemented (T4) |
| `__x__` italic | `.italic` | `<i>` | implemented (T4) |
| `-x-` deleted | `.deleted` | `<del>` | implemented (T4) |
| `+x+` inserted | `.inserted` | `<ins>` | implemented (T4) |
| `^x^` superscript | `.superscript` | `<sup>` | implemented (T4) |
| `~x~` subscript | `.subscript` | `<sub>` | implemented (T4) |
| `%x%` span | `.span` | `<span>` | implemented (T4) |
| `"text":url` link | `.link` (arena href/title) | `<a href title>` | implemented (T4) |
| `"text (title)":url` link | `.link` (+ title) | `<a href title>` | implemented (T4) |
| `!url!` image | `.image` (src, alt `""`) | `<img src alt />` | implemented (T4) |
| `!url(alt)!` / `!url (alt)!` image | `.image` (src, alt, title) | `<img src alt title />` | implemented (T4) |
| `!url!:href` linked image | `.link` → `.image` | `<a><img /></a>` | implemented (T4) |
| `*` bullet lists | `.list` (bullet) → `.list_item` → `.paragraph` | `<ul><li>` | implemented (T4) |
| `#` ordered lists | `.list` (ordered) → `.list_item` → `.paragraph` | `<ol><li>` | implemented (T4) |
| marker-depth nesting (`**`, `##`) | nested `.list` inside `.list_item` | nested `<ul>`/`<ol>` | implemented (T4) |
| `|a|b|` rows | `.table` → `.table_row` → `.table_cell` | flat `<table><tr><td>` | implemented (T8) |
| `|_. header|` cells / `_`-marked rows | header cells (`<th>`) | `<th>` | implemented (T8) |
| cell modifiers (`<`, `>`, `=`, `<>`, `^`, `~`, `{style}`, `(class#id)`, `[lang]`, padding) | cell `attrs` (style/class/id/lang) | `<td style="…">` | implemented (T8) |
| `\2` colspan / `/2` rowspan | cell `colspan`/`rowspan` | `colspan="2"`/`rowspan="2"` | implemented (T8) |
| `table<mods>.` signature | table `attrs` | `<table style="…" class="…">` | implemented (T8) |
| row modifiers (incl. `_` header row) | row `attrs` / header flags | `<tr style="…">`, all-`<th>` row | implemented (T8) |
| `[alias]url` definition lines | (no node: collected into the alias table) | never renders | implemented (T9) |
| `"text":alias` reference | `.link` (href from the alias table) | `<a href="defined-url">` | implemented (T9) |

T1/T2/T4 refer to the ledger cards in docs/WORK-LEDGER.md. "T4" is the
phrase/link/image/list milestone this audit drove; every new row is pinned
by a fixture pair plus exact-span unit tests in `src/textile.zig`, and the
convergence test in `tests/fixtures_test.zig` proves the shared renderer
produces byte-identical output for equivalent Markdown/Textile inputs
(Textile `*x*` ↔ Markdown `**x**`, `_x_` ↔ `*x*`, `"x":u` ↔ `[x](u)`,
`!img.png!` ↔ `![](img.png)`, `# x` ↔ `1. x`).

## 2. Gaps vs. Textile 2 semantics: audit results

The audit walked the two references feature by feature. The **biggest
user-visible gaps** were the inline phrase-modifier family, links, images,
and lists — the four families listed in this milestone's brief — because
every paragraph in the documented examples uses at least one of them, and
the previous slice rendered them literally. All four are now implemented.

Remaining gaps are deliberate and recorded in docs/FEATURE-MATRIX.md as
planned/deferred. The notable ones, so the record is honest:

- **Image modifiers** — alignment (`!<x!`, `!>x!`, `!-x!`, `!^x!`, `!~x!`),
  CSS class/id/style, padding, and sizing (`10x20`, `10w 20h`, `20%`) from
  Textile 2. Oliver keeps modifier-prefixed and whitespace-containing image
  bodies literal (fixture `image-literal`).
- **`bq..` extended blocks and citations**, **`pre.`/`bc.`**,
  **footnotes**, **block/line attributes**, **`==` escaping**, and the
  **character-replacement macros** (curly quotes, em/en dashes, ellipsis,
  `(c)`/`(r)`/`(tm)`). All planned/deferred in the feature matrix.

Tables were the last large *block* gap; they are now implemented (T8) —
see §6. The largest remaining *inline* gap, link aliases, is now
implemented too (T9) — see §7.
- **Textile 2's `++bigger++` / `--smaller--`** (`<big>`/`<small>`): only in
  Textile 2, not Hobix; Oliver defers per the "implement once from the
  majority" rule. Runs of 2+ for the single-length operators stay literal.
- **`??citation??`**, **acronyms**, and **definition lists** (Hobix-only or
  Textile 2-only) — deferred.
- **Textile raw HTML** — Textile keeps `<...>` as plain text (no `.raw_html`
  recognition); documented in the model convergence table.
- **Bracket/brace forcing** (`c[*oo*]l`) — documented by Textile 2 as a way
  to force intraword formatting; not inferred by this slice (same position
  as docs/TEXTILE-INLINE-CODE.md §2 for `@code@`).

## 3. Chosen behaviors where the references are silent or disagree

Each choice is a *choice*, recorded here and in the feature matrix, never an
accident. "Both references" means Hobix + Textile 2; where they differ the
disagreement is named.

1. **Phrase delimiter runs.** `*`/`_` of length 1 are strong/emphasis and of
   length 2 are bold/italic (both references agree: "doubling the
   underscores or asterisks"); `-`, `+`, `^`, `~`, `%` are single-length
   only. Runs longer than any documented operator stay **entirely literal**
   (`***x***` is never split into literal `*` + bold `**`), and unmatched
   openers stay literal — the same conservatism as `@code@` edge cases.
2. **Boundary rule.** An opener needs a whitespace-or-punctuation boundary
   before and non-whitespace content immediately after; a closer needs
   non-whitespace before and a whitespace-or-punctuation boundary (or line
   end) after. This is exactly the documented `@code@` contract
   (docs/TEXTILE-INLINE-CODE.md §2) applied uniformly. Textile 2's
   `c*oo*l` counterexample, edge-whitespace phrases, and intraword
   `a^2`/`50%` all stay literal (fixture `phrase-boundaries`).
3. **Nesting and LIFO.** Phrase content is scanned for nested phrases
   (`*_way_*` is Textile 2's own example). Matching is strict LIFO: a
   closer closes only the innermost open phrase with the same character and
   run length. A mismatched closer (e.g. a `*` while an `_` is innermost)
   stays literal and does not close a deeper opener.
4. **Same-line and single-pass.** Phrases, like `@code@`, never cross a line
   ending. The scanner is one linear pass over the line (scan → LIFO match →
   emit with an explicit work stack, so deep nesting cannot overflow the
   call stack); code-span opacity is preserved — a pending `@` opener makes
   the intervening bytes opaque to phrases/links/images, so
   `@*strong* "link":u@` stays one code span.
5. **Link display text is plain text.** Textile 2 documents no formatting
   inside `"text":url`, so the display text is one plain `.text` node (not
   re-scanned), which also makes nested links impossible by construction.
   Image src/alt are likewise opaque.
6. **Link URL boundary.** The URL runs to whitespace or a closing bracket
   (`)` `]` `}`); the bracket trick `You["gotta":url]seethis!` (Textile 2)
   therefore never swallows its `]`. Common trailing sentence punctuation
   (`.`, `,`, `;`, `:`, `!`, `?`, quotes, `)]}`) is excluded from the URL
   (Hobix: "the link won't include any trailing punctuation"). `&` in URLs
   is escaped by the shared renderer like Markdown hrefs (Textile 2's
   "unescaped `&` within URLs will be properly escaped").
7. **Link title.** `"text (title)":url` — the parenthesized suffix of the
   display text, recognized only when preceded by a space (so
   `"a(b)":url` has no title and display `a(b)`). The title is arena-owned
   and HTML-escaped at render, like Markdown titles.
8. **Image alt/title.** `!url(alt)!` (Hobix, no space) and `!url (alt)!`
   (Textile 2, with space) both set the alt; per the Hobix example the alt
   also becomes the title. The shared renderer's fixed attribute order is
   `src`, `alt`, `title` (Hobix's raw output shows `title` before `alt`;
   Oliver's order is the renderer policy of docs/ARCHITECTURE.md).
9. **Lists are single-line, tight, and marker-depth driven.** Each item is
   one line (`*`/`#` run + space/tab + content). Nesting is by marker count,
   not indentation (both references' `**`/`##` examples). Items render
   tight (no `<p>`), like Hobix's `<li>A first item</li>`. A blank line, a
   block signature, or any non-marker line closes the list tree — an
   unmarked line after list content is a fresh paragraph, and a following
   marker line starts a new list (neither reference defines multi-line
   items or lazy continuation).
10. **Depth jumps and marker switches.** `* a` then `*** b` (skipping a
    level) opens the intermediate list with an empty item — deterministic,
    but outside the documented examples. A different marker at the same
    depth closes that list and opens a sibling list (`* a` / `# b` are two
    sibling lists, matching the "each item in its own paragraph" reading).
    A mixed run (`*#`) or a run not followed by space/tab is ordinary text.
11. **List placement.** Marker lines interrupt an open paragraph or `bq.`
    quote (they are recognized block signatures), and the resulting list
    attaches to the same parent the interrupted block would have had — the
    root. Lists inside block quotes are not in either reference and are
    deferred.
12. **Opaque-atom precedence.** Code spans, links, and images are atoms
    discovered in the same scan as phrase delimiters; their contents are
    opaque and they are never split by phrase scanning. Phrase delimiters
    inside link display text or image src/alt are not recognized (they are
    inside atoms).

## 4. Complexity

The inline pass is three linear passes over the line (item scan, LIFO
match, emit) plus a work stack for nested phrase emission — no recursion,
no substring rescans, no quadratic delimiter storms (the 10,000-pair
`*ok*`/near-miss storm and the 2,000-deep nesting test in `src/textile.zig`
run as ordinary unit tests, and each passes under `std.testing.allocator`).
Failing link/image lookaheads only ever scan up to the next `"`/`!` (or a
URL's whitespace), and those segments are disjoint, so the scan is linear
even for hostile quote/bang runs.

Table parsing is likewise linear: each row is scanned once into cells and
a single close-time pass resolves the column defaults, so a 20,000-row
storm test in `src/textile.zig` runs as an ordinary unit test.

## 5. Acceptance contract

The fixture wall added by this audit:

- the full phrase-modifier family with exact node spans and byte-exact HTML
  (`phrase-modifiers`, `phrase-in-heading`);
- documented nesting `*_way_*` plus deeper same-type/other-type nesting
  (`phrase-nesting`);
- every boundary fallback: intraword, edge whitespace, over-long runs,
  deferred `--`, unmatched openers (`phrase-boundaries`);
- links: trailing punctuation, mailto, relative URLs, titles, the bracket
  trick, and literal fallbacks (`link-basic`, `link-title`,
  `link-bracket-trick`, `link-literal`);
- images: absolute/relative src, Hobix and Textile 2 alt forms, the link
  attachment, and literal fallbacks for deferred modifiers and malformed
  shapes (`image-basic`, `image-linked`, `image-literal`);
- lists: bullet/ordered basics, mixed-depth nesting, sibling lists, and
  termination by blank line, plain text, and signatures
  (`list-basic`, `list-nested`, `list-mixed`);
- cross-family composition and `@code@` opacity (`inline-composition`);
- tables: the Hobix examples byte-for-byte (basic, header cells, the cell-
  attribute rows, colspan, rowspan, cell style, signature on its own line,
  row attributes), the Textile 2 complex example, the header-alignment
  propagation rule, inline content in cells, literal fallbacks, and block
  closing (`table-basic` … `table-close`);
- link aliases: the Hobix example, the Textile 2 definition-block form,
  precedence/case-sensitivity, and literal fallbacks
  (`link-alias-basic`, `link-alias-def-block`, `link-alias-precedence`,
  `link-alias-literal`);
- shared-model convergence with the Markdown frontend (see §1) — including
  `"x":alias` + `[alias]url` ↔ `[x][a]` + `[a]: http://u`, byte-identical.

## 6. Tables (T8): pinned behaviors

Both references document the syntax; only Hobix shows rendered output, so
Hobix's HTML is the byte-level target where it exists, and Textile 2's
prose fills the gaps. Every choice below is a *choice*, recorded here and
in the feature matrix.

**Block shape.** A table is its own block: consecutive row lines compose
one table until a blank line or any other block-level line (a signature, a
heading, a list marker, or plain paragraph text closes it). Two tables
need a blank line between them. An optional `table<mods>.` signature opens
the table — alone on its own line (Hobix) or followed by a space and the
first row (Textile 2's `table(fig). {color:red}_|Top|Row|`). A signature
that never receives a row produces no table at all (tables must be in
their own block). A row must start with `|` (after any row modifiers) and
end with `|`; every `|` splits — Textile documents no pipe escape — so
`|a|b` (no closing pipe) is a paragraph. Rows need not be aligned: each
row emits exactly its cells (the rowspan example's `| b |` is a one-cell
row). Row-shaped lines can open a table even without a signature
(consecutive `|…|` lines are a table), and a modifier-prefixed row is
accepted as the first line too — the references only ever show that shape
inside a table, but it is unambiguous.

**Modifiers and the `. ` contract.** Cell modifiers (`_`, `<`, `>`, `=`,
`<>`, `^`, `~`, `\2`, `/2`, `{style}`, `(class#id)`, `[lang]`, `(`/`)`
padding) must be terminated by a period followed by a space (Textile 2:
"a period followed with a space must be placed after any modifiers"). A
terminator without the space — `|_.|`, `|_.< a |` — is not a modifier run:
the whole cell stays verbatim. Row modifiers end at the first `|` (Textile
2's `{color:red}_|Top|Row|`) or after `. ` (Hobix's `{background:#ddd}.
|This|…`). A malformed token anywhere in the run (an unclosed `{`, a
non-modifier character) makes the whole line literal.

**Rendering.** Cells render as flat `<tr>` rows with no `<thead>`/`<tbody>`
— both references show flat rows even with header cells (the model's
`sections` flag is false for Textile, true for GFM; docs/DOCUMENT-MODEL.md).
`_` marks a header cell (row-level `_` marks the whole row), rendered
`<th>` (Hobix). Cell content is verbatim, including leading/trailing
spaces (`| name |` → `<td> name </td>`), and is inline-parsed (emphasis,
links, images, `@code@` all work inside cells). Attributes emit in the
fixed render order style/class/id/lang; the composed style joins its parts
with `; ` and a trailing `;` in the pinned order user `{style}`,
padding-left, padding-right, text-align, vertical-align (`h2()>.` →
`style="padding-left:1em; padding-right:1em; text-align:right;"`).
Alignment renders as CSS (Hobix's `style="text-align:left;"`), never the
GFM `align` attribute.

**Header-alignment propagation.** Textile 2: "When a cell is identified
as a header cell and an alignment is specified, that becomes the default
alignment for cells below it." Walking the table top-down, a header cell
with an explicit alignment updates its column's default; every cell below
inherits the current default unless it carries its own alignment (the
"override" the references describe). Only horizontal alignment propagates
(`^`/`~` vertical stays per-cell). The resolved defaults are recorded in
`table.alignment`; each cell's resolved alignment is composed into its
`style` at parse time. The first explicit-alignment header cell in a
column wins over later ones (a later header row restarts its column's
default for the cells below it).

**Table-signature alignment.** Textile 2 describes table-level `<`/`>`/`=`
as alignment of the table itself (`<`/`>` float, `=` sets left/right
margins to auto) with no literal HTML in either reference; Oliver pins
`float:left;`, `float:right;`, and `margin-left:auto;margin-right:auto;`
respectively. `<>` is cells-only (Textile 2) and rejected on the
signature.

**Literal fallbacks (all pinned by `table-literal`).** No closing pipe;
modifiers without the `. ` terminator; `table.` followed by non-row text
(`table. of contents` stays a paragraph — the rest after the period must
parse as a row); a modifier run without a `. ` or `|` terminator; an
unclosed `{`/`(`/`[` inside a cell (the line is still a row, the cell
verbatim). `||` is a degenerate one-cell row and stays a table.

## 7. Link aliases (T9): pinned behaviors

Both references document the alias mechanism: Hobix "Link Aliases" (the
`[hobix]https://hobix.com` example, with uses before the definition) and
Textile 2 "Links" ("place one or more links in a block of it's own, it
can be anywhere within your document", then `"Text to display":alias`).
Every choice below is a *choice*, recorded here and in the feature matrix.

**Definition lines.** A definition is a line of the form `[alias]url`:
`[` + a non-empty alias with no `[` + `]` + a non-whitespace URL running
to end of line. Textile 2's "block of its own" is read loosely on purpose:
the Hobix example places the definition directly after the paragraph with
no blank line, so a def line needs no separation. A recognized def line
**vanishes from output without changing the surrounding block** — an open
paragraph or list continues across it ("place the URL anywhere in your
document"), and a bare block of def lines renders nothing. A def line that
lands between table rows closes the table (the table's own rule: any
non-row line ends it).

**Resolution.** A `"text":alias` link whose URL token matches a defined
alias uses the defined URL; the token is otherwise an ordinary URL — an
undefined alias is simply a relative URL (no error), and a defined alias
always wins over the token's literal bytes. Matching is **exact and
case-sensitive** and the **first definition of an alias wins** — the
references are silent on both, so the conservative, deterministic choices
mirror the Markdown §4.7 machinery. The definition's URL is verbatim (no
trailing-punctuation trimming, unlike reference URLs).

**Scope.** Aliases resolve in every inline context — paragraphs, headings,
list items, and table cells — because the alias table is document-global
and collected before any inline parsing. Image link attachments
(`!url!:href`) stay direct-URL only; neither reference documents aliases
there. Titles work unchanged: `"text (title)":alias`.

**Literal fallbacks (all pinned by `link-alias-literal`).** `[1] See
footnote` (space after `]`), `[]http://x` (empty alias), `[x]` (no URL),
`[x] url with space` (whitespace in the URL), and a def-shaped substring
inside a line are all ordinary paragraph text.


