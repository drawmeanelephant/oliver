---
published_at: 2026-10-16T00:00:00Z
summary: "Planned opt-in TeX math extension ($…$, $$…$$, fenced $$ blocks) in the Markdown frontend: Pandoc's tex_math_dollars disambiguation, code-span precedence, model, and passthrough rendering (issue #189)."
---

# Math (extension, planned)

**Status:** planned — spec under review in issue #189; not implemented.
The family overview is at docs/OBSIDIAN-EXTENSIONS.md.  \
**Modules (planned):** `src/markdown.zig` (parse), `src/document.zig`
(model), `src/html.zig` (render)  \
**Options (planned):** `markdown.Options.math: bool = false`; CLI
`--math`; C ABI `OLIVER_MD_MATH = 1 << 9`

Obsidian documents `$…$` inline math and `$$` display math (Obsidian
Help, "Advanced formatting syntax § Math"), but it does not document how
`$` is disambiguated in prose. Oliver adopts the published Pandoc rule
for that. knap 0.6.0's `math` and `math_block` filters emit the same
shapes (KNAP-FIDELITY.md §2). Oliver passes TeX through and never
typesets it.

## 1. Inline math

### Delimiters

- A run of **exactly one** unescaped `$` is an inline delimiter.
- A run of **exactly two** is a display delimiter.
- Runs of three or more stay literal, consumed whole.
- An escaped `\$` is a literal dollar and never a delimiter. `$` is
  ASCII punctuation, so it is already escapable in CommonMark.

### `$…$` disambiguation (decision: Pandoc `tex_math_dollars`)

Quoting the Pandoc User's Guide: "The opening `$` must have a
non-space character immediately to its right, while the closing `$` must
have a non-space character immediately to its left, and must not be
followed immediately by a digit."

- The closer is the first later single-`$` run that is unescaped,
  preceded by a non-space, and not followed by an ASCII digit.
- Any `$` that fails those tests is content.
- If no closer exists in the inline scope, the opener is literal text
  and scanning resumes after it.

### `$$…$$` inside a paragraph

This is display math. Following Pandoc, the delimiters may be separated
from the formula by whitespace, so the space rules do not apply.

- It closes at the next unescaped `$$` run in the inline scope.
- If the content between the delimiters is empty or only whitespace, the
  whole thing is literal.

### Worked cases (pinned)

| input | result | why |
| --- | --- | --- |
| `$x$` | inline math `x` | — |
| `$e^{2i\pi} = 1$` | inline math | Obsidian's documented example |
| `$20,000 and $30,000` | literal | Pandoc's own example: the second `$` is preceded by a space |
| `$5 and $10` | literal | same rule |
| `$x$5` | literal | the candidate closer is followed by a digit |
| `$ x $` | literal | space after the opener |
| `$a $b$` | inline math `a $b` | the middle `$` can't close, so it's content |
| `$\$5$` | inline math `\$5` | an escaped `$` never closes, and the TeX is kept verbatim |
| `\$x$` | literal `$x$` | the escaped opener is a literal dollar, and the second `$` has no closer |
| `$$x$$` mid-paragraph | display math `x` | — |

### Precedence (load-bearing)

Math spans join the CommonMark **first-opener-wins** family of code
spans, autolinks, and raw inline HTML (§6.1, §6.5, §6.6): whichever
construct opens first claims its bytes.

- `` `$x$` `` is a code span, and `` $`x`$ `` is math whose content is
  `` `x` ``.
- Inside math, backslash escapes and entity references are **not**
  processed. TeX is full of backslashes: `$\{a\}$` keeps `\{a\}`.
- Emphasis, links, wikilinks, embeds, and highlights cannot form inside
  math or cross its boundary: in `$a_1 + b_1$` the `_` stays content.
- Because code-span precedence beats link brackets, a valid `$…$` pair
  inside a link destination becomes math, exactly as a code span would.
  Escape the `$` to keep it out.

### Content

- The content is the bytes between the delimiters.
- A multi-line span has the paragraph's container prefixes and line
  leading whitespace stripped, as with any inline content, and line
  endings are normalized to `\n`.
- Line endings are **preserved, not turned into spaces** as code spans
  do: a TeX `%` comment runs to the end of its line, so joining lines
  would comment out the rest of the formula.

## 2. Math blocks

```markdown
$$
\begin{vmatrix}a & b\\
c & d
\end{vmatrix}=ad-bc
$$
```

