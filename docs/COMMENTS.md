---
published_at: 2026-10-16T00:00:00Z
summary: "Opt-in Obsidian comment extension (%%…%% inline and block) in the Markdown frontend: marker rules, block extent, removal semantics, and the unclosed-comment diagnostic (issue #189)."
---

# Comments (extension)

**Status:** implemented (issue #189).
The family overview is at docs/OBSIDIAN-EXTENSIONS.md.  \
**Modules:** `src/markdown.zig` (parse; no model or render
change)  \
**Options:** `markdown.Options.comments: bool = false`; CLI
`--comments`; C ABI `OLIVER_MD_COMMENTS = 1 << 10`

## Source behavior

Obsidian publishes the syntax (Obsidian Help, "Basic formatting syntax §
Comments"):

- `%%` wraps a comment, and comments are hidden in Reading view.
- An inline comment can appear anywhere in a line, including headings,
  list items, and bold text.
- A block comment "starts when a line begins with `%%`, and ends at the
  next `%%`". It can include blank lines and Markdown.
- Text after the closing `%%` stays visible and renders.
- An unclosed block comment hides the rest of the note.
- Obsidian advises keeping both inline markers on one line and starting
  block comments at the beginning of a line.
- To show a literal `%%`, use a code span or backslash-escape the
  marker.

knap 0.6.0's `comment` filter emits `%%x%%` (KNAP-FIDELITY.md §2).

## 1. Marker

- A marker is a run of **exactly two** unescaped `%`.
- A single `%` and runs of three or more are not markers, and are
  consumed whole.
- `\%%` escapes the first `%`. The remaining `%` is a run of one, so the
  result is a literal `%%`. This is Obsidian's documented escape.

## 2. Inline comments

- **Shape:** an opening marker and the next marker **on the same source
  line**, within one inline scope, form an inline comment. Everything
  between them, plus the markers, is removed.
  - Single-line is a decision, following Obsidian's "keep both markers
    on one line" guidance. A marker with no closer later on its line
    stays literal, unless it begins the line (§3).
- **Precedence:** inline comments join the first-opener-wins family
  with code spans, autolinks, raw inline HTML, and math (MATH §1).
  - `` `%%x%%` `` is code.
  - `` %%`x`%% `` is a comment.
  - `%%*a%%*` removes `*a`, and the trailing `*` is literal.
- **Delimiter matching:** removal happens before delimiter matching, so
  comments are transparent to emphasis. `**a %%x%% b**` is
  `<strong>a  b</strong>`.
- **No whitespace normalization:** the bytes around a comment are kept
  verbatim, which is pinned. `a %%x%% b` renders `a  b` with two spaces,
  and `%%x%% _italic_` renders ` <em>italic</em>`. HTML collapses this
  whitespace visually, and keeping it verbatim keeps removal a pure
  deletion.
- **Empty paragraphs:** a paragraph whose inlines are empty or only
  whitespace once comments are removed is **not emitted**. A line that
  is only `%%x%%` produces nothing. Headings and list items keep their
  CommonMark shapes: `# %%x%%` is an empty `<h1></h1>`, just as `#`
  alone is.
- **Link reference definitions** are extracted before inline parsing
  (§4.7). A comment inside a definition line is part of the definition's
  bytes, for example inside the title.

## 3. Block comments

```markdown
%%
This is a block comment.

Block comments can span multiple lines.
%%
```

- **Start.** A line opens a block comment when, after container prefixes
  and up to 3 columns of indentation, it begins with a marker and has no
  other marker later on the same line. If the line does contain another
  marker, it is ordinary content and §2 applies.
  - A line indented 4 or more columns is indented code (or paragraph
    continuation), never a comment.
  - This is the same shape as HTML-block start condition 2 (`<!--`,
    §4.6), and like it, a block comment **can interrupt a paragraph**.
- **Extent.** The comment runs from the opener through the **next
  marker** on a later line of the same container.
  - Everything in between is unparsed comment content: blank lines,
    headings, lists, fences, and even a fenced block that itself
    contains `%%`. The first marker always closes.
  - Bytes before the closing marker on its line are comment content.
- **After the close.** Bytes after the closing marker on its line are
  processed as **a new line of the same container**: block starts,
  paragraph continuation, and so on, as usual. So:

  ```markdown
  %%
  hidden
  %% visible *text*
  ```

  renders `<p>visible <em>text</em></p>`, matching Obsidian's "text
  after the closing `%%` stays visible". The line view machinery already
  supports resuming mid-line (`View.after`).
- **Containers.**
  - A block comment belongs to the container it started in. Closing
    lines need that container's prefixes (`> %%` … `> %%`).
  - It is never lazily continued: like an HTML block, a line that
    doesn't continue the container closes the container, and the
    comment with it.
- **Opaque contexts.** Inside fenced code, indented code, HTML blocks,
  and math blocks, `%%` is content, because block starts are never
  checked there.

## 4. Rendering

**Decision: comments are removed. They produce no Document node and no
output in any profile.**

- **Privacy.** Obsidian hides comments in Reading view. Emitting
  `<!-- … -->` would ship private annotations to anyone who views the
  source.
- **No dead nodes.** The Document is the normalized render
  representation, and a node that never renders is dead surface.
- **Rejected alternative:** preserving comments as HTML comments.
  Consumers that want visible annotations should use callouts or HTML
  comments directly.
- **Divergence recorded:** k4o's `--format oliver` currently substitutes
  `<!--x-->` (KNAP-FIDELITY.md §6). Under this spec, k4o emits `%%x%%`
  and lets Oliver remove it.

## 5. Diagnostics

The diagnostic fires when a block comment reaches the end of its
container or the document without a closing marker:

```text
severity: warning
code:     unclosed-comment
span:     the opening marker (2 bytes)
message:  "block comment is never closed; it hides the rest of its container"
```

- The comment still runs to the end. This matches Obsidian's
  hide-the-rest-of-the-note behavior; the diagnostic only makes it
  visible.
- Unclosed *inline* markers stay literal and are never diagnosed.
- This is the **first diagnostic the Markdown frontend emits**.
  `markdown.parse` already threads `diags`, and the CLI already surfaces
  diagnostics through `render --diagnostics json`.
- Severity `warning` versus `note` is open question 3
  (docs/OBSIDIAN-EXTENSIONS.md §11).

## 6. Interactions

- **Highlights and emphasis** are transparent to comments (§2).
- **Callouts:** comments work in titles and bodies. A block comment in a
  body closes within the callout (§3, containers).
- **Plain-text flattening** (image alt, `heading_ids` slugs): comments
  contribute nothing. `# Title %%x%%` slugs as `title`.
- **GFM tables:** row splitting comes first, so a `|` inside a comment
  in a cell still splits the cell. The cell's inline content then
  removes its comment.
- **Footnotes:** a `[^x]` reference that sits only inside a comment is
  not a reference, so it doesn't count toward first-reference order.
- **Front matter** is stripped before the body parses, so a `%%` in
  YAML is data.

## 7. Fixtures

| fixture | covers |
| --- | --- |
| `comments-inline` | prose, headings, list items, bold text, code-span precedence, `\%%`, `%%%`, the whitespace pin, empty-paragraph removal, `# %%x%%` |
| `comments-block` | the Obsidian example; blank lines and Markdown inside; resuming after the close; paragraph interruption; `> %%` containers; indented-code exclusion; opacity inside fences |
| `comments-unclosed` | the end-of-document and end-of-container close; the diagnostic code, severity, and span are asserted in a unit test |

Other tests cover cross-extension interactions (`cross-comments-callout`)
and a 10,000-marker determinism storm, and fuzz seeds cover `%` runs.

## 8. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration: 652/652 with the `--gate` harness).
