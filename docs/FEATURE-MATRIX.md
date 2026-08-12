# Oliver Feature Matrix

Status legend:

- **implemented** — in the vertical slice, tested by fixtures/unit tests
- **planned** — designed, next milestones, behavior chosen from specs
- **deferred** — documented, deliberately not scheduled yet

The matrix is the record of *chosen* behavior. When documentation sources
disagree, the disagreement and Oliver's choice are recorded here.

---

# Markdown

Reference: CommonMark specification 0.31.2
(<https://spec.commonmark.org/0.31.2/spec.txt>). Oliver does not claim
conformance yet; the slice implements a subset deliberately and documents
divergences.

## Blocks

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| paragraphs | implemented | Consecutive non-blank lines; blank = only spaces/tabs (§3 "blank line"). §4.8: raw content is the concatenated lines with initial and final spaces/tabs removed. Oliver (slice, chosen): leading spaces/tabs are skipped on every line; trailing spaces/tabs are consumed by the break analysis (never emitted). Lines join with soft breaks unless the line ends in a hard break (§6.7). |
| ATX headings | implemented | §4.2. Opening 1–6 unescaped `#` preceded by ≤3 spaces, followed by space/tab or EOL. Content stripped of leading/trailing spaces/tabs. Optional closing run of *unescaped* `#`s (preceded by space/tab or comprising the whole content; followed only by spaces/tabs) stripped together with its preceding whitespace — backslash-escaped `#`s do not count in the closing sequence (§4.2 example 76). A single pass: in `# foo # #`, only the final `#` is a closing sequence (content `foo #`). `####### foo` is a paragraph. A trailing unescaped backslash in ATX content is a hard break inside the heading (chosen, low confidence; recorded below). |
| Setext headings | planned | §4.3. Needs line lookahead (underline = `=`/`-` run) and the documented precedence dance with thematic breaks and paragraphs. Cannot interrupt a paragraph. |
| thematic breaks | planned | §4.1. `-`/`_`/`*` runs, ≥3, up to 3-space indent, optional interleaved/trailing spaces. Takes precedence over list items; yields to setext underlines. |
| block quotes | implemented | §5.1, per docs/BLOCKS-PARSING.md: a `>` marker (≤3 leading spaces, one following space consumed) opens a container; markers nest (`> > foo`); laziness lets paragraph-continuation lines omit markers (`> foo` then `bar`), and omitting any number of initial `>`s is allowed on nested continuation lines; a truly blank line separates quotes while a marker-blank line (`>`) keeps one quote open; quotes can interrupt paragraphs; `>` alone is an empty quote. The container stack (spec appendix "A parsing strategy") is shared with list items and lists. **Scorecard: 18/25** (§5.1) — remaining failures depend on leaf blocks still pending. |
| unordered lists | implemented | §5.2, §5.3. Bullet `-`/`+`/`*`; same-marker list merging; tight vs loose; nested via content indentation; `<ul>`/`<li>` rendering. |
| ordered lists | implemented | §5.2, §5.3. `1.`/`)` markers, nine-digit start numbers, same-delimiter merging, and `<ol start="…">` rendering. |
| fenced code blocks | planned | §4.5. Backtick/tilde fences, info strings, closing-fence rules, unclosed-to-EOF. |
| indented code blocks | planned | §4.4. 4-space/tab indentation; cannot interrupt paragraphs. |
| HTML blocks | planned | §4.6. Seven start/end-condition kinds. Oliver must first decide raw-HTML policy (pass-through vs escaped vs rejected) — a renderer/model question, not just a parser question. |
| tables (GFM extension) | planned | Not part of CommonMark. Oliver will define tables as an explicit extension with its own chosen syntax (GFM-style `|` rows + delimiter row), documented before implementation. |
| link reference definitions | implemented | §4.7: `[label]: destination ["title"]` collected during the block pass, before any inline parsing (a use may precede its definition). Extracted at paragraph close: the first line must be `[` + label + `]` + optional spaces/tabs + destination; an optional title may follow on the same line (separated by spaces/tabs) or on the next line; nothing else may follow the title on its line; indentation beyond 3 spaces cannot start a definition. First definition wins per label; labels are case-folded (Unicode full case fold, §6.3) with internal whitespace collapsed to a single space; an unclosed `[` cannot be a definition. Paragraphs consisting solely of definitions disappear from output; a definition may sit inside a paragraph of other content (the surrounding paragraph keeps its own inline pass). |
| blank lines | implemented | §3; whitespace-only lines separate blocks and are never part of content. |

## Inlines

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| plain text | implemented | Text nodes are slices of the source. Rendering escapes `& < > "` and replaces NUL with U+FFFD (see docs/ARCHITECTURE.md). |
| soft breaks | implemented | Newline inside a paragraph → `soft_break` node → `\n` in HTML (CommonMark default, §6.8). A preceding single trailing space is consumed, not emitted. |
| hard breaks | implemented | §2.4/§6.7: two or more trailing ASCII spaces (tabs in the trailing run do not trigger a break) or an unescaped backslash as the final character → `hard_break` → `<br />`. The trailing whitespace run (and a hard-break backslash) is consumed and never emitted. A single trailing space yields a soft break; the run is still consumed. |
| backslash escapes | implemented | §2.4: `\` + any ASCII punctuation escapes it (produces that character literally); backslashes before other characters are literal; `\\` → literal `\` (escape-aware, example 15). Escapes are recognized in ATX closing-sequence detection (§4.2 example 76) and in end-of-line hard-break analysis (`foo\\` is a literal backslash + soft break). Each escape splits the text into adjacent text nodes with exact source spans; contiguous spans merge into one text node (§6.2 milestone). |
| entities | deferred | §2.3: named + numeric references; entity table is large (HTML5 entities.json) — a dedicated milestone with a compact lookup strategy. |
| emphasis / strong | implemented | §6.2, full rule set (rules 1–12) with the scan → match → emit algorithm in docs/INLINE-PARSING.md: per-run flanking classification, a delimiter stack with `openers_bottom` pruning (amortized linear), the mod-3 rule, strong-before-emphasis, and front/back run consumption for intraword runs that act as both closer and opener. Unicode whitespace/punctuation classification comes from generated tables (src/unicode.zig, Unicode 13.0 categories Zs / P+S per §2.1). Adjacent text nodes merge when their spans are contiguous (normalized model). Verified against spec examples 384–418 including `***foo** bar*`, `*****Hello*world****`, `foo_bar_baz`, `5__6__78`, `пристаням__стремятся__`. |
| code spans | implemented | §6.6: backtick-string discovery runs ahead of delimiter matching; an opener closes at the next backtick string of equal length (opening 2 vs closing 1 does not match); unmatched backticks stay literal. Content is opaque to delimiters and backslash escapes are inert inside; line endings become spaces; one ASCII space is stripped from each end when the content begins and ends with space but is not all spaces (tabs are not stripped, spec 344's note); the closer scan ignores backslash escapes (spec 340). `code_span` is a leaf inline with arena-owned normalized content; the node span covers the whole construct including backticks. Verified against spec examples 333–348. |
| links | implemented | §6.6 (inline links + reference forms): link-bracket discovery runs ahead of delimiter matching (brackets bind more tightly than emphasis; `*[foo*](/uri)` is a link), and code spans bind more tightly than brackets. A `]` whose nearest `[` is followed by a valid `(...)` forms an inline link; otherwise the full `[text][label]`, collapsed `[text][]`, and shortcut `[text]` reference forms are tried against the collected definitions (§4.7), in that order; a `(` after the `]` that fails to parse as an inline destination does *not* block the shortcut form (spec example 561), and reference forms cannot contain other reference links in their labels. Brackets that never resolve stay literal. Inline destination/title syntax per spec: `<...>` or bare destinations (balanced/escaped parens only), `"`/`'`/`(...)` titles, components separated by spaces/tabs/up to one line ending, destinations cannot contain line endings, titles may. A valid link kills every earlier `[` (links cannot contain links, innermost wins); link text is matched as a fresh inline scope. Destinations and titles resolve backslash escapes into arena-owned payloads (`data.link`); href percent-encoding is a renderer policy (see docs/ARCHITECTURE.md). **Chosen behaviors/divergences:** a paren-title closes at the first unescaped `)`; an unescaped `<` inside an angle destination fails the link; DoS guards — paren depth capped at 32 (spec-sanctioned) and component scans capped at 2048 bytes; `&entity;` in destinations/titles stays literal (entities deferred). Verified against spec examples 482–536 (inline subset) plus the §6.6 reference-link examples. |
| images | implemented | §6.7 (inline images), see docs/IMAGES-PARSING.md. `![` (unescaped `!` + `[`) is its own opener on the same discovery stack as links; an image description may contain links and images, so only a formed *link* inactivates earlier `[` openers — never `![` (the spec appendix's active/inactive rule, implemented as an O(1) monotone check). The description is matched as a fresh inline scope and flattened to the arena-owned `alt` string ("only the plain string content" — an autolink in the description contributes its raw label, `![<http://x>](img)` → `alt="http://x"`); `.image` is a leaf inline (`data.image = { src, alt, title }`). `<img src alt title>` renders as a void element under `void_trailing_slash`; `src` uses the link `href` percent-encoding policy; `alt` is always emitted (possibly empty) and `title` only when present, both HTML-escaped like text; attribute order is fixed `src`, `alt`, `title`. Destinations/titles parse identically to links and share the §6.6 DoS guards (paren depth 32, scan cap 2048). **Reference forms implemented:** `![alt][label]`, `![alt][]`, and `![alt]` resolve through the §4.7 definition table with the same full→collapsed→shortcut ordering as reference links (docs/REFERENCE-IMAGES.md); the description flattens to `alt` identically, and a formed reference image inactivates nothing (same monotone rule). Verified byte-for-byte against spec examples 572, 574, 575, 578–581, the literal forms of 592–593, and the §6.4 reference-image examples 582–591. |
| autolinks | implemented | §6.8, see docs/AUTOLINKS.md. A `<` is recognized ahead of link/image bracket parsing (brackets and code spans do not intercept it) when it starts a URI autolink (scheme 2–32 chars, then `:`, then content up to the first `>`; content forbids ASCII control, space, and `<`) or an email autolink (the non-normative HTML5 email regex, anchored: local part + `@` + dot-separated labels of at most 63 chars, each alphanumeric-bounded and ending alphanumeric). URI content may contain `\`, `]`, and `(` freely — those are *not* escapes or link syntax inside an autolink (spec example 526: `](uri)` lands in the href). Emits one `.autolink` leaf (`data.autolink = { href, label }`); the label is the raw content verbatim (backslash escapes are inert inside autolinks — the payload is *not* escape-resolved, unlike `data.link`), and the href is the content for URIs or `mailto:` + content for emails. Renders `<a href="...">label</a>`: the href is percent-encoded under the link policy (`&` → `&amp;`, `\` → `%5C`, `[` → `%5B`), the label is HTML-escaped like text. Recognition is linear: every failed scan is bounded by the next `<`/space (forbidden in content), and the email domain run is capped at 62 chars. Verified byte-for-byte against all 19 §6.8 spec examples 567–585. |
| inline HTML | implemented | §6.6: open/closing tags, comments, processing instructions, declarations, and CDATA sections are discovered across paragraph lines, kept opaque to delimiters/links, and rendered verbatim from their source spans. Invalid shapes remain escaped text; custom tag names are allowed. The renderer policy for this slice is pass-through; HTML blocks (§4.6) and configurable escaped/rejected modes remain planned. See docs/RAW-HTML.md. |
| Unicode | partial | Bytes pass through untouched; no encoding assumptions beyond byte slicing. Text escaping operates on bytes; multibyte UTF-8 is unaffected. |
| NUL | decided | Kept in the model (source bytes preserved), replaced with U+FFFD at render time. CommonMark replaces at parse time; divergence recorded deliberately because Oliver preserves source fidelity in spans. |

## Inline parsing (origin, not imitation)

Emphasis/strong is implemented with an explicit delimiter algorithm derived
from the spec's own rules (§6.2) — see docs/INLINE-PARSING.md, which was
written as the design contract *before* any code: scan delimiter runs and
classify flanking, match on a delimiter stack with the mod-3 rulebook and
`openers_bottom` pruning, then emit emphasis/strong pairs with exact source
spans. Malformed delimiter input degrades to literal text predictably.

Links, code spans, raw HTML, and escapes are recognized by scanning *before*
delimiter matching in a documented precedence order (code span markers are
opaque to delimiters; raw HTML is opaque to delimiters and link brackets; link
brackets are opaque to emphasis), exactly as §6.1's precedence requires. The
code-span precedence landed with the
code-span milestone; the link precedence (a second discovery pass with its
own bracket stack) landed with the link milestone; images (`![` openers,
with the appendix's active/inactive bracket semantics) extended that same
pass with the images milestone (docs/IMAGES-PARSING.md, written as the
design contract *before* the image code). Raw HTML uses a whole-paragraph
discovery pass merged with code spans so the first construct at the earliest
source position wins.

---

# Textile

Sources: Hobix "Textile Reference" (Dean Allen,
<https://hobix.com/textile>) and Movable Type "Textile 2 Syntax" (Brad
Choate, <https://movabletype.org/documentation/author/textile-2-syntax.html>).
These are user-facing syntax documents, not parser code.

Textile is a first-class dialect. Where the two references disagree, Oliver
records the disagreement and chooses one behavior (see "Recorded ambiguities"
below).

## Blocks

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| paragraphs | implemented | Blank-line separated (`p.` default signature, both references). Bare text or `p.`-prefixed; a `p.` marker must be followed by a space/tab to count. Content is preserved verbatim (only the marker's separator whitespace is consumed). |
| headings | implemented | `h1.`–`h6.` markers, each followed by a space/tab. `h0.`/`h7.`+ are not headings (paragraph text). `hN.` at end of line (no space) is not a heading. Content after the marker is verbatim. |
| line breaks | implemented | Newline inside a paragraph → hard break → `<br />`. Textile 2 is explicit ("newlines for XHTML content receive a `<br />` tag at the end of the line, with the exception of the last line in the paragraph"); Hobix prose agrees ("Line breaks are converted to HTML breaks") though its rendered example shows a plain newline — recorded below. |
| block quotes | planned | `bq.` signature; Textile 2: enclosed in `<blockquote>` with `<p>` inside. |
| pre/code | planned | `pre.` and `bc.` (block code, which also escapes `<`/`>`). |
| lists | planned | `*` unordered, `#` ordered; nesting by repeating the marker (`**` = nested). Styling markers (`(class#id)* one` vs `*(class#id) one`) from Textile 2. |
| tables | planned | `|a|b|c|` rows; `|_. header|`; cell modifiers (`{style}`, `(class)`, alignment, `\2` colspan, `/3` rowspan); table/row attributes. |
| footnotes | planned | `fn1.` blocks and `[1]` references. |
| escaping blocks | planned | `==` delimited regions and `notextile.` (raw) — Textile 2 documents `==`; Oliver will also accept `notextile.` where documented. |
| block attributes | planned | `{style}`, `[lang]`, `(class)`, `(#id)`, `(class#id)`, alignment `> < = <>`, padding `(`/`)` between signature and period: `h2()>. Bingo.` (Hobix). |
| extended blocks | planned | `sig..` keeps a signature active across blank lines (Textile 2). |
| definition lists | deferred | `dl.` signature (Textile 2). |
| `clear` signature | deferred | Textile 2. |

## Inlines

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| plain text | implemented | Verbatim bytes; escaped at render like Markdown (shared renderer). |
| emphasis `_x_` | planned | → `<em>`. Both references agree. |
| strong `*x*` | planned | → `<strong>`. Both references agree. |
| bold `**x**` / italic `__x__` | planned | → `<b>` / `<i>`. Both references agree (Hobix: "doubling the underscores or asterisks"). |
| deleted `-x-` / inserted `+x+` | planned | → `<del>` / `<ins>`. Both references agree. |
| superscript `^x^` / subscript `~x~` | planned | → `<sup>` / `<sub>`. Both references agree. |
| code `@x@` | planned | → `<code>`; `<`/`>` escaped inside. Both references agree. |
| citation `??x??` | planned | → `<cite>`. Hobix only. |
| span `%x%` | planned | → `<span>` (with attributes). Both references agree. |
| big `++x++` / small `--x--` | deferred | Textile 2 only; Hobix does not document them. Oliver will not implement until the inline milestone and will record the choice. |
| links | planned | `"text":url`, optional `(title)` inside the quotes, aliases `[alias]url` + `"text":alias`. Both references agree on the core form. |
| images | planned | `!url!`, alt `(alt)`, size modifiers, link attachment `!url!:href`, alignment/attribute modifiers. Both references agree on core; Textile 2 adds sizing syntax. |
| acronyms | deferred | `CSS(Cascading Style Sheets)` → `<acronym title=...>`. Hobix only. |
| escaping | planned | `==...==` inline region (Textile 2). Backslash escaping varies by version and is unresolved in the references; Oliver will choose one documented form when implementing. |
| character replacements | deferred | Curly quotes, `--`→em-dash, `...`→ellipsis, `(c)`/`(r)`/`(tm)`, Textile 2 macros. Oliver deliberately defers all implicit typography: implicit text transformation is the kind of magic a library should make explicit, and it is not needed by the migration consumers. |
| whitespace sensitivity | planned | Textile 2: inline operators need whitespace before/after to be recognized; brackets/braces can force recognition. Will be part of the inline milestone. |

## Recorded ambiguities and chosen behaviors

1. **Textile line breaks.** Hobix prose says newlines become `<br />` but its
   rendered example shows a plain newline; Textile 2 explicitly says `<br />`
   (except the last line). **Oliver: `<br />` for every internal newline.**
2. **Block interruption without a blank line.** CommonMark explicitly allows
   ATX headings to interrupt paragraphs; neither Textile reference addresses
   marker lines directly after text. **Oliver: Textile marker lines (`hN.`,
   `p.`) always start a new block, even without a preceding blank line.**
3. **Marker whitespace.** Textile 2: signatures "end with a period and be
   followed with a space"; a third-party note (Mylyn/WikiText docs) says a
   line is only a heading if `hN.` is immediately followed by a space.
   **Oliver: the marker must be followed by a space or tab; all following
   whitespace is consumed as separator.**
4. **Paragraph whitespace.** **Oliver: Textile paragraph content is preserved
   verbatim (only marker separator whitespace is consumed).** Markdown
   paragraphs are trimmed per line. The dialects genuinely differ; the model
   represents the resulting text identically.
5. **Inline modifier sets.** Hobix and Textile 2 disagree on the full inline
   set (`++`/`--` exist only in Textile 2). **Oliver implements each feature
   once, from the behavior the majority of references support, and documents
   the choice in this matrix.**
6. **Markdown ATX closing sequences.** `# foo # #` — the spec says a closing
   sequence is a trailing run of `#`s preceded by spaces/tabs. **Oliver
   applies a single pass: only the final run is a closing sequence, so the
   content is `foo #`.**
7. **Markdown tabs.** The spec expands tabs to 4-space tab stops where
   whitespace defines block structure. **Oliver (slice): a tab in leading
   indentation disqualifies a line from being an ATX heading; full tab-stop
   handling is deferred. Tabs after the opening `#` are ordinary separator
   whitespace (matches the spec's `#→Foo` example).**8. **Markdown paragraph whitespace.** §4.8: "The paragraph's raw content is formed by concatenating the lines and removing initial and final spaces or tabs." Oliver (slice, chosen): leading spaces/tabs are skipped on every line; trailing whitespace is governed by the hard-break rule (two+ spaces → hard break, else soft break; the run is always consumed). Whether CommonMark preserves *interior* leading whitespace on continuation lines in its exact output is an open question that will be settled against the §4.8 example set when indented code blocks land (it cannot matter to block structure until §4.4 exists).
9. **NUL replacement timing.** CommonMark mandates parse-time NUL → U+FFFD.
   **Oliver preserves NUL in the model and replaces at render time** so spans
   always reflect source bytes; output is identical.
10. **ATX trailing backslash.** A trailing unescaped backslash in ATX content
    is a hard line break inside the heading (`# foo\` → `<h1>foo<br />\n</h1>`),
    chosen by applying §2.4's hard-break rule to inline content generally.
    Setext headings explicitly *exclude* this (example 90), so the two heading
    forms genuinely differ; **Oliver implements the hard break for ATX** and
    will verify against the spec corpus during the conformance phase.
11. **Trailing tabs and hard breaks.** §6.7 requires "two or more spaces";
    Oliver counts only ASCII spaces in the trailing run (a tab does not
    trigger a hard break, but the whole run is consumed).
12. **Alt flattening of breaks and code spans.** §6.7 says only the plain
    string content of an image description is used, with no spec example
    for breaks or code spans inside a description. **Oliver: soft and hard
    breaks flatten to `\n`** (a break's plain string content is the line
    ending; the hard-break marker is consumed as usual) **and code spans
    flatten to their §6.1-normalized content.** Both pinned by fixtures
    (`image-alt-breaks`, `image-alt-code`); see docs/IMAGES-PARSING.md
    §3/§8.
13. **Image section numbering.** The repo cites images as §6.7 (the
    convention the link milestone established); the numbered 0.31.2 HTML
    numbers the Images section §6.4. **Oliver keeps the repo convention**
    and records the discrepancy in docs/IMAGES-PARSING.md.
14. **Inactive `[` openers are kept, not cleared.** A formed link marks
    every earlier `[` inactive per the spec appendix, and an inactive `[`
    still intercepts a later `]` (it must not reach a `![` below it).
    Oliver implements this with a monotone O(1) check instead of
    re-marking, so the shape stays linear (fixture
    `image-inactive-bracket`; docs/IMAGES-PARSING.md §2).
15. **Reference-style images share the link reference machinery.** The
    appendix's *look for link or image* procedure is uniform for links
    and images, so `![alt][label]`/`![alt][]`/`![alt]` resolve through
    the same §4.7 definition table, label normalization (Unicode case
    fold + whitespace collapse), first-wins, and full→collapsed→shortcut
    ordering as reference links (docs/REFERENCE-IMAGES.md). A formed
    reference image inactivates nothing — the inactive rule keys on
    formed *links* only, matching the inline-image behavior. The
    description's bracket text is the collapsed/shortcut label; matching
    is on the raw bracket text (normalized), not the parsed description
    (`![*foo*][]` matches a definition labeled `*foo*` while the alt
    flattens to `foo`).
