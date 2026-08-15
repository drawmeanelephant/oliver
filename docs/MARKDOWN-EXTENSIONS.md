# Markdown extensions (footnotes, definition lists, heading attributes, strikethrough)

**Status:** implemented — opt-in Markdown dialect extensions  \
**Modules:** `src/markdown.zig` (parse), `src/html.zig` (render), `src/document.zig` (model)  \
**Options:** `oliver.ParseOptions.markdown` (parse) and `oliver.html.RenderOptions` (render)

The Markdown frontend is byte-exact CommonMark 0.31.2 by default (the
652/652 conformance corpus is green with default options). The extensions
below are **off by default** and enabled per parse/render call, so no
consumer pays for syntax it did not ask for, and the CommonMark regression
wall stays meaningful.

The four extensions were added for a real consumer (the Boris static-site
compiler) that publishes footnotes, definition lists, explicit heading
anchors, and GFM-style auto heading ids. They are implemented here, in the
markup library, rather than as consumer-side post-processing, so their
behavior is a library contract with fixtures.

---

## 1. Footnotes (`parse: footnotes`)

Pandoc-style footnotes:

```markdown
Hi[^note].

[^note]: The note body.
```

- A reference is `[^label]` where `label` is any non-empty bytes between
  the caret and the closing bracket (spaces allowed, `]` not). A reference
  is recognized **only when the label names a registered definition**;
  undefined references stay literal text.
- A definition line is `[^label]:` at the start of a paragraph line with
  at most three columns of indentation, followed by optional whitespace
  and the note body. A definition may be continued on following lines
  indented 1–3 columns. Definitions are extracted from the start of each
  paragraph, exactly like §4.7 link reference definitions, and a paragraph
  consisting only of definitions produces no block.
- Definitions never appear in the body; the renderer (with the `footnotes`
  render option) appends a footnotes section at the end of the document
  containing the **used** definitions in **first-reference order**,
  numbered 1..N:

```html
<p>Hi<sup class="footnote-ref"><a href="#fn-1" id="fnref-1" data-footnote-ref>1</a></sup>.</p>
<section class="footnotes" data-footnotes>
<ol>
<li id="fn-1">
<p>The note body. <a href="#fnref-1" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">↩</a></p>
</li>
</ol>
</section>
```

- Labels match **exactly** (case-sensitive byte equality).
- Render-side numbering is first-reference order, so the numbers follow the
  order the author references the notes, not the order of the definitions.
- **Repeated references are tracked per reference.** The first reference to
  a footnote is `fnref-N`; the second is `fnref-N-2`, the third
  `fnref-N-3`, and so on, so every reference has a unique id (a duplicate
  `id` would be invalid HTML and break fragment navigation and
  `getElementById`). The footnote body emits **one backref per reference**,
  each pointing at its own reference id — the `data-footnote-backref-idx`
  carries the `N`, `N-2`, `N-3`, … form. Example (three references to one
  note):

```html
<p>The note body. <a href="#fnref-1" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">↩</a> <a href="#fnref-1-2" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1-2" aria-label="Back to reference 1-2">↩</a> <a href="#fnref-1-3" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1-3" aria-label="Back to reference 1-3">↩</a></p>
```

- The back-reference anchor is appended inside the definition's last
  paragraph; a definition whose last block is not a paragraph gets the
  anchor on its own line before `</li>`.
- The footnotes section renders only when the `footnotes` render option is
  on **and** at least one reference exists.

## 2. Definition lists (`parse: definition_lists`)

Pandoc-style definition lists:

```markdown
Term
: Definition text.
```

- A definition marker is `:` or `~` preceded by at most three columns of
  indentation and followed by a space/tab. The marker line must directly
  follow a term paragraph (no blank line).
- The term is the immediately preceding paragraph. Consecutive
  term/definition pairs without a blank line between them merge into **one**
  `<dl>`.
- A definition's content is the marker-stripped line; following lines
  indented 1–3 columns continue the definition's paragraph (the inline pass
  trims their leading whitespace). A line with four or more columns of
  indentation ends the definition body (it is reprocessed as an indented
  code block).
- A blank line, a block start (heading, fence, thematic break, list, block
  quote, table, HTML block, ...), or end of input ends the list. A
  definition marker with no open term paragraph and no open list is
  ordinary text.
- Within block quotes and list items the marker is matched after container
  markers are stripped (`> Term`, `> : Definition` works).
