# Oliver engineering work ledger

This is the dependency-ordered construction queue at the CommonMark 0.31.2
leaf-block wave. It is an execution aid, not a promise that later cards will
land unchanged: current HEAD, specifications, tests, and discovered seams win.

## Traffic table

| lane | mission | semantic ownership | dependency / merge order | state |
| --- | --- | --- | --- | --- |
| lead | M1 thematic breaks + Setext headings | central Markdown block precedence; `document` thematic node; HTML leaf rendering | first | integrated on main (PR #10) |
| lead | M2 fenced code blocks | Markdown open-leaf state; shared code-block model; HTML rendering | stacked after M1 | integrated on main (PR #13) |
| conformance worker | Q1 list conformance wall | list fixture pairs and list-only hostile tests; no parser files | independent; merge after M1 only to minimize fixture-index conflict | integrated on main (PR #11) |
| Textile worker | T1 `p.`/break-span repairs + `bq.` | Textile frontend, Textile fixtures/provenance; no Markdown/core model | independent | integrated on main (PR #12) |
| lead | M4 §2.5 entities + HTML blocks types 6/7 | entity table + decode seams; `.html_block` leaf; info/dest/title normalization | after M3 | implemented on main (uncommitted) |
| lead | M5 HTML blocks types 1–5 | per-type terminator end conditions; type 1–6 paragraph interruption | after M4 | implemented on main (uncommitted) |
| lead | M6 full conformance | §4.7 angle-destination separator rule; manifest/pins to 652/652 | after M5 | implemented on main (uncommitted) |
| lead | M7 GFM tables extension | Markdown table open-leaf + header/delimiter/body parsing; `.table` family in model and HTML renderer; docs/TABLES.md contract | after M6 | integrated on main (PR #19) |
| Textile worker | T8 Textile tables | Textile `|a|b|` block rows, cell/row/table modifiers, header-alignment propagation, flat-row rendering; Textile fixtures; no Markdown/core changes | after M7 (reuses the `.table` model family) | integrated on main (PR #20) |
| Textile worker | T9 Textile link aliases | `[alias]url` definition lines + `"text":alias` references via a document-global alias table; Textile fixtures; no Markdown/core changes | after T8 | integrated on main (PR #21) |
| Textile worker | T10 Textile block attributes | `{style}`/`(class#id)`/`[lang]`/alignment/padding on `p.`/`hN.`/`bq.` signatures; block attrs in model + renderer; Textile fixtures; Markdown untouched | after T9 | implemented on main (uncommitted) |

## M1 — Thematic-break / Setext precedence rung

- **Objective:** implement CommonMark §4.1 and §4.3 as one precedence slice.
- **Normative source:** CommonMark 0.31.2 examples 43–61 and 80–106,
  §4.7 definitions, §5 containers, appendix parsing strategy.
- **Dependencies:** landed container stack and paragraph/definition phase split.
- **Seams:** `src/markdown.zig`, `.thematic_break` in `src/document.zig`,
  `src/html.zig`, Markdown fixtures, architecture/model/test docs.
- **Acceptance:** Setext > thematic > list precedence; paragraph interruption;
  quote/list matched-vs-lazy behavior; multiline inline content; definitions
  before heading content; exact spans; both HTML void profiles; terminal
  paragraph backslash; no unexplained normative failures.
- **Tests:** 13 fixture pairs, AST/span unit tests, renderer test, deterministic
  10,000-cycle leaf storm, a 20,000-level thematic near-miss, and full
  suite/section scorecards.
- **Parallelism:** no. The lead owns this sensitive block-parser seam.
- **Integration:** first.
- **State:** integrated on main (PR #10). The canonical scorecard at this
  milestone was 513/652, thematic 18/19, Setext 25/27; the overall scorecard
  reached 546/652 after M2. Remaining focused failures require indented code.

## Q1 — List conformance wall

- **Objective:** turn the landed §5.2/§5.3 list behavior into byte-exact,
  provenance-labeled product tests and add list-specific hostile cases.
- **Normative source:** CommonMark 0.31.2 §§5.2–5.3 examples only.
- **Dependencies:** landed lists; no dependency on M1 semantics.
- **Seams:** `tests/fixtures/markdown/list-*`, fixture index, list-only
  adversarial tests. Parser/model/renderer edits forbidden.
- **Acceptance:** every included expected output is copied from the normative
  corpus and already passes; failures are reported rather than normalized away;
  nesting/marker/indent/ordered-boundary storms complete deterministically.
- **Tests:** 26 normative fixture pairs and named list stress/determinism test.
- **Parallelism:** yes; fixtures-only ownership.
- **Integration:** after M1 to resolve the shared fixture index once.
- **State:** integrated on main (PR #11); rebased onto the M1/M2 fixture index
  during integration.

## T1 — Textile single-period block quotes

- **Objective:** repair `p.` interruption and hard-break spans, then implement
  single-period `bq.` through the shared `.block_quote → .paragraph` IR.
- **Authoritative sources:** Hobix Textile Reference; Movable Type Textile 2
  Syntax; textile-lang.com block-quotation user documentation.
- **Dependencies:** existing shared block-quote model/renderer.
- **Seams:** `src/textile.zig`, Textile fixtures/index, Textile feature matrix
  and clean-room provenance. Markdown/core model/renderer edits forbidden.
- **Acceptance:** signatures interrupt; unmarked lines continue until blank or
  another signature; LF/CRLF/CR spans cover the preceding terminator; content
  spans exclude `bq.`; `bq..`, citations, and empty quotes remain deferred.
- **Tests:** eight fixture pairs, AST/span unit tests, 10,000-signature flood.
- **Parallelism:** yes; Textile-local ownership.
- **Integration:** independent after M1/Q1 fixture-index reconciliation.
- **State:** integrated on main (PR #12).

## M2 — Fenced code blocks

- **Objective:** implement CommonMark §4.5 fenced code as the next leaf block,
  including container composition and info strings.
- **Normative source:** CommonMark 0.31.2 §4.5 examples 119–147, §2.5 entities
  for info-string normalization (entity-dependent examples classified), and
  appendix phase-1 rules.
- **Dependencies:** M1 precedence rung. Requires a normalized `.code_block`
  node with content and optional info-string/language payload.
- **Seams:** lead-owned `document` tag/data contract, Markdown open
  leaf state, HTML `<pre><code>` rendering, fixtures/design docs.
- **Acceptance:** backtick/tilde run rules; closing fence length/indentation;
  unclosed-to-EOF; backticks forbidden in backtick info strings; content
  literal/opaque; matched quote/list behavior; exact spans; long-fence and
  unclosed-fence hostile cases.
- **Tests:** 13 fixture groups, canonical §4.5 wall, containers, CR/LF/CRLF,
  exact IR/rendering, fence-run and unclosed-content storms.
- **Parallelism:** no during core design/implementation; fixtures may be
  prepared independently after the model contract is fixed.
- **Integration:** after M1; before indented code.
- **State:** integrated on main (PR #13). Branch-state measurements: 113/113
  tests, canonical scorecard 546/652 and §4.5 at 28/29. The sole focused
  failure is the four-space-indented-code dependency.

## M3 — Tab-aware indentation and indented code

- **Objective:** implement CommonMark §2.2 tab stops and §4.4 indented code
  without corrupting source spans or container indentation.
- **Normative source:** CommonMark 0.31.2 Tabs examples 1–11, §4.4 examples
  107–118, §5 container indentation rules.
- **Dependencies:** M2 code-block IR. Requires an architectural design for a
  line cursor with virtual columns because partially consumed tabs cannot be
  represented by byte-slice advancement alone.
- **Expected seams:** `source`/Markdown line view, container matching,
  `.code_block`, renderer, all indentation-sensitive fixtures.
- **Acceptance:** four-column tab stops; paragraph non-interruption; blank-line
  retention; container/list code indentation; source spans remain byte-true;
  no quadratic indentation scanning.
- **Tests:** complete Tabs and Indented-code sections, mixed endings, nested
  lists/quotes, long whitespace/tabs.
- **Parallelism:** no until the virtual-column seam is designed by the lead.
- **Integration:** after M2.
- **State:** implemented on main. A `View` wraps each line with a
  tab-expanded column (the reference implementation's partially-consumed-tab
  model): container markers and block starts measure indentation in columns,
  partially consumed tabs stay as the view's first byte, and indented-code
  content strips four columns with the leftover of a straddled tab becoming
  spaces. Canonical scorecard 592/652; Tabs 11/11, Indented code 12/12,
  List items 48/48, Block quotes 25/25, Thematic/ATX/Setext/Fenced 100%.

## M4 — Entity references (§2.5) and HTML blocks types 6/7

- **Objective:** implement CommonMark §2.5 named + numeric character
  references everywhere the spec recognizes them, and the two HTML-block
  start kinds (§4.6 types 6/7) that the entity milestone's example #31 needs.
- **Normative source:** CommonMark 0.31.2 §2.5 examples 25–42, §4.6 examples
  155–178, and the WHATWG entities.json data source the spec names as
  authoritative (an HTML-specification data source, clean-room allowed).
- **Dependencies:** M3 tab/column work (HTML-block indentation ≤3 columns);
  the raw-HTML pass-through policy (docs/RAW-HTML.md); `.code_block` info
  payload (M2) for info-string normalization.
- **Expected seams:** new generated `src/entities.zig` (+ `tools/gen-entities.py`),
  entity-aware text writer in `src/html.zig`, `resolveEntities` in
  `src/markdown.zig`, `.html_block` leaf in `src/document.zig` + renderer,
  manifest/docs.
- **Acceptance:** named/numeric/hex decode with the §2.5 range rules; `;`
  required; recognized in text, destinations/titles, info strings, autolinks,
  and alt flattening but never in code spans/blocks and never as structural
  characters; backslash-escaped `&` never decodes; types 6/7 with blank-line
  end conditions and type-7 paragraph non-interruption.
- **Tests:** entity unit tests (generated with the table), text/rendering
  fixtures, HTML-block fixtures, updated escape/link fixtures, full suite.
- **Parallelism:** no (lead-owned seams: generated data, text writer, block pass).
- **Integration:** after M3.
- **State:** implemented on main (uncommitted). Canonical scorecard
  636/652, 0 regressions: Entities 17/17, HTML blocks 31/44 (types 6/7
  conform; the 13 not-yet examples need types 1–5), backslash escapes and
  links gain the incidental normalization passes. 138/138 tests green.

## M5 — HTML blocks types 1–5

- **Objective:** implement the remaining §4.6 HTML-block start kinds —
  type 1 (`<script|pre|style|textarea`, case-insensitive), type 2 (`<!--`),
  type 3 (`<?`), type 4 (`<!` + ASCII letter), type 5 (`<![CDATA[`) — with
  their per-type matching-terminator end conditions, closing the last
  HTML-block conformance gap.
- **Normative source:** CommonMark 0.31.2 §4.6 examples 155–178 (spec prose
  only; the terminator rules are fully specified there).
- **Dependencies:** M4's `.html_block` open-leaf machinery (start detection,
  container-stripped verbatim accumulation, blank-line end); the §4.6
  interruption rule, which types 1–6 satisfy (type 7 alone cannot interrupt).
- **Expected seams:** `HtmlBlock.block_type` + per-type end-condition scan in
  `src/markdown.zig`, type 1–5 start scanners, paragraph-laziness awareness
  (`isParagraphContinuationText`), manifest/docs.
- **Acceptance:** types 1–5 end at the first line containing their
  terminator (including a terminator on the start line itself, closing the
  block after one line) or a blank line; types 1–6 interrupt paragraphs,
  type 7 does not; content stays verbatim (no entity decode, no emphasis).
- **Tests:** unit tests for each start kind + end condition; fixture pairs
  `html-block-type1`…`type5`, `type1-raw`, `interrupt-types`; full suite.
- **Parallelism:** no (lead-owned seams).
- **Integration:** after M4.
- **State:** implemented on main (uncommitted). Canonical scorecard
  651/652, 0 regressions: HTML blocks 44/44, Lists 26/26 (the two
  `<!-- -->`-in-list examples, spec #308/#309, flip with type-2 support),
  and the sole remaining not-yet example is the §4.7 link-reference-
  definition edge case #201. 139/139 tests green.

## M6 — Full conformance (closing example 201)

- **Objective:** close the last not-yet example — §4.7 example 201,
  `[foo]: <bar>(baz)`. An angle-bracketed destination must be followed by
  spaces/tabs or the end of the line: with `(baz)` directly adjacent, the
  title has no separating whitespace, so the line is not a definition
  ("No further character may occur" after the destination, §4.7).
- **Normative source:** CommonMark 0.31.2 §4.7 example 201 and the
  definition grammar's whitespace-separator rule.
- **Dependencies:** M5's all-seven-HTML-block-types manifest.
- **Expected seams:** the angle-destination branch of
  `tryParseDefinition` (`src/markdown.zig`), manifest/pins, docs.
- **Acceptance:** `[foo]: <bar>(baz)` renders as literal text (`<p>[foo]:
  <bar>(baz)</p>`), not a definition; the bare-destination form (`[foo]:
  /url "title"`) is unaffected; gate reaches 652/652.
- **Tests:** the manifest partition test pins 652 supported / 0 not-yet;
  the whole corpus is the regression wall.
- **Parallelism:** no (lead-owned seams).
- **Integration:** after M5.
- **State:** implemented on main (uncommitted). Canonical scorecard
  **652/652 — full conformance**, 0 not-yet, 0 divergences, 0 regressions.
  140/140 tests green.

## T4 — Textile parity audit: phrase modifiers, links, images, lists

- **Objective:** build the Textile fixture audit (docs/TEXTILE-PARITY.md):
  inventory every implemented Textile feature against the shared document
  model, then close the biggest gaps vs. Textile 2 semantics — the inline
  phrase-modifier family, `"text":url` links, `!url!` images, and `*`/`#`
  lists.
- **Authoritative sources:** Hobix Textile Reference; Movable Type Textile 2
  Syntax (both clean-room allowed); the existing Textile contracts
  (docs/TEXTILE-INLINE-CODE.md).
- **Dependencies:** shared model/renderer; the T2 `@code@` boundary contract
  is reused uniformly for every inline family.
- **Seams:** `src/textile.zig` (inline item scan → LIFO phrase match → emit,
  plus the block-pass list tree), new shared tags `bold`/`italic`/`deleted`/
  `inserted`/`superscript`/`subscript`/`span` in `src/document.zig` and
  `src/html.zig`, Textile fixtures/index, feature matrix, model and parity
  docs. Markdown parser files untouched.
- **Acceptance:** the documented operator set renders to the documented HTML
  (`_x_`→`<em>`, `*x*`→`<strong>`, `**x**`→`<b>`, `__x__`→`<i>`, `-x-`→`<del>`,
  `+x+`→`<ins>`, `^x^`→`<sup>`, `~x~`→`<sub>`, `%x%`→`<span>`); nesting
  `*_way_*`; links with titles and the bracket trick; images with alt/title
  and the `!url!:href` attachment; tight single-line lists with marker-depth
  nesting; every ambiguous shape stays literal and is pinned by a fixture.
- **Tests:** 9 new unit tests (tags/spans, nesting, boundaries, links,
  images, lists, a 10,000-pair phrase storm, a 2,000-deep nesting workload)
  and 15 new Textile fixture pairs, plus shared-model convergence pairs.
- **Parallelism:** yes; Textile-local ownership, Markdown untouched.
- **Integration:** after M6 (the Markdown corpus is untouched, so the
  652/652 gate is unaffected).
- **State:** implemented on main (uncommitted). 148/148 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## M7 — GFM tables extension

- **Objective:** promote the "tables (GFM extension)" row from planned to
  implemented per recorded ambiguity 21 and issue #17: document the chosen
  syntax first, then implement GFM §4.10 pipe tables in the Markdown
  frontend.
- **Normative source:** GFM spec §4.10 (github.github.com/gfm,
  clean-room allowed); recorded ambiguity 21's update points.
- **Dependencies:** shared model/renderer; the phase-1 paragraph open-leaf
  and phase-2 single-line inline seams.
- **Seams:** new `.table`/`.table_row`/`.table_cell` tags in
  `src/document.zig` (alignment on the table, header/alignment on the
  cell), `<table><thead><tbody>` output in `src/html.zig`, the table
  open-leaf + delimiter-row conversion in `src/markdown.zig` (with the
  cell code-span pipe-escape post-fix), docs/TABLES.md, Markdown
  fixtures/index, feature matrix, model, test and ledger docs. Textile and
  the CommonMark corpus untouched.
- **Acceptance:** the normative §4.10 examples byte-for-byte (basic,
  alignment incl. the single-hyphen `:-:`, escaped pipes incl.
  `<code>|</code>`, break-at-blockquote, pipe-less body rows, mismatch
  stays a paragraph, pad/truncate, no-`<tbody>`); containers and
  inline-parsed cells (links/emphasis/code, reference links); non-table
  pipe lines stay paragraphs.
- **Tests:** 2 unit tests (node structure/alignment, escaped pipes +
  mismatch/literal fallbacks), a renderer-only table test, and 11 Markdown
  fixture pairs.
- **Parallelism:** yes; Markdown + model/renderer, Textile untouched.
- **Integration:** after M6 (corpus untouched; the 652/652 gate is
  re-verified).
- **State:** integrated on main (PR #19). 151/151 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T8 — Textile tables

- **Objective:** implement Textile's own `|a|b|` table syntax — the last
  large feature gap the parity audit recorded — converging with the
  `.table`/`.table_row`/`.table_cell` model family M7 introduced.
- **Authoritative sources:** Hobix Textile Reference "Tables" (rendered
  HTML examples); Movable Type Textile 2 Syntax "Tables" (modifier list,
  the `table(fig).` complex example, the header-alignment propagation
  rule, table-level `<`/`>`/`=` float/margin semantics); Textile Markup
  Language Documentation (modifier semantics). All clean-room allowed.
- **Seams:** `src/textile.zig` (table block state, row/signature
  recognition, the modifier scanner, close-time propagation), the model
  (`Attribute` lists on table/row/cell, `colspan`/`rowspan`, `justify`
  alignment, the `sections` flag), `src/html.zig` (attribute emission;
  `sections` selects flat rows vs GFM thead/tbody), Textile
  fixtures/index, feature matrix, parity/model/test/ledger docs. Markdown
  and the CommonMark corpus untouched.
- **Acceptance:** the Hobix table examples byte-for-byte (simple rows,
  header cells, cell attributes incl. `<`/`>`/`=`/`<>`/`^`/`~`, colspan,
  rowspan, cell style, `table{...}.` signature on its own line, row
  attributes); the Textile 2 complex example; header-alignment propagation;
  inline-parsed cells; literal fallbacks (no closing pipe, missing `. `
  terminator, `table. of contents`, unclosed braces); block closing;
  GFM-model structural convergence.
- **Tests:** 8 unit tests (structure/spans/rendering, cell modifiers and
  attrs, propagation + row headers, signature + row modifiers, literal
  fallbacks, block closing, a 20,000-row storm, GFM-model convergence),
  a renderer-only `sections` test, and 13 Textile fixture pairs.
- **Parallelism:** yes; Textile + model/renderer, Markdown untouched.
- **Integration:** after M7 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #20). 159/159 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T9 — Textile link aliases

- **Objective:** implement `[alias]url` definition lines and
  `"text":alias` references — the largest remaining documented Textile
  gap — converging with the Markdown §4.7 definition-table machinery.
- **Authoritative sources:** Hobix Textile Reference "External References:
  Link Aliases" (uses before the definition; the trailing-punctuation
  exclusion); Movable Type Textile 2 Syntax "Links" (definition blocks
  "anywhere within your document", multiple aliases per block). Both
  clean-room allowed.
- **Seams:** `src/textile.zig` (pass-1 alias collection over every line,
  the def-line recognizer, threading the alias table through the inline
  pass, alias lookup in `scanLink` with the href span carried on
  `LinkData`), Textile fixtures/index, feature matrix, parity
  (new §7), test and ledger docs, README. Markdown, model, and renderer
  untouched.
- **Acceptance:** the Hobix example (four references resolve, the def
  line vanishes, trailing `!` excluded); the Textile 2 definition-block
  form; first-definition-wins; case-sensitive exact matching; an
  undefined alias stays a relative URL; aliases resolve in headings,
  lists, and table cells; def lines vanish mid-paragraph without
  splitting it; literal fallback shapes.
- **Tests:** 4 unit tests (document resolution + the Hobix render, shapes
  and precedence, every inline context, a 2,000-definition storm), 4
  Textile fixture pairs, and 2 shared-model convergence pairs
  (`"x":alias` ↔ `[x][a]`, byte-identical).
- **Parallelism:** yes; Textile-local ownership, Markdown untouched.
- **Integration:** after T8 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #21). 163/163 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T10 — Textile block attributes

- **Objective:** implement the block attribute set (`{style}`,
  `(class#id)`, `[lang]`, `< > = <>` alignment, `(`/`)` padding) on `p.`,
  `hN.`, and `bq.` signatures — the last large documented block gap — so
  block signatures carry the modifier machinery the table and alias work
  already built.
- **Authoritative sources:** Hobix Textile Reference "Attributes: Block
  Attributes / Block Alignments" (class, id, class#id, style, lang, the
  four alignments, `(`/`)` indentation, and the combined `h2()>.` /
  `h3()>[no]{color:red}.` heading examples); Movable Type Textile 2
  Syntax "Block Attributes". Both clean-room allowed.
- **Seams:** `src/document.zig` (`.paragraph`/`.block_quote` gain attrs;
  `.heading` becomes `{ level, attrs }`), `src/html.zig` (attrs on the
  three block opens; `clampHeading` reads), `src/textile.zig` (a `.block`
  modifier kind in `scanMods`; `parseBlockSignature`; reworked
  `tryHeading`/`tryParagraphMarker`/`tryBlockQuoteMarker`; `emitHeading`
  carries attrs), Textile fixtures/index, feature matrix, parity (new
  §8), model/test/ledger docs, README. Markdown untouched.
- **Acceptance:** the Hobix §4 examples byte-for-byte (`p(example1).`,
  `p(#big-red).`, `p(example1#big-red2).`, `p{color:blue;margin:30px}.`
  with `; ` normalization, `p[fr].`, the four alignments, `p(.`/`p((.`/
  `p))).` padding, `h2()>.`, `h3()>[no]{color:red}.`); `bq` attrs land
  on the `<blockquote>` with the inner paragraph unmarked; malformed
  signatures (`p(foo not closed`, `p>.no-space`, `p..`, `bq..`, `bq:`,
  `h1x.`) stay literal; the 652/652 gate is untouched.
- **Tests:** 4 unit tests (paragraph attrs incl. `; ` normalization and
  id-only, alignment/padding/heading combinations, blockquote placement,
  literal fallbacks), 5 Textile fixture pairs (Hobix battery, combined
  forms, bq attrs, heading attrs, literal).
- **Parallelism:** yes; Textile + model/renderer, Markdown untouched.
- **Integration:** after T9 (the 652/652 gate is re-verified).
- **State:** implemented on main (uncommitted). 167/167 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## C1 — Classified conformance expectations

- **Objective:** bind the conformance harness to the exact 0.31.2 corpus and
  classify each example as supported, not-yet-implemented, or a named Oliver
  divergence.
- **Normative source:** official CommonMark 0.31.2 `spec.txt` and its license.
- **Dependencies:** none; keep parser semantics out of scope.
- **Expected seams:** `tools/spec_conformance.zig`, versioned expectation data,
  build wiring, harness self-tests, test documentation.
- **Acceptance:** corpus digest/count check; complete/non-overlapping statuses;
  supported-regression and divergence-drift gates; malformed corpus rejection;
  unexpected passes surfaced; tool unit tests run under `zig build test`.
- **Tests:** synthetic extraction/tab/CRLF/malformed/status/exit fixtures.
- **Parallelism:** yes, tooling-only ownership.
- **Integration:** any time after current PR stack; avoid simultaneous edits to
  global test-count prose.
- **State:** integrated on main (PR #15); the manifest was 592 supported, 60
  not-yet, and 0 named divergences after the tab-stop/indented-code milestone
  (the former ATX trailing-backslash divergence now conforms). The manifest is
  a living artifact — M4 moved it to 636 supported / 16 not-yet / 0 divergences,
  M5 to 651 supported / 1 not-yet / 0 divergences, and M6 to 652 supported /
  0 not-yet / 0 divergences (full conformance)
  (see the M4/M5/M6 cards below).

## Deferred architectural cards

- **B1 HTML blocks (§4.6) types 1–5:** landed as M5 — comments, PIs,
  declarations, CDATA, and the `<script|pre|style|textarea` element set now
  end at their matching terminators; the §4.6 family is 44/44
  (docs/HTML-BLOCKS.md).
- **T2 Textile `@code@`:** integrated on main (PR #14); Textile-local inline
  scanner using the existing `.code_span` IR, with opacity and delimiter-storm
  tests (docs/TEXTILE-INLINE-CODE.md).
- **T3 Textile emphasis/strong:** follows T2; same-line boundary/nesting policy
  must be pinned from authoritative Textile documentation first.
