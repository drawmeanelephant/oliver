---
published_at: 2026-10-16T00:00:00Z
summary: "Opt-in Obsidian highlight extension (==text==, colored ==🔴text==) in the Markdown frontend: delimiter rules, color markers, model, rendering per profile (issue #189)."
---

# Highlights (extension)

**Status:** implemented (issue #189).
The family overview is at docs/OBSIDIAN-EXTENSIONS.md.  \
**Modules:** `src/markdown.zig` (parse), `src/document.zig`
(model), `src/html.zig` (render)  \
**Options:** `markdown.Options.highlights: bool = false`; CLI
`--highlights`; C ABI `OLIVER_MD_HIGHLIGHTS = 1 << 8`

Obsidian's published syntax (Obsidian Help, "Basic formatting syntax §
Bold, italics, highlights" and "§ Highlight colors"). knap 0.6.0's
`highlight` filter emits the same bytes (KNAP-FIDELITY.md §2). With the
flag off, `==x==` stays literal text, as it is today.

## 1. Shape

- **Delimiters.** `==text==` is a highlight whose children are the
  inline-parsed `text`.
  - A delimiter is a run of **exactly two** unescaped `=`.
  - A single `=` and runs of three or more stay literal, consumed whole,
    so `===` never re-scans as `==` + `=`.
  - This is the same run rule as `~~` strikethrough
    (docs/MARKDOWN-EXTENSIONS.md §4).
- **Flanking** follows the CommonMark §6.2 rules, `*`-style: an opener
  must be left-flanking and a closer right-flanking. So `== a ==` stays
  literal, and intraword `a==b==c` highlights `b`.
- **Matching.** Runs are matched on the existing delimiter stack.
  - `==` runs never pair with `*`, `_`, or `~` runs, and never count
    toward the mod-3 rule.
  - A highlight may span soft line breaks within one paragraph or inline
    scope, and never crosses a block boundary.
- **Block structure is resolved first.** A line of only `=` characters
  under a paragraph is a Setext h1 underline (§4.3), so
  `foo` + newline + `==` is `<h1>foo</h1>` (verified). `==x==` on its
  own line is never an underline, because it contains other bytes.
- **Escapes.** `\==x==` escapes the first `=`. The remaining `=` is a
  run of one and stays literal, and the trailing `==` has no opener, so
  the whole thing is literal.

## 2. Color markers

Obsidian documents six colors, selected by an emoji placed
**immediately after the opening `==`**:

| emoji | codepoint | UTF-8 | `color` |
| --- | --- | --- | --- |
| 🔴 | U+1F534 | `F0 9F 94 B4` | `.red` |
| 🟠 | U+1F7E0 | `F0 9F 9F A0` | `.orange` |
| 🟡 | U+1F7E1 | `F0 9F 9F A1` | `.yellow` |
| 🟢 | U+1F7E2 | `F0 9F 9F A2` | `.green` |
| 🔵 | U+1F535 | `F0 9F 94 B5` | `.blue` |
| 🟣 | U+1F7E3 | `F0 9F 9F A3` | `.purple` |

**How a marker is recognized:**

- **Decision: markers are recognized.** The marker exists only to
  select a color; left as content, every consumer would have to strip
  it again. The table is closed: it matches Obsidian's documentation
  exactly.
- **Where.** A marker is recognized only as the **first bytes** of a
  matched highlight's content, with no whitespace in between.
  - When present, the marker is consumed, together with an immediately
    following U+FE0F (VS16), and sets `color`.
  - Any other leading emoji, or a table emoji anywhere else in the
    content, is ordinary text.
- **Order.** Delimiter matching happens first and marker extraction
  second. So `==🔴==` is a highlight with `color = .red` and no
  children; it renders as an empty `<mark>` and is pinned.
- **Flanking consequence (pinned, not special-cased).** These emoji are
  Unicode symbols (category So), so CommonMark 0.31.2 counts them as
  punctuation. An opener directly followed by a marker is therefore
  left-flanking only when it is preceded by whitespace, punctuation, or
  the start of the line:
  - `see ==🔴x==` highlights;
  - `see==🔴x==` stays literal.

## 3. Model

New inline **container** tag `.highlight`, with children that are
ordinary inlines:

```zig
data.highlight = .{
    .color: ?HighlightColor = null, // null: theme-default highlight
}
pub const HighlightColor = enum { red, orange, yellow, green, blue, purple };
```

- The node span covers the delimiters. The marker bytes are covered by
  no child node (consumed, like delimiter bytes).
- Textile never produces `.highlight`. Textile's `==` is its notextile
  raw passthrough and is unrelated.

## 4. Rendering

| profile | no color | `color = .red` |
| --- | --- | --- |
| HTML | `<mark>…</mark>` | `<mark class="highlight-red">…</mark>` |
| XHTML | `<mark>…</mark>` | `<mark class="highlight-red">…</mark>` |
| HTML 4.01 Strict | `<span class="mark">…</span>` | `<span class="mark highlight-red">…</span>` |

- `<mark>` is not in HTML 4.01. The Strict profile maps it to a `span`,
  following the precedent of footnotes `section` → `div` in
  docs/HTML4-STRICT.md, which gains a row when this lands.
- The class names come from the `HighlightColor` tag names, never from
  source bytes.

## 5. Fallbacks (literal)

- The flag is off (the default).
- `=x=`, `===x===`, and longer runs.
- `== x ==` (opener not left-flanking) and an unmatched `==x`.
- `word==🔴x==` (§2 flanking consequence).
- `\==x==`.

## 6. Interactions

- **Nesting.** Children are ordinary inlines: emphasis, links, code
  spans, wikilinks, embeds, math, and strikethrough all nest inside, and
  highlights nest inside emphasis and links.
- **Comments.** `%%…%%` inside a highlight is removed (COMMENTS §2).
- **Callout titles.** `> [!note] ==Title==` works, because titles are
  inline-parsed.
- **`smartypants`** applies to highlight text. The marker is consumed
  before typography runs.
- **Plain-text flattening** (image alt, `heading_ids` slugs) uses the
  children's text. The marker contributes nothing.
- **Code.** Code spans and code blocks stay opaque: `` `==x==` `` is
  code.

## 7. Fixtures

| fixture | covers |
| --- | --- |
| `highlight-basic` | prose; nesting both ways; soft-break spans; lists; table cells; callout titles |
| `highlight-literal` | the §5 battery and the Setext-underline precedence |
| `highlight-color` | each of the six markers, VS16 consumption, a non-table emoji as content, `==🔴==`, and the flanking consequence |
| `highlight-color.strict.html` | the HTML 4.01 Strict mapping |

Unit tests cover the node shape and span, marker consumption, behavior
with the flag disabled, and a 10,000-highlight determinism storm.

## 8. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration: 652/652 with the `--gate` harness).
