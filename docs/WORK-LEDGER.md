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
- **State:** M2 dependency cleared; the virtual-column/tab design is the next
  lead-owned architectural decision.

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
- **State:** integrated on main (PR #15); the manifest is 546 supported, 106
  not-yet, and 0 named divergences (the former ATX trailing-backslash
  divergence now conforms).

## Deferred architectural cards

- **E1 entities (§2.5):** blocked on a normalized owned-text decision. Current
  `Data.text` must borrow a contiguous source slice; decoded entities cannot
  satisfy that invariant, and renderer-side Markdown parsing is forbidden.
- **B1 HTML blocks (§4.6):** blocked on an explicit block raw-HTML policy and
  profile contract; seven start/end kinds then become implementable.
- **T2 Textile `@code@`:** integrated on main (PR #14); Textile-local inline
  scanner using the existing `.code_span` IR, with opacity and delimiter-storm
  tests (docs/TEXTILE-INLINE-CODE.md).
- **T3 Textile emphasis/strong:** follows T2; same-line boundary/nesting policy
  must be pinned from authoritative Textile documentation first.
