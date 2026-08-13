# Oliver Document Model

The normalized typed document is the contract between the dialect frontends
and every future renderer. It is **not** HTML-shaped: HTML is one rendering
target, and the model must stay renderer-independent (an HTML renderer today,
maybe a plain-text or AST-dump renderer tomorrow, without reparsing source).

## Shape

```zig
Document {
    arena: ArenaAllocator,   // owns everything below
    src: Source,             // borrowed input bytes
    root: *Node,             // always a .document node
}

Node {
    tag: Tag,                // block or inline kind
    span: Span,              // half-open [start, end) byte range into src
    data: Data,              // per-tag payload (union)
    children: ArrayList(*Node),
}
```

`Tag` in the slice: `document`, `paragraph`, `heading`, `thematic_break`,
`code_block`, `block_quote`, `list`, `list_item`, `text`, `emphasis`, `strong`, `code_span`, `link`, `image`,
`autolink`, `raw_html`, `soft_break`, `hard_break`. Blocks and inlines are
distinguished by `Tag.isBlock` / `Tag.isInline`. `Data` carries `heading`
level (1..6), list kind/marker metadata/start/looseness, the borrowed `text`
slice, arena-owned `code_span` content, arena-owned `code_block` content/info,
the arena-owned `link` href/title,
the arena-owned `image` src/alt/title, or the arena-owned `autolink` href/label.
`raw_html` has no data payload; its source bytes are read from `Node.span`.

## Design decisions

- **One node type, one tag enum.** Two node types (block node vs inline node)
  would add ceremony without type safety that matters here; the invariant is
  enforced by the frontends and documented. If enforcement proves valuable,
  a comptime-asserted child-kind table can be added without reshaping the
  model.
- **Spans everywhere.** Every node carries its exact source range. Text
  payloads are slices into the source — no copies, and spans stay truthful
  even for trimmed or closing-sequence-stripped content (the text node's span
  is the trimmed range).
- **u32 offsets.** 8-byte spans, overflow-free by construction: inputs over
  4 GiB are rejected before parsing. Documented in `source.zig`.
- **Arena ownership.** One allocation pattern per document, freed in one
  `deinit`. No per-node frees, no leak risk, no double-free surface.
- **Deterministic traversal.** `Document.Iterator` yields pre-order
  (document order) using an explicit stack: parent before children, children
  in append order, no call-stack recursion.
- **Dialect metadata only where unavoidable.** The slice needs none: a
  heading from Markdown `# x` and a heading from Textile `h1. x` are the same
  node. The soft_break (Markdown) vs hard_break (Textile) distinction is a
  *semantic* difference in the model itself, not dialect metadata — Textile
  line breaks genuinely render as `<br />`, Markdown soft breaks as `\n`.
  When dialects genuinely differ (e.g. Markdown tight-list `<li>` wrapping
  vs Textile), the difference is represented in structure, or a documented
  per-dialect option on render, never a flag bolted onto the document.
- **Borrowing, not owning text.** The document borrows the input; text nodes
  slice it. This is why `ParseResult` (and thus the document) must not
  outlive the caller's buffer. Documented in `src/document.zig` and
  `docs/ARCHITECTURE.md`.

## Invariants

1. Root is `.document`; its children are blocks.
2. `.paragraph` children are inlines.
3. `.heading` children are inlines.
4. `.thematic_break` is a leaf block with no children or data payload. Its
   span covers the marker line after enclosing container markers are stripped.
5. `.code_block` is a leaf block. `data.code_block.content` is arena-owned,
   indentation-stripped literal content with normalized `\n` endings;
   `info` is the complete trimmed, backslash-resolved arena-owned fence info
   string or null. Its span covers the full container-marker-stripped
   construct, including fences.
6. `.block_quote` children are blocks (it is a container, §5.1); its span
   covers its lines' content with markers stripped, and text inside it
   slices the stripped content (marker bytes are excluded from child
   spans).
7. `.list` children are `.list_item` blocks; `.list_item` children are
   blocks, and list payloads record bullet/ordered type, marker metadata,
   ordered start, and tight/loose state.
8. `emphasis`/`strong`/`link` contain inline children. The leaf inline
   tags (`text`, `code_span`, `image`, `autolink`, `raw_html`, `soft_break`,
   `hard_break`) never have children.
9. `Data.text` always slices the document's source bytes; `raw_html` also
   borrows its bytes through `Node.span` and carries `Data.none`; the other
   text payloads (`code_span`, `code_block.content`, `code_block.info`,
   `link.href`, `link.title`, `image.src`,
   `image.alt`, `image.title`, `autolink.href`, `autolink.label`) are
   arena-owned copies — normalization (code-span content, escape
   resolution, alt flattening, the `mailto:` prefix) cannot be
   expressed as a source slice.
