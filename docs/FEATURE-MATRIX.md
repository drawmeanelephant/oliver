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
| ATX headings | implemented | §4.2. Opening 1–6 unescaped `#` preceded by ≤3 spaces, followed by space/tab or EOL. Content stripped of leading/trailing spaces/tabs. Optional closing run of *unescaped* `#`s (preceded by space/tab or comprising the whole content; followed only by spaces/tabs) stripped together with its preceding whitespace — backslash-escaped `#`s do not count in the closing sequence (§4.2 example 76). A single pass: in `# foo # #`, only the final `#` is a closing sequence (content `foo #`). `####### foo` is a paragraph. A terminal backslash stays literal because hard breaks do not occur at the end of a block (example 646). |
| Setext headings | implemented | §4.3, per docs/LEAF-BLOCKS.md. One or more `=`/`-` underline bytes with ≤3 leading spaces and trailing spaces/tabs transforms an eligible open paragraph; `=` → h1, `-` → h2. Content may span lines and is parsed as inlines; the final content line cannot create a hard break merely because the excluded underline follows. Leading link-reference definitions are registered but do not become heading content, and definitions alone are not an eligible heading. A Setext underline takes precedence over a dash thematic break, including one- and two-dash underlines that could otherwise become empty list items. It cannot be a lazy container continuation. **Scorecard: 27/27**. |
| thematic breaks | implemented | §4.1, per docs/LEAF-BLOCKS.md. Three or more matching `-`/`_`/`*` bytes, ≤3-column indent, with optional interleaved/trailing spaces or tabs; no other bytes permitted. Interrupts paragraphs and lazy container continuation, takes precedence over list items, and yields to an eligible Setext underline. Emits semantic `.thematic_break`; HTML uses the configured void-element style. **Scorecard: 19/19**. |
| block quotes | implemented | §5.1, per docs/BLOCKS-PARSING.md: a `>` marker (≤3 columns of indentation, one following column consumed — which may be a partially consumed tab) opens a container; markers nest (`> > foo`); laziness lets paragraph-continuation lines omit markers (`> foo` then `bar`), and omitting any number of initial `>`s is allowed on nested continuation lines; a truly blank line separates quotes while a marker-blank line (`>`) keeps one quote open; quotes can interrupt paragraphs; `>` alone is an empty quote. The container stack (spec appendix "A parsing strategy") is shared with list items and lists. **Scorecard: 25/25** (§5.1). |
| unordered lists | implemented | §5.2, §5.3. Bullet `-`/`+`/`*`; same-marker list merging; tight vs loose; nesting via content indentation; `<ul>`/`<li>` rendering. Content indentation and the whitespace after the marker are measured in columns, so tabs work as marker/indent whitespace (§2.1 Tabs examples 4, 5, 7, 9); five or more columns of whitespace after the marker makes the item's first block an indented code block (rule 2). |
| ordered lists | implemented | §5.2, §5.3. `1.`/`)` markers, nine-digit start numbers, same-delimiter merging, and `<ol start="…">` rendering. |
| fenced code blocks | implemented | §4.5, per docs/FENCED-CODE.md. Backtick or tilde opener of length ≥3 with ≤3 leading columns; same-marker closer at least as long, ≤3-column indent, trailing spaces/tabs only. Backtick info strings reject backticks; the complete trimmed info string resolves §2.4 backslash escapes and §2.5 entities, is retained, and its first word becomes an escaped `language-…` class. Content is literal, removes up to the opener indentation, normalizes every content line ending to `\n`, and closes without backtracking at the containing block/document end. Emits arena-owned `.code_block { content, info }` and deterministic `<pre><code>`. **Scorecard: 29/29**. |
| indented code blocks | implemented | §4.4. One or more chunks of lines each indented ≥4 columns (tabs expand to four-column tab stops), separated by blank lines. Cannot interrupt a paragraph; ends at the first line with <4 columns of indentation, so a paragraph may follow immediately. Content is the literal bytes minus four columns of indentation — a tab straddling the boundary leaves its remaining columns as spaces — with blank lines between chunks retained, trailing blank lines dropped, and one final newline. List and quote composition follows the container stack. Emits arena-owned `.code_block { content, info = null }`. **Scorecard: 12/12**. |
| HTML blocks | implemented | §4.6, all seven types, per docs/HTML-BLOCKS.md. Type 1 (`<script|pre|style|textarea`, case-insensitive), type 2 (`<!--`), type 3 (`<?`), type 4 (`<!` + letter), type 5 (`<![CDATA[`) end at their matching terminator on the line (`</script>` etc., `-->`, `?>`, `>`, `]]>`) or a blank line; type 6 (`<`/`</` + one of the 62 HTML block-tag names) and type 7 (a complete open/closing tag on its own line) end at a blank line (or containing-block boundary). Types 1–6 can interrupt a paragraph; type 7 cannot. Content is the container-stripped remainder with leading whitespace preserved, emitted verbatim as a `.html_block` leaf (pass-through policy, same as inline HTML). **Scorecard: 44/44**. |
| tables (GFM extension) | implemented | GFM §4.10 pipe tables in the Markdown frontend: header + delimiter (3+ hyphens, or 1+ with a colon) + body rows, leading/trailing pipes optional, `\|` escaped pipes, inline-parsed cells, alignment colons, `<table><thead><tbody>` output. Delimiter required; header/delimiter column counts must match; table ends at blank line or another block start. Cells are single-line (no blocks). Chosen behaviors where the GFM spec is silent are pinned in docs/TABLES.md. The contract-doc and assertion update points of recorded ambiguity 21 now point at docs/TABLES.md. |
| link reference definitions | implemented | §4.7: `[label]: destination ["title"]` collected during the block pass, before any inline parsing (a use may precede its definition). Extracted at paragraph close: the first line must be `[` + label + `]` + optional spaces/tabs + destination; an optional title may follow on the same line (separated by spaces/tabs) or on the next line; nothing else may follow the title on its line; indentation beyond 3 spaces cannot start a definition. First definition wins per label; labels are case-folded (Unicode full case fold, §6.3) with internal whitespace collapsed to a single space; an unclosed `[` cannot be a definition. Paragraphs consisting solely of definitions disappear from output; a definition may sit inside a paragraph of other content (the surrounding paragraph keeps its own inline pass). |
| blank lines | implemented | §3; whitespace-only lines separate blocks and are never part of content. |

