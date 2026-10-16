---
published_at: 2026-10-16T00:00:00Z
summary: "Planned opt-in Obsidian embed extension (![[target]] / ![[target|alias]]) in the Markdown frontend: parse-only typed node sharing the wikilink grammar, plus the embed resolver render policy (issue #189)."
---

# Embeds (extension, planned)

**Status:** planned — spec under review in issue #189; not implemented.
The family overview is at docs/OBSIDIAN-EXTENSIONS.md.  \
**Modules (planned):** `src/markdown.zig` (parse), `src/document.zig`
(model), `src/html.zig` (render)  \
**Options (planned):** `markdown.Options.embeds: bool = false` (parse);
`html.RenderOptions.embed_resolver` and `embed_resolver_ctx` (render);
CLI `--embeds`; C ABI `OLIVER_MD_EMBEDS = 1 << 11`

Obsidian documents embeds in Obsidian Help ("Embed files"; "Obsidian
Flavored Markdown" lists `![[Link]]` and `![[Link#^id]]`). knap 0.6.0's
`embed` filter emits `![[x]]` and `![[x|alias]]` (KNAP-FIDELITY.md §2,
§6).

**Parse only.** Oliver produces a typed reference. Resolving it to a
file, image, or transcluded note is the consumer's job: dogbed resolves
vault references at build time. Oliver never touches the filesystem
(AGENTS.md boundary 5).

## 1. Shape

- **Grammar.** `!` immediately followed by a wikilink body:
  `![[target]]` or `![[target|alias]]`.
- **Body.** The `[[…]]` body uses docs/WIKILINKS.md §1–§3 unchanged:
  - the target ends at the first `|` or the closing `]]`;
  - target and alias are trimmed, with internal whitespace kept;
  - the closer is the first unescaped `]]`, and it is greedy;
  - there is no `[[` inside the target;
  - the malformed battery (`![[]]`, `![[x|]]`, `![[|x]]`, `![[ ]]`,
    `![[a|b|c]]`, `![[a [[b]]`) stays literal.
- **Target bytes are opaque.** Oliver gives none of these special
  grammar:
  - headings: `![[Internal links#Heading]]`;
  - blocks: `![[Internal links#^b15695]]`;
  - image fragments: `![[Engelbart.jpg#outline]]`.
- **The alias is opaque too.** For images, Obsidian puts dimensions in
  the alias position (`![[Engelbart.jpg|100x145]]`,
  `![[Engelbart.jpg|100]]`), and for notes the alias is display text.
  Oliver doesn't tell the two apart: both are `label`. Interpreting the
  label is the resolver's job (§4).

## 2. Recognition and precedence

- **Where it's recognized.** `![` already tokenizes as one `'!'`
  bracket item, so `![[` reaches link discovery as a `!`-bracket
  followed by a `[`-bracket. Embeds are recognized at that position,
  **ahead of image matching**.
- **Performance.** Recognition reuses the wikilink closer/opener scan
  memos in `discoverLinksAndImages`, so `![[![[![[…` storms stay linear.
- **Atomic fallback** (WIKILINKS §2). Once `![[` is seen, it either
  completes as an embed or is emitted as literal text, and the bracket
  machinery never re-visits it. `![[x]](u)` is the embed `![[x]]`
  followed by literal `(u)`.
- **Escapes.**
  - `\![[x]]` escapes the `!`, leaving `[[x]]`: a wikilink when
    `wikilinks` is on, otherwise literal.
  - `!\[[x]]` escapes the `[` and is never an embed.
- **`embeds` and `wikilinks` are independent flags.** They share
  implementation but enable separately:

| `embeds` | `wikilinks` | `![[x]]` | `[[x]]` |
| --- | --- | --- | --- |
| off | off | literal | literal |
| off | on | literal (today's behavior, verified) | wikilink |
| on | off | embed | literal |
| on | on | embed | wikilink |

- **Opacity.** Embeds are opaque in the same places wikilinks are
  (WIKILINKS §2): code spans and blocks, autolinks, raw HTML, link
  destinations and titles, and image src/alt/title.
- **Demotion.** An embed inside link text or an image description is
  demoted to literal text. This generalizes `demoteWikilinks` and
  prevents nested anchors and recursive alt text.

## 3. Model

New inline leaf tag `.embed`:

```zig
data.embed = .{
    .target: []const u8,  // trimmed source slice
    .label: ?[]const u8,  // trimmed alias source slice; null when absent
}
```

- The node span covers the whole `![[…]]`.
- Both payloads are source slices. Trimming narrows the span, so no copy
  is made.
- Like `.wikilink`, an embed never merges with adjacent text nodes.

## 4. Rendering

**Default (no resolver):** a deterministic placeholder that keeps the
reference machine-readable.

```html
<span class="embed" data-embed-target="Engelbart.jpg">Engelbart.jpg</span>
```

- The text is `label orelse target`, escaped as text. The target is
  escaped as an attribute value.
- HTML 4.01 Strict omits `data-embed-target`, following the precedent
  of footnote `data-*` in docs/HTML4-STRICT.md, so it renders
  `<span class="embed">…</span>`.

**Resolver.** `html.RenderOptions.embed_resolver` plus an opaque
`embed_resolver_ctx`. This mirrors `wikilink_resolver`: a comptime-known
function plus context, because the freestanding core has no closures.

```zig
const ResolvedEmbed = struct {
    kind: enum { link, image, text },
    href: []const u8 = "",     // link href / image src
    text: []const u8,          // link text / image alt / span text
    width: ?u32 = null,        // image only
    height: ?u32 = null,       // image only
};
// fn (target: []const u8, label: ?[]const u8, ctx: ?*const anyopaque) ResolvedEmbed
```

| `kind` | output |
| --- | --- |
| `.link` | `<a class="embed" href="{href}">{text}</a>` |
| `.image` | `<img class="embed" src="{href}" alt="{text}" width="W" height="H">`, emitting width/height only when set, as a void element per profile |
| `.text` | `<span class="embed">{text}</span>`, so a resolver can decline (for example, a missing file) |

**Why the resolver returns this shape:**

- **Images.** `![[pic.png]]` is the most common embed, so a link-only
  shape (as wikilinks use) is too weak. Width and height let the
  resolver apply Obsidian's `|100x145` sizing after interpreting
  `label`.
- **Structured data, never raw HTML.** `href` goes through the standard
  href escaping and percent-encoding policy, and all text is escaped.
  The XHTML fail-closed policy and the HTML 4.01 Strict gate therefore
  still hold.
- **No transclusion through the resolver.** A consumer that wants a
  note's rendered body renders that document itself.
- **Determinism and memory.** The resolver must be a pure function of
  `(target, label, ctx)`. Its returned memory must outlive the render
  call; the renderer never frees it (WIKILINKS §5).

## 5. Fallbacks (literal)

- The flag is off (the default).
- The WIKILINKS §3 malformed battery with a leading `!`.
- An unclosed `![[x`.
- `!\[[x]]`.
- An embed inside link text or an image description.

## 6. Interactions

- **Highlights** may contain embeds (`==![[x]]==`).
- **Callout titles and bodies** are inline-parsed, so embeds work in
  both.
- **GFM tables:** an unescaped `|` splits the cell before inline
  parsing, so `| ![[pic.png|100]] |` is two cells. This is the
  docs/WIKILINKS.md §7 caveat, with the same escaped-pipe behavior.
- **`smartypants`:** embed payloads join the exemption set.
- **Plain-text flattening:** `heading_ids` slugs use
  `label orelse target`. Image alt can't contain embeds (§2, demotion).
- **Front matter** is stripped before the body parses.

## 7. Fixtures (planned)

| fixture | covers |
| --- | --- |
| `embed-basic` | notes, headings and `^block` targets, images, image sizes, `#outline`, audio and PDF names, list items, callout bodies, table cells |
| `embed-literal` | the §5 battery |
| `embed-precedence` | `![[x]](u)`, link-text and image-description demotion, the §2 flag matrix (including wikilinks-only `![[x]]` staying literal), escapes |
| `embed-basic.strict.html` | the HTML 4.01 Strict placeholder |

Unit tests cover the default placeholder; a consumer resolver for each
`kind`, including width/height and ctx pass-through; the XHTML
well-formedness gate for every kind; and a 10,000-embed determinism
storm. Fuzz seeds cover `![[` runs.

## 8. Conformance status

Not implemented. When it lands it is off by default, and the CommonMark
0.31.2 corpus must stay 652/652 under `--gate`.