- Rendering: a single-paragraph definition body renders tight (`<dd>text</dd>`);
  a multi-block body keeps its `<p>` wrappers:

```html
<dl>
<dt>Term</dt>
<dd>Definition text.</dd>
</dl>
```

## 3. Heading attribute lists (`parse: heading_attributes`)

Kramdown/MultiMarkdown-style inline attribute lists on ATX and Setext
headings:

```markdown
## Exit codes {#exit-codes}

### Warning {#warn .important}
```

- The attribute list is the last thing on the heading line, preceded by
  whitespace: `{#id .class}`. `#id` sets the heading's explicit id and
  `.class` its class (first token of each kind wins; values are the raw
  source bytes). Unknown token shapes, an empty `{}`, or a `{...}` that is
  not preceded by whitespace leave the heading unchanged (the `{...}`
  stays literal text).
- The list is consumed: it never appears in the rendered heading text.
- The parse option only affects recognition; the id/class are carried on
  the heading model. See the `heading_ids` render option for how the
  explicit id interacts with auto-generated ids.

## 4. GFM strikethrough (`parse: strikethrough`)

Wraps text in `<del>` when it is surrounded by a matching pair of exactly
**two** tildes, per GFM spec §6.5 "Strikethrough (extension)".

- Only runs of exactly two tildes are delimiters; a single `~` and runs of
  three or more tildes stay literal text (consumed whole, so a three-tilde
  run cannot re-scan as a two-tilde delimiter).
- Flanking follows the CommonMark emphasis rules (`*`-style: opening needs
  left-flanking, closing needs right-flanking), and strikethrough cannot
  span paragraph boundaries. Within a paragraph it may span soft-wrapped
  lines, and it composes with emphasis, links, code spans, and tables.
- `~~` delimiters never interact with `*`/`_` emphasis runs, and the
  block-level definition-list `~` marker is unaffected (definitions require
  a `~` at line start; a two-tilde run never matches).
- Rendered as the document-model `deleted` node (the same node Textile's
  `-x-` produces), so both dialects emit `<del>`.
- Examples: `~~Hi~~ Hello, world!` → `<del>Hi</del> Hello, world!`;
  `~x~` and `~~~x~~~` render literally.
- Fixtures: `tests/fixtures/markdown/ext-strikethrough.md`; unit tests in
  `src/markdown.zig`.

---

## 5. GFM-style heading ids (`render: heading_ids`)

Auto-generated `id` attributes on every heading that has no explicit IAL
id, following GFM §5.3 applied byte-wise:

1. Lowercase ASCII letters.
2. Keep `a-z 0-9 _ -`; drop everything else (including non-ASCII bytes).
3. Collapse every whitespace run into a single `-`.
4. Trim leading/trailing `-`.

The slug is computed from the heading's **plain-text content**: text is
entity-decoded, code spans contribute their normalized content, images
their alt, autolinks their label, nested inline containers their text,
breaks become spaces, and raw HTML is skipped. Examples:

| Heading | id |
| --- | --- |
| `## Hello, World!` | `hello-world` |
| `## Sub & More` | `sub-more` |
| `## Café résumé` | `caf-rsum` |
| `## Code ` + `` `span` `` + ` here` | `code-span-here` |
| `## **Bold** and *italic*` | `bold-and-italic` |
| `## Exit codes {#exit-codes}` (IAL) | `exit-codes` (explicit wins) |

Byte-wise application means non-ASCII letters are dropped (their base
letters are not recovered), which matches the observed GitHub behavior for
accented headings (`Café résumé` → `caf-rsum`) without a Unicode
normalization table. Duplicate headings keep duplicate ids (no `-1`
suffixes), matching the GFM reference implementation.

---

## Interaction and precedence

- Extensions compose: a heading with an IAL id renders that id even when
  `heading_ids` is on; footnotes may appear inside definition bodies; link
  reference definitions and footnote definitions can lead the same
  paragraph (footnote definitions are tried first).
- Fenced code, code spans, HTML blocks, and raw HTML are opaque to all five
  extensions (a `[^x]:` line inside a fence is code, not a definition; a
  `~~` pair inside a code span or fence is literal).
- Fixtures: `tests/fixtures/markdown/ext-*.md` (parsed with all extensions
  enabled) plus unit tests in `src/markdown.zig` and `src/html.zig`.
