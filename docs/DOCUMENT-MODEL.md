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

`Tag` in the slice: `document`, `paragraph`, `heading`, `text`,
`emphasis`, `strong`, `code_span`, `link`, `image`, `soft_break`,
`hard_break`. Blocks and inlines are distinguished by `Tag.isBlock` /
`Tag.isInline`. `Data` carries `heading` level (1..6), the borrowed
`text` slice, the arena-owned `code_span` content, the arena-owned `link`
href/title, or the arena-owned `image` src/alt/title.

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
4. `emphasis`/`strong`/`link` contain inline children. The leaf inline
   tags (`text`, `code_span`, `image`, `soft_break`, `hard_break`) never
   have children.
5. `Data.text` always slices the document's source bytes; the other text
   payloads (`code_span`, `link.href`, `link.title`, `image.src`,
   `image.alt`, `image.title`) are arena-owned copies — normalization
   (code-span content, escape resolution, alt flattening) cannot be
   expressed as a source slice.
6. `span.start <= span.end`; all spans lie within the source.
7. Consecutive `text` children of one parent never have contiguous spans:
   adjacent source bytes land in one text node. Scanning artifacts (item
   boundaries, leftover delimiters, escape splits) merge at emission, so
   the normalized model has no text fragmentation (chosen behavior,
   docs/INLINE-PARSING.md §15; a consumed backslash or delimiter byte can
   still leave a gap, which is why `a\*b` stays two nodes).
8. `link` children never contain another `link` (links cannot contain
   links, §6.6), but may contain `image` nodes (an image description may
   contain links and images, §6.7); each link's children are a
   self-contained inline scope. `image` is a leaf whose `alt` is the
   description's inlines flattened to a string at parse time
   (docs/IMAGES-PARSING.md §3) — the image node carries no subtree.

## Growth path (planned tags, not yet implemented)

Blocks: `block_quote`, `list`, `list_item` (ordered/unordered is a `Data`
field, e.g. `list: { ordered: bool, start: ?u32 }`), `code_block` (fenced /
indented, info string), `thematic_break`, `table` (+ `table_row`, `table_cell`
with header flag), `raw_html` (under policy).

Inlines: `autolink`, `raw_inline` (under policy).
`emphasis`/`strong`/`link`/`image` are implemented; `emphasis`/`strong`
carry no special data — nesting already expresses it. `code_span`,
`link`, and `image` are the implemented inlines whose payloads are
**arena-owned**: `data.code_span` is the §6.1-normalized content,
`data.link` is the escape-resolved href/title, and `data.image` is the
escape-resolved src/title plus the flattened plain-string alt (copies,
unlike `data.text` which borrows the source), because normalization
cannot be expressed as a source slice. Reference links and
reference-style images (§4.7 + §6.6 reference forms) produce the same
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
| ATX `#` heading | `hN.` heading | `.heading` (level) |
| `emphasis` / `strong` | (Textile inline markers: later) | `.emphasis` / `.strong` |
| `` `code span` `` | (Textile `@code@`: later) | `.code_span` (arena-owned content) |
| `[x](url "title")` | (Textile `"text":url`: later) | `.link` (arena-owned href/title) |
| `![alt](url "title")` | (Textile `!url(alt)!`: later) | `.image` (arena-owned src/alt/title) |
| plain text | plain text | `.text` |
| newline in paragraph | newline in paragraph | `.soft_break` (MD) / `.hard_break` (Textile) |
| `*x*` / `**x**` | `_x_` / `*x*` (Textile, planned) | `.emphasis` / `.strong` |

The same HTML renderer consumes both; `tests/fixtures_test.zig` proves the
convergence (equivalent Markdown/Textile inputs render byte-identically).