## Inlines

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| plain text | implemented | Text nodes are slices of the source. Rendering escapes `& < > "` and replaces NUL with U+FFFD (see docs/ARCHITECTURE.md). |
| soft breaks | implemented | Newline inside a paragraph → `soft_break` node → `\n` in HTML (CommonMark default, §6.8). A preceding single trailing space is consumed, not emitted. |
| hard breaks | implemented | §2.4/§6.7: two or more trailing ASCII spaces (tabs in the trailing run do not trigger a break) or an unescaped backslash before a following content line → `hard_break` → `<br />`. The trailing whitespace run (and a hard-break backslash) is consumed and never emitted. A single trailing space yields a soft break; the run is still consumed. A terminal backslash with no following content line remains literal (example 644); likewise, the final content line before a Setext underline cannot create a break into the excluded underline. |
| backslash escapes | implemented | §2.4: `\` + any ASCII punctuation escapes it (produces that character literally); backslashes before other characters are literal; `\\` → literal `\` (escape-aware, example 15). Escapes are recognized in ATX closing-sequence detection (§4.2 example 76) and in end-of-line hard-break analysis (`foo\\` is a literal backslash + soft break). Each escape splits the text into adjacent text nodes with exact source spans; contiguous spans merge into one text node (§6.2 milestone). |
| entities | implemented | §2.5, per docs/ENTITIES.md. Named references decode against the full WHATWG HTML5 entity list (2,231 names, generated into src/entities.zig from html.spec.whatwg.org entities.json via tools/gen-entities.py, mirroring the unicode.zig pattern); numeric references decode hex/decimal with the spec's range rules — invalid codepoints and surrogates become U+FFFD, a decoded tab/carriage-return/line-feed is emitted literally. Decoding happens at render time in the text writer (escaped chars are still escaped, e.g. `&lt;` → `&lt;`) and at parse time in link/image destinations + titles, autolinks, image alt flattening, and fenced info strings; backslash-escaped `&` is never decoded (the escape splits the text node so the renderer sees the escaped char). Not decoded in code spans or code blocks. Requires a trailing `;`; bare names like `&copy` stay literal. **Scorecard: 17/17** (§2.5). |
| emphasis / strong | implemented | §6.2, full rule set (rules 1–12) with the scan → match → emit algorithm in docs/INLINE-PARSING.md: per-run flanking classification, a delimiter stack with `openers_bottom` pruning (amortized linear), the mod-3 rule, strong-before-emphasis, and front/back run consumption for intraword runs that act as both closer and opener. Unicode whitespace/punctuation classification comes from generated tables (src/unicode.zig, Unicode 13.0 categories Zs / P+S per §2.1). Adjacent text nodes merge when their spans are contiguous (normalized model). Verified against spec examples 384–418 including `***foo** bar*`, `*****Hello*world****`, `foo_bar_baz`, `5__6__78`, `пристаням__стремятся__`. |
| code spans | implemented | §6.1: backtick-string discovery runs ahead of delimiter matching; an opener closes at the next backtick string of equal length (opening 2 vs closing 1 does not match); unmatched backticks stay literal. Content is opaque to delimiters and backslash escapes are inert inside; line endings become spaces; one ASCII space is stripped from each end when the content begins and ends with space but is not all spaces (tabs are not stripped, spec 344's note); the closer scan ignores backslash escapes (spec 340). `code_span` is a leaf inline with arena-owned normalized content; the node span covers the whole construct including backticks. Verified against spec examples 333–348. |
| links | implemented | §6.3 (inline links + reference forms): link-bracket discovery runs ahead of delimiter matching (brackets bind more tightly than emphasis; `*[foo*](/uri)` is a link), and code spans bind more tightly than brackets. A `]` whose nearest `[` is followed by a valid `(...)` forms an inline link; otherwise the full `[text][label]`, collapsed `[text][]`, and shortcut `[text]` reference forms are tried against the collected definitions (§4.7), in that order; a `(` after the `]` that fails to parse as an inline destination does *not* block the shortcut form (spec example 561), and reference forms cannot contain other reference links in their labels. Brackets that never resolve stay literal. Inline destination/title syntax per spec: `<...>` or bare destinations (balanced/escaped parens only), `"`/`'`/`(...)` titles, components separated by spaces/tabs/up to one line ending, destinations cannot contain line endings, titles may. A valid link kills every earlier `[` (links cannot contain links, innermost wins); link text is matched as a fresh inline scope. Destinations and titles resolve backslash escapes into arena-owned payloads (`data.link`); href percent-encoding is a renderer policy (see docs/ARCHITECTURE.md). **Chosen behaviors/divergences:** a paren-title closes at the first unescaped `)`; an unescaped `<` inside an angle destination fails the link; DoS guards — paren depth capped at 32 (spec-sanctioned) and component scans capped at 2048 bytes. Destinations and titles also resolve §2.5 entities (`&amp;` → `&`) before escaping, per the spec. Verified against spec examples 482–536 (inline subset) plus the §6.3 reference-link examples. |
| images | implemented | §6.4, see docs/IMAGES-PARSING.md. `![` (unescaped `!` + `[`) is its own opener on the same discovery stack as links; an image description may contain links and images, so only a formed *link* inactivates earlier `[` openers — never `![` (the spec appendix's active/inactive rule, implemented as an O(1) monotone check). The description is matched as a fresh inline scope and flattened to the arena-owned `alt` string ("only the plain string content" — an autolink in the description contributes its raw label, `![<http://x>](img)` → `alt="http://x"`); `.image` is a leaf inline (`data.image = { src, alt, title }`). `<img src alt title>` renders as a void element under `void_trailing_slash`; `src` uses the link `href` percent-encoding policy; `alt` is always emitted (possibly empty) and `title` only when present, both HTML-escaped like text; attribute order is fixed `src`, `alt`, `title`. Destinations/titles parse identically to links and share the §6.3 DoS guards (paren depth 32, scan cap 2048). **Reference forms implemented:** `![alt][label]`, `![alt][]`, and `![alt]` resolve through the §4.7 definition table with the same full→collapsed→shortcut ordering as reference links (docs/REFERENCE-IMAGES.md); the description flattens to `alt` identically, and a formed reference image inactivates nothing (same monotone rule). |
| autolinks | implemented | §6.5, see docs/AUTOLINKS.md. A `<` is recognized ahead of link/image bracket parsing (brackets and code spans do not intercept it) when it starts a URI autolink (scheme 2–32 chars, then `:`, then content up to the first `>`; content forbids ASCII control, space, and `<`) or an email autolink (the non-normative HTML5 email regex, anchored: local part + `@` + dot-separated labels of at most 63 chars, each alphanumeric-bounded and ending alphanumeric). URI content may contain `\`, `]`, and `(` freely — those are *not* escapes or link syntax inside an autolink (spec example 526: `](uri)` lands in the href). Emits one `.autolink` leaf (`data.autolink = { href, label }`); the label is the raw content verbatim (backslash escapes are inert inside autolinks — the payload is *not* escape-resolved, unlike `data.link`), and the href is the content for URIs or `mailto:` + content for emails. Renders `<a href="...">label</a>` with deterministic escaping and percent-encoding. Recognition is linear; verified byte-for-byte against all 19 §6.5 examples. |
| inline HTML | implemented | §6.6: open/closing tags, comments, processing instructions, declarations, and CDATA sections are discovered across paragraph lines, kept opaque to delimiters/links, and rendered verbatim from their source spans. Invalid shapes remain escaped text; custom tag names are allowed. The renderer policy for this slice is pass-through (as is the §4.6 HTML-block family, now complete); configurable escaped/rejected modes remain planned. See docs/RAW-HTML.md. |
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
<https://hobix.com/textile>), Movable Type "Textile 2 Syntax" (Brad
Choate, <https://movabletype.org/documentation/author/textile-2-syntax.html>),
and the Textile Markup Language Documentation
(<https://textile-lang.com/doc/block-quotations>). These are user-facing
syntax documents, not parser code.

Textile is a first-class dialect. Where the references disagree, Oliver
records the disagreement and chooses one behavior (see "Recorded ambiguities"
below).

## Blocks

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| paragraphs | implemented | Blank-line separated (`p.` default signature, both references). Bare text or `p.`-prefixed; a `p.` marker must be followed by a space/tab to count and interrupts an open block even without a preceding blank line. Content is preserved verbatim (only the marker's separator whitespace is consumed). |
| headings | implemented | `h1.`–`h6.` markers, each followed by a space/tab. `h0.`/`h7.`+ are not headings (paragraph text). `hN.` at end of line (no space) is not a heading. Content after the marker is verbatim. |
| line breaks | implemented | Newline inside a paragraph → hard break → `<br />`. Textile 2 is explicit ("newlines for XHTML content receive a `<br />` tag at the end of the line, with the exception of the last line in the paragraph"); Hobix prose agrees ("Line breaks are converted to HTML breaks") though its rendered example shows a plain newline — recorded below. |
| block quotes | implemented | Single-period `bq.` from the Hobix Textile Reference, Movable Type Textile 2 Syntax, and the current Textile Markup Language Documentation. The signature must be followed by space/tab; all separator whitespace is consumed. Unmarked following lines continue one paragraph inside `.block_quote` with Textile hard breaks until a blank line or a recognized `p.`, `hN.`, or `bq.` signature; signatures interrupt an open block. The quote and child paragraph spans exclude the marker/separator and cover their content. An empty `bq. ` stays literal because the sources do not specify empty quote behavior. Extended `bq..` and citation `bq.:URL` remain literal/deferred. |
| pre/code | planned | `pre.` and `bc.` (block code, which also escapes `<`/`>`). |
| lists | implemented | `*` unordered, `#` ordered; nesting by repeating the marker (`**` = nested), per both references. Each item is one line; lists are tight; a blank line, a block signature, or a non-marker line closes the list tree. A different marker at the same depth starts a sibling list; a depth jump opens empty intermediate items; `*#` runs or markers without a following space/tab are ordinary text (docs/TEXTILE-PARITY.md §3). Styling markers (`(class#id)* one` vs `*(class#id) one`) and multi-line items remain deferred. |
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
| emphasis `_x_` | implemented | → `<em>`. Both references agree. Same-line, with the shared whitespace/punctuation boundary contract (docs/TEXTILE-PARITY.md §3). |
| strong `*x*` | implemented | → `<strong>`. Both references agree. Same boundary contract. |
| bold `**x**` / italic `__x__` | implemented | → `<b>` / `<i>`. Both references agree (Hobix: "doubling the underscores or asterisks"). Runs of 3+ stay entirely literal. |
| deleted `-x-` / inserted `+x+` | implemented | → `<del>` / `<ins>`. Both references agree. |
| superscript `^x^` / subscript `~x~` | implemented | → `<sup>` / `<sub>`. Both references agree. |
| code `@x@` | implemented | Same-line code phrase → shared opaque `.code_span` → `<code>`; payload bytes are verbatim and the full `@...@` source range is the node span. Textile 2 explicitly requires `<`/`>` escaping; the shared renderer also escapes `&`, `"`, and NUL. Open/close operators must touch non-whitespace content and use outside Unicode whitespace/punctuation boundaries; intraword, empty, edge-whitespace, unmatched, embedded-`@`, and cross-line shapes fall back literally. Backslash has no escape role in the cited references. Exact clean-room contract: `docs/TEXTILE-INLINE-CODE.md`. |
| citation `??x??` | planned | → `<cite>`. Hobix only. |
| span `%x%` | implemented | → `<span>` (no attributes yet). Both references agree. Attribute forms (`%{style}x%` etc.) stay planned. |
| big `++x++` / small `--x--` | deferred | Textile 2 only; Hobix does not document them. Oliver will not implement until the inline milestone and will record the choice. |
| links | implemented | `"text":url`, optional `(title)` inside the quotes (both references). URL runs to whitespace or `)]}`; trailing sentence punctuation is excluded (Hobix); the bracket trick `You["gotta":url]seethis!` works (Textile 2). Display text is plain text (not re-scanned). Aliases `[alias]url` + `"text":alias` remain planned. See docs/TEXTILE-PARITY.md §3. |
| images | implemented | `!url!`, alt `(alt)` (Hobix) / ` (alt)` (Textile 2), link attachment `!url!:href` (Hobix). The alt doubles as the title per the Hobix example. Size, alignment, and attribute modifiers remain planned; modifier-prefixed or whitespace-containing bodies stay literal. See docs/TEXTILE-PARITY.md §3. |
| acronyms | deferred | `CSS(Cascading Style Sheets)` → `<acronym title=...>`. Hobix only. |
| escaping | planned | `==...==` inline region (Textile 2). Backslash escaping varies by version and is unresolved in the references; Oliver will choose one documented form when implementing. |
| character replacements | deferred | Curly quotes, `--`→em-dash, `...`→ellipsis, `(c)`/`(r)`/`(tm)`, Textile 2 macros. Oliver deliberately defers all implicit typography: implicit text transformation is the kind of magic a library should make explicit, and it is not needed by the migration consumers. |
| whitespace sensitivity | implemented | Textile 2: inline operators need whitespace before/after to be recognized; brackets/braces can force recognition. The boundary rule (Unicode whitespace or punctuation/symbol before an opener and after a closer, non-whitespace content edges) is implemented uniformly for `@code@`, every phrase operator, links, and images (docs/TEXTILE-PARITY.md §3). Bracket/brace forcing stays planned. |

## Recorded ambiguities and chosen behaviors

1. **Textile line breaks.** Hobix prose says newlines become `<br />` but its
   rendered example shows a plain newline; Textile 2 explicitly says `<br />`
   (except the last line). **Oliver: `<br />` for every internal newline.**
2. **Block interruption without a blank line.** CommonMark explicitly allows
   ATX headings to interrupt paragraphs; the historical Textile references do
   not define every adjacency between marker lines and open blocks. **Oliver:
   recognized Textile marker lines (`hN.`, `p.`, `bq.`) always start a new
   block, even without a preceding blank line.**
3. **Marker whitespace.** Textile 2: signatures "end with a period and be
   followed with a space"; a third-party note (Mylyn/WikiText docs) says a
   line is only a heading if `hN.` is immediately followed by a space.
   **Oliver: a recognized `hN.`, `p.`, or `bq.` marker must be followed by a
   space or tab; all following separator whitespace is consumed.**
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
   whitespace defines block structure. **Oliver implements the spec's tab
   stops: a tab advances to the next multiple of 4 columns for all block
   structure, while content bytes are never expanded. A tab partially
   consumed by a container's content indentation stays as the view's first
   byte, and its leftover columns become spaces in indented-code content
   (spec Tabs examples 4–7). Tabs after the opening `#` are ordinary
   separator whitespace (matches the spec's `#→Foo` example).**
8. **Markdown paragraph whitespace.** §4.8: "The paragraph's raw content is formed by concatenating the lines and removing initial and final spaces or tabs." Oliver (slice, chosen): leading spaces/tabs are skipped on every line; trailing whitespace is governed by the hard-break rule (two+ spaces → hard break, else soft break; the run is always consumed). With indented code blocks and tab stops implemented, the full §4.8 example set (including the indented-continuation and paragraph-interruption cases) conforms byte-for-byte.
9. **NUL replacement timing.** CommonMark mandates parse-time NUL → U+FFFD.
   **Oliver preserves NUL in the model and replaces at render time** so spans
   always reflect source bytes; output is identical.
10. **Terminal backslashes in headings.** Hard breaks separate inline content
    within a block and therefore do not occur at a block's end. Oliver keeps a
    terminal backslash literal in both ATX headings (example 646) and Setext
    heading content (example 90).
11. **Trailing tabs and hard breaks.** §6.7 requires "two or more spaces";
    Oliver counts only ASCII spaces in the trailing run (a tab does not
    trigger a hard break, but the whole run is consumed).
12. **Alt flattening of breaks and code spans.** §6.4 says only the plain
    string content of an image description is used, with no spec example
    for breaks or code spans inside a description. **Oliver: soft and hard
    breaks flatten to `\n`** (a break's plain string content is the line
    ending; the hard-break marker is consumed as usual) **and code spans
    flatten to their §6.1-normalized content.** Both pinned by fixtures
    (`image-alt-breaks`, `image-alt-code`); see docs/IMAGES-PARSING.md
    §3/§8.
13. **Historical section-number drift.** Some older design records cite
    images as §6.7. Canonical CommonMark 0.31.2 numbers Images as §6.4;
    current feature contracts and new work use the canonical numbering.
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
16. **Textile single-period block-quote termination.** The current Textile
    Markup Language Documentation says a block quotation ends with a blank
    line and distinguishes the multi-paragraph `bq..` form. The compact Hobix
    example does not spell out continuation-line termination. **Oliver:
    unmarked lines after `bq.` remain in its one quoted paragraph until a
    blank line or another recognized block signature.** `bq..` is a later,
    separately documented feature rather than an accidental synonym.
17. **Textile inline-code delimiter edges.** Hobix documents at-sign-delimited
    code phrases, and Textile 2 documents `@code@`, entity escaping, generic
    whitespace sensitivity, and bracket/brace forcing. Neither reference
    defines embedded at-signs, multiline matching, empty/edge-whitespace
    content, or a backslash escape. **Oliver: code is same-line and nonempty;
    operators touch non-whitespace content and have outside Unicode
    whitespace/punctuation-or-symbol boundaries; the first following `@` is
    the only closer candidate; invalid shapes remain literal; backslash is
    inert.** Bracket/brace forcing and `==...==` escaping are later features.
    See `docs/TEXTILE-INLINE-CODE.md`.
18. **Textile phrase operators share the `@code@` boundary contract.** Both
    references agree on the operator set and the doubling rule (`**` → bold,
    `__` → italic); neither defines nesting, run splitting, intraword
    enforcement, or mismatched-closer behavior. **Oliver: openers/closers use
    the same Unicode whitespace/punctuation boundaries as `@code@`; matching
    is strict LIFO by character and run length; phrase content is scanned for
    nested phrases; runs longer than any documented operator (and unmatched
    openers) stay entirely literal; `++`/`--` big/small are deferred.**
    See docs/TEXTILE-PARITY.md §3.
19. **Textile link/image URL edges.** Both references require whitespace
    around a hyperlink and say common punctuation may follow; Textile 2
    documents the bracket/brace trick. Neither defines URL terminators or
    display-text formatting. **Oliver: the URL stops at whitespace or
    `)]}`; trailing sentence punctuation (`.`, `,`, `;`, `:`, `!`, `?`,
    quotes, `)]}`) is excluded; link display text and image src/alt are
    opaque plain text; the image `(alt)` doubles as title.**
    See docs/TEXTILE-PARITY.md §3.
20. **Textile list termination and item shape.** Both references show lists
    as marker-prefixed lines and nesting by marker count; neither defines
    multi-line items, lazy continuation, mixed markers at one depth, or
    depth jumps. **Oliver: items are single lines; lists are tight; a blank
    line, a block signature, or a non-marker line closes the tree; a
    different marker at the same depth starts a sibling list; a depth jump
    opens empty intermediate items.** See docs/TEXTILE-PARITY.md §3.
21. **The repo's own docs use GFM tables by choice.** The authoring docs
    (README.md plus ten `docs/*.md`: ARCHITECTURE, BLOCKS-PARSING,
    DOCUMENT-MODEL, ENTITIES, FEATURE-MATRIX, IMAGES-PARSING,
    INLINE-PARSING, TESTS, TEXTILE-PARITY, WORK-LEDGER) use GFM table
    syntax, which Oliver rendered literally until the tables extension
    landed. The docs are read on GitHub and in source, where GFM tables
    are the native format, and no Oliver consumer renders them (Oliver is
    markup infrastructure; static-site generation is a documented
    non-goal), so converting them to raw-HTML `<table>` blocks was never
    warranted. **Oliver: resolved — the GFM tables extension is now
    implemented (docs/TABLES.md is the contract doc), so the docs render
    correctly through Oliver too. The update points named here — the
    "tables (GFM extension)" row above, the DOCUMENT-MODEL.md convergence
    table, the fixture index, and the shared-model convergence pairs in
    tests/fixtures_test.zig — are all updated.**