This is Obsidian's documented form, and the rules mirror fenced code
(§4.5):

- **Opening line:** after container prefixes, up to 3 columns of
  indentation, `$$`, then only spaces and tabs.
- **Closing line:** the same shape. The block closes at the first
  closing line.
- **Content:** the lines between are taken verbatim. If the opener is
  indented N columns, up to N columns of indentation are removed from
  each content line, as with fences. There are no escapes, and blank
  lines are content.
- **Interruption:** a math block can interrupt a paragraph, and it is
  never a lazy continuation line.
- **Unclosed:** a block with no closing line ends with its container or
  the document, with no diagnostic (fenced-code behavior).
- **One-line form:** `$$x$$` alone on a line is **not** a block. It is a
  paragraph containing inline display math, which keeps the block
  grammar unambiguous. Obsidian renders both as display math; the
  difference here is only the wrapping `<p>`.
- **Divergence from Pandoc:** Pandoc's display math is inline-only and
  forbids blank lines. The fenced block form is Obsidian-driven.

## 3. Model

```zig
data.math = .{
    .tex: []const u8,  // the TeX source
    .display: bool,    // false only for `$…$`
}
```

- `.math_inline` is an inline leaf.
  - `tex` is a source slice for single-line spans, and arena-owned when
    line normalization was needed.
  - `display` is true for `$$…$$`.
- `.math_block` is a leaf block.
  - `tex` is arena-owned, because container prefixes are stripped.
  - Like code blocks, each content line is terminated with `\n`.
  - `display` is always true.

## 4. Rendering

| node | output |
| --- | --- |
| `$x$` | `<span class="math inline">x</span>` |
| `$$x$$` (inline) | `<span class="math display">x</span>` |
| math block | `<div class="math display">tex</div>`, where `tex` ends with `\n` |

- The TeX is escaped like text, for example `&` → `&amp;`. KaTeX and
  MathJax read the text content, so they see the original TeX.
- The output is identical in HTML, XHTML, and HTML 4.01 Strict: `span`,
  `div`, and `class` are valid in all three.
- The renderer emits no `\(…\)` or `\[…\]` wrappers; the class tokens
  carry the inline/display distinction. Open question 1
  (docs/OBSIDIAN-EXTENSIONS.md §11) asks whether to add them for
  zero-config auto-render.
- **Not in scope:** TeX → MathML/SVG typesetting, and macro expansion.

## 5. Fallbacks (literal, no diagnostic)

- The flag is off (the default).
- The §1 worked-case literals.
- An unmatched `$` or `$$`, an empty `$$ $$`, and runs of `$$$` or
  more.
- A `$$` line indented 4 or more columns (that is indented code or
  paragraph continuation).

## 6. Interactions

- **Highlights** may contain math (`==$x$==`). Math contains nothing
  else.
- **Link text** may contain math, because a `<span>` inside `<a>` is
  valid.
- **Plain-text flattening:** image alt and `heading_ids` slugs use the
  TeX source.
- **`smartypants`:** math content joins the exemption set
  (docs/SMARTY.md), so it is never curled or dashed.
- **GFM tables:** row splitting happens before inline parsing, so a `|`
  inside math in a cell splits the cell. TeX `|` needs `\vert` or `\|`
  there; this is the same caveat as docs/WIKILINKS.md §7.
- **Opacity:** math is never recognized inside code spans, code blocks,
  autolinks, raw HTML, HTML blocks, or comments.
- **Callout titles** are inline-parsed, so inline math works in them.

## 7. Fixtures (planned)

| fixture | covers |
| --- | --- |
| `math-inline` | the §1 worked-case table; multi-line spans with `%` comments; inside highlights, link text, and callout titles |
| `math-literal` | the §5 battery |
| `math-precedence` | code-span, autolink, and raw-HTML first-opener-wins; escape inertness; `_`/`*` opacity; link destinations |
| `math-block` | fences, indentation stripping, blank lines, paragraph interruption, end-of-container and end-of-document close, and one-line `$$x$$` |

Unit tests cover node shapes, `display`, spans, behavior with the flag
disabled, and a 10,000-span determinism storm. Fuzz seeds cover `$`
runs.

## 8. Conformance status

Not implemented. When it lands it is off by default, and the CommonMark
0.31.2 corpus must stay 652/652 under `--gate`.