10. `span.start <= span.end`; all spans lie within the source.
11. Consecutive `text` children of one parent never have contiguous spans:
   adjacent source bytes land in one text node. Scanning artifacts (item
   boundaries, leftover delimiters, escape splits) merge at emission, so
   the normalized model has no text fragmentation (chosen behavior,
   docs/INLINE-PARSING.md §15; a consumed backslash or delimiter byte can
   still leave a gap, which is why `a\*b` stays two nodes).
12. `link` children never contain another `link` (links cannot contain
   links, §6.3), but may contain `image` nodes (an image description may
   contain links and images, §6.4); each link's children are a
   self-contained inline scope. `image` is a leaf whose `alt` is the
   description's inlines flattened to a string at parse time
   (docs/IMAGES-PARSING.md §3) — the image node carries no subtree.
   `autolink` is likewise a leaf (no children): its label is the raw
   content verbatim, and backslash escapes are inert inside autolinks
   (§6.5), so `data.autolink.label` is *not* escape-resolved — the
   payload is a verbatim arena copy (docs/AUTOLINKS.md §3).

## Growth path

Blocks: `table` (+ `table_row`, `table_cell`
with header flag).

`.code_block` is implemented for fenced Markdown blocks and is shared by the
planned indented-code frontend path.
`emphasis`/`strong`/`link`/`image`/`autolink` are implemented;
`raw_html` is implemented for Markdown inline tags; Textile keeps `<...>` as
plain text until a dialect-specific raw-HTML decision is made.
`emphasis`/`strong`
carry no special data — nesting already expresses it. `code_span`,
`link`, `image`, and `autolink` are the implemented inlines whose
payloads are **arena-owned**: `data.code_span` is the dialect-normalized
content,
`data.link` is the escape-resolved href/title, `data.image` is the
escape-resolved src/title plus the flattened plain-string alt, and
`data.autolink` is the verbatim href/label (escapes inert — not
escape-resolved, unlike `data.link`; the `mailto:` prefix is a copy)
(copies,
unlike `data.text` which borrows the source), because normalization
cannot be expressed as a source slice.
The `code_span` payload is the one shared IR whose bytes differ by
dialect: Markdown content is normalized per §6.1 (line endings become
spaces, one ASCII space stripped per side when the content begins and
ends with space but is not all spaces, tabs never stripped, backticks
dropped), while Textile `@code@` content is a verbatim arena copy —
Textile does not normalize spaces or line endings
(docs/TEXTILE-INLINE-CODE.md §3). The renderer is identical for both:
it HTML-escapes the payload as text, so each frontend's payload reaches
it already in its own dialect's final form. Reference links and
reference-style images (§4.7 + §6.3 reference forms) produce the same
`link` / `image` nodes as their inline forms — the definitions map is
parser-internal state, not a model concept, so the model is unchanged
by those milestones.

Attributes (Textile classes/ids/styles; Markdown image/link titles) will be
represented as an ordered attribute list on the node (`Data.attrs`), since
deterministic rendering requires deterministic ordering. The renderer will
emit them in a fixed documented order.

## Convergence table (slice)

| Markdown | Textile | shared node |
| --- | --- | --- |
| paragraph | paragraph / `p.` | `.paragraph` |
| ATX/Setext heading | `hN.` heading | `.heading` (level) |
| thematic break | (planned) | `.thematic_break` |
| fenced code block | `bc.` / `pre.` (planned) | `.code_block` (owned content/info) |
| `emphasis` / `strong` | `_x_` / `*x*` plus doubled runs | `.emphasis` / `.strong` |
| `` `code span` `` | `@code@` | `.code_span` (arena-owned payload: Markdown §6.1-normalized vs Textile-verbatim) |
| `[x](url "title")` | (Textile `"text":url`: later) | `.link` (arena-owned href/title) |
| `![alt](url "title")` | (Textile `!url(alt)!`: later) | `.image` (arena-owned src/alt/title) |
| `<scheme:...>` / `<a@b.c>` | (Textile has no autolink; literal) | `.autolink` (arena-owned href/label) |
| raw HTML tag (`<tag>`, comment, PI, declaration, CDATA) | literal text | `.raw_html` in Markdown; `.text` in Textile |
| plain text | plain text | `.text` |
| newline in paragraph | newline in paragraph | `.soft_break` (MD) / `.hard_break` (Textile) |
| `*x*` / `**x**` | `_x_` / `*x*` (plus `__x__` / `**x**`) | `.emphasis` / `.strong` |

The same HTML renderer consumes both; `tests/fixtures_test.zig` proves the
convergence (equivalent Markdown/Textile inputs render byte-identically).
