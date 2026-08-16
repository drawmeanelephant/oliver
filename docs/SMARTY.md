---
published_at: 2026-08-16T00:00:00Z
summary: Pre-implementation contract for the opt-in smartypants typography pass in the Markdown frontend, one shared implementation with Textile.
---

# Smart typography (`smartypants`) — contract

**Status:** planned — contract only; nothing is parsed or rendered yet.
Implementation is tracked as issue #67 (milestone v1.0, "The Goodest
Boy"), ledger card E3, and the "smart typography (extension)" row of the
feature matrix (docs/FEATURE-MATRIX.md).  \
**Modules:** new shared `src/typography.zig` (extracted from
`src/textile.zig`), `src/markdown.zig` (parse), `src/textile.zig`
(caller)  \
**Options (proposed):** `markdown.Options.smartypants: bool = false`

Textile already implements the legendary typotastic rules
(docs/TEXTILE-PARITY.md §13 — T15). This contract brings those **exact**
transform passes to CommonMark as an opt-in pipeline, as **one shared
implementation with two callers**: the machinery is extracted from
`src/textile.zig` (`replaceChars`, `hasCharMacroTrigger`, the
quote-direction helpers, the paren-symbol table) into a shared module,
Textile becomes a caller whose output stays **byte-identical** (the
Textile fixture wall is the regression net), and Markdown calls the same
pass on plain text when the option is on. No new upstream material is
consulted; the extraction and chosen scope are recorded in a new
clean-room session.

## 1. The replacement set (the Textile passes, verbatim)

| source | result | rule |
| --- | --- | --- |
| `"` `'` | curly quotes | direction by the surrounding source bytes: opening after start-of-content, whitespace, or `(`/`[`/`{`; otherwise closing; apostrophes by position |
| `--` | em dash (`—`) | a run of two hyphens |
| ` - ` (space-surrounded) | en dash (`–`) | single hyphen between spaces |
| `...` | ellipsis (`…`) | a run of three periods |
| digit-adjacent `x` | dimension sign (`×`) | `2 x 4`, `2x4` |
| `(c)` `(r)` `(tm)` | © ® ™ | case-insensitive |
| `(1/4)` `(1/2)` `(3/4)` | ¼ ½ ¾ | |
| `(o)` | ° | |
| `(+/-)` | ± | |
| `---`, `....` | `—` + `-`, `…` + `.` | runs of 3+ replaced left-to-right |

The Textile `{...}` character-macro table (T20) is **Textile-only**:
braces in CommonMark are ordinary text, and smartypants never enables
the macro table (pinned).

## 2. Where the pass applies

- Applied to plain `.text` nodes in every Markdown inline scope:
  paragraphs, ATX/Setext headings, list items, table cells (GFM), and
  link **display text** (matching Textile, which replaces inside link
  text).
- **Exempt (verbatim):** code spans, code blocks (fenced and indented),
  autolink labels, link destinations and titles, image src/alt/title,
  raw HTML and inline HTML, and HTML-looking `<...>` regions — the same
  exemption set Textile pins today (docs/TEXTILE-PARITY.md §13).
- Image alt strings are exempt: the description's text nodes do not pass
  through the typography pass when they flatten into `alt`.

## 3. CommonMark-specific pins

- **Link titles are exempt by construction:** title parsing runs before
  the text pass (`[x](url "title")`), so the quoted title is never
  curled.
- **Escaped characters stay straight:** a backslash-escaped `\"` or `\'`
  renders the literal straight character (the escape's output is literal
  punctuation, not typography) — the CommonMark parallel of Textile's
  `==...==` exemption.
- **No phrase interplay:** CommonMark has no `--smaller--` big/small
  phrase and no phrase operators, so `--` and `-` runs need no
  phrase-scanner coordination — a `--` always em-dashes under smartypants.
- **Borrow-or-copy contract:** untouched text borrows the source slice;
  only spans containing a replacement allocate arena copies — identical
  to the current `hasCharMacroTrigger`-first fast path.
- **Determinism:** the pass is a pure function of the source bytes and
  position; no hidden state.

## 4. Rendering and XHTML

- No renderer changes: replaced payloads flow through the existing text
  writer (the renderer already escapes and emits payloads).
- No new elements; curly quotes, dashes, and symbols are valid in both
  output profiles. The XHTML well-formedness gate is unaffected.

## 5. Interaction with the other planned extensions

- `wikilinks`: wikilink targets/labels are exempt (plain-text payloads,
  not re-scanned) — matching the exemption set.
- `callouts`: the title and body are ordinary inline scopes; the pass
  applies there like anywhere else.
- `front matter`: stripped before the body parses; never processed.

## 6. Acceptance and fixtures

- `"Hello," -- she said...` → `“Hello,” — she said…` (byte-pinned);
  `2 x 4` → `2 × 4`; `(c)` → ©; apostrophes by position.
- Exemptions pinned: `` `code "quotes"` ``, fenced code, autolinks, raw
  HTML, link destinations/titles, image src/alt/title, escaped `\"`.
- Literal fallbacks pinned: `---` → `—` + `-`, `....`, `(1/3)`,
  letter-touching hyphens (no en dash in `foo-bar`), plain `x`.
- Textile fixtures byte-identical before/after the extraction refactor
  (the wall is the regression net).
- Off by default: quotes/dashes stay literal — 652/652 + full suite
  green.

## 7. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration). The fixture wall lives at
`tests/fixtures/markdown/smartypants-*`.
