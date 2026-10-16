---
published_at: 2026-10-16T00:00:00Z
summary: "Planned opt-in Obsidian-flavor Markdown extensions — highlights, math, comments, embeds, callout folds — plus the obsidian preset: scope, surface, model impact, and recorded non-goals (issue #189)."
---

# Obsidian-flavor extensions (planned)

**Status:** planned — spec under review in issue #189; **not
implemented**. Nothing on this page or its feature pages changes current
behavior. Each feature lands in its own PR, and that PR moves its page from
planned to implemented.  \
**Feature pages:** [Highlights](HIGHLIGHTS.html) ·
[Math](MATH.html) · [Comments](COMMENTS.html) ·
[Embeds](EMBEDS.html) · [Callouts §10 (folds)](CALLOUTS.html)  \
**Provenance:** docs/CLEANROOM.md session 37

These are the Obsidian constructs that Oliver does not parse yet. The
existing Obsidian-adjacent extensions (wikilinks, callouts) set the
pattern this family follows. Every construct is **off by default** and
enabled per parse call, so default output stays byte-exact CommonMark
0.31.2 and the 652/652 gate is untouched.

## 1. Why these, and why in Oliver

Three consumers produce or carry these constructs:

- **knap → k4o.** The knap 0.6.0 filters `highlight`, `math` /
  `math_block`, `comment`, `embed`, and `callout` (with fold markers)
  emit them. This is recorded black-box in k4o's `KNAP-FIDELITY.md` §2.
- **Obsidian vaults → dogbed.** Vault source contains all of them.
  Obsidian lists them as its supported Markdown extensions (Obsidian
  Help, "Obsidian Flavored Markdown").
- **The k4o stopgap.** k4o's `--format oliver` substitutes raw HTML
  (`<mark>`, `<span class=math>`, `<!-- -->`) instead. That costs three
  things:
  - it needs `raw_html = .allowed`;
  - the XHTML profile fails closed on any `.raw_html`
    (`error.RawHtmlNotXmlWellFormed`), and HTML 4.01 Strict rejects it
    (`error.RawHtmlNotHtml4Strict`);
  - the constructs reach the Document as opaque raw HTML instead of
    typed nodes.

Parsing them in Oliver, under opt-in flags, makes them typed nodes that
render under every profile.

Current behavior, verified with the CLI on `main` @ 8e4dacb using
`--wikilinks --callouts`:

| construct | today |
| --- | --- |
| `==text==`, `==🔵text==` | literal |
| `$x$`, `$$…$$` | literal |
| `%%x%%` | literal |
| `![[x]]`, `![[x\|alias]]` | literal (`![` is not a wikilink opener) |
| `> [!note]+ Title`, `> [!note]- Title` | ordinary blockquote, with `[!note]+` as text |

## 2. Scope

| construct | syntax | flag | contract |
| --- | --- | --- | --- |
| highlights | `==text==`, colored `==🔴text==` | `highlights` | [HIGHLIGHTS](HIGHLIGHTS.html) |
| math | `$…$`, `$$…$$` inline, `$$` fenced block | `math` | [MATH](MATH.html) |
| comments | `%%…%%` inline, `%%` block | `comments` | [COMMENTS](COMMENTS.html) |
| embeds | `![[target]]`, `![[target\|alias]]` | `embeds` | [EMBEDS](EMBEDS.html) |
| callout folds | `> [!type]+`, `> [!type]-` | existing `callouts` | [CALLOUTS §10](CALLOUTS.html) |

## 3. Public surface

- **Parse:** new `markdown.Options` fields `highlights`, `math`,
  `comments`, `embeds`, each `bool = false`. Callout folds extend
  `callouts` and get no new flag.
- **Render:** `html.RenderOptions.embed_resolver` and
  `embed_resolver_ctx` (EMBEDS §4). Nothing else is added on the render
  side.
- **CLI:** `--highlights`, `--math`, `--comments`, `--embeds`, and the
  `--obsidian` preset (§4) on `oliver render --from markdown`. Like the
  existing extension flags, they are rejected for other frontends.
- **C ABI:** additive `OLIVER_MD_HIGHLIGHTS = 1 << 8`,
  `OLIVER_MD_MATH = 1 << 9`, `OLIVER_MD_COMMENTS = 1 << 10`,
  `OLIVER_MD_EMBEDS = 1 << 11`, plus an `OLIVER_MD_OBSIDIAN` mask.
  - Bits 0–7 are unchanged, and no new error codes are added.
  - The ABI renders only, so the new node tags never cross it.
- **Diagnostics:** one new code, `unclosed-comment` (warning;
  COMMENTS §5). It is the first diagnostic the Markdown frontend emits:
  `markdown.parse` already takes the `diags` list, but nothing appends
  to it today. The existing `render --diagnostics json` side channel
  surfaces it.

## 4. The `obsidian` preset

```zig
pub const obsidian: markdown.Options = .{
    .wikilinks = true,
    .embeds = true,
    .callouts = true,
    .highlights = true,
    .comments = true,
    .math = true,
    .strikethrough = true,
    .task_lists = true,
    .footnotes = true,
};
```

- **A constant, not a field.** Consumers write
  `.markdown = markdown.obsidian` or modify a copy. The CLI `--obsidian`
  flag expands to the individual flags, and the C header ships the
  matching `OLIVER_MD_OBSIDIAN` mask.
- **Membership follows Obsidian's own published list.** These are the
  syntaxes in Obsidian Help's "Supported Markdown extensions" table,
  plus LaTeX math, which the same page claims. GFM tables are always on
  in Oliver.
- **Not in the preset:**
  - `smartypants`, `definition_lists`, and `heading_attributes` are not
    Obsidian behavior.
  - `frontmatter` lives on the top-level `ParseOptions`, not on
    `markdown.Options`. Obsidian properties are YAML front matter, so
    consumers set `.frontmatter = .yaml` alongside the preset.
  - Block identifiers (`^id`) are in Obsidian's table but are not
    proposed here (§8).
- **Footnotes need the render side too.** The preset turns on
  footnote *parsing*; the footnotes section still renders only with the
  `footnotes` render option, as today.
- **Changing membership is a conformance change.** Changing the set
  changes output for every preset user, so a change is recorded on this
  page and in the release notes, never silently.

Why have a preset at all: k4o, dogbed, and Solipsist all want this exact
bundle. One named definition replaces three copies that would drift
apart.

## 5. Where each construct sits in the parser

Each construct joins an existing precedence family. No new machinery is
needed:

| family | existing members | joins |
| --- | --- | --- |
| first-opener-wins opaque inlines (§6.1/§6.5/§6.6) | code spans, autolinks, raw inline HTML | inline math, inline comments |
| delimiter runs (§6.2 flanking) | `*`/`_` emphasis, `~~` strikethrough | `==` highlights |
| double-bracket constructs, ahead of link/image brackets | wikilinks | embeds |
| fenced leaf blocks (§4.5) | fenced code | `$$` math blocks |
| end-condition blocks (§4.6 conditions 1–5) | HTML blocks | block comments |
| blockquote first-line payload | callout `[!type]` | the fold marker |

## 6. Document model impact and compatibility

**Additive. No model redesign.**

| addition | kind | payload |
| --- | --- | --- |
| `.highlight` | inline container (children: inlines) | `data.highlight.color: ?HighlightColor` |
| `.math_inline` | inline leaf | `data.math = .{ .tex, .display }` |
| `.math_block` | leaf block | `data.math = .{ .tex, .display = true }` |
| `.embed` | inline leaf | `data.embed = .{ .target, .label }` |
| `BlockQuote.callout_fold` | field on the existing payload | `enum { none, open, closed }` |
| comments | none | removed at parse time; no node |

**In-tree:** every exhaustive `switch` on `document.Tag` gains arms.
That covers `isBlock` / `isInline`, html.zig's leaf list and plain-text
flattening, image-alt flattening in markdown.zig, typography exemptions,
and rewrite.

**Downstream (the one real compatibility break):** a Zig consumer that
switches exhaustively on `document.Tag` stops compiling when tags are
added. dogbed pins Oliver by commit, so it sees this at upgrade time.

- The flags don't help here: the break comes from the enum growing, and
  whether the new codepaths run is irrelevant.
- So the release that adds the first new tag is a **minor version bump**
  with a release-notes callout.
- Open question 4 asks whether to declare `Tag` open by contract
  (consumers keep an `else` arm) before this lands.

## 7. Cross-construct interactions

Each feature page has its own §6 with the rest. These are the
cross-cutting ones:

- **Nesting:**
  - highlights contain any inline: `==[[x]]==`, `==![[x]]==`,
    `==$x$==`, `==*a*==`;
  - math and comments contain nothing parseable;
  - embeds have plain-text payloads.
- **Callout titles** are inline-parsed, so every inline construct here
  works in a title: `> [!faq]- ==Why== $x$`.
- **Link text and image descriptions:**
  - embeds are demoted to literal there, generalizing today's wikilink
    demotion and avoiding nested anchors;
  - highlights and math are allowed (`<mark>` and `<span>` are valid
    inside `<a>`).
- **Image `alt` flattening:** highlight → its text, math → its TeX
  source, embed → its source bytes, comment → nothing.
- **Heading slugs (`heading_ids` render option):** highlight → its text,
  math → TeX source, embed → `label orelse target`, comment → nothing.
- **`smartypants`:** math and embed payloads join the exemption set
  (docs/SMARTY.md). Highlight children get typography like any inline.
- **GFM tables:** row splitting (§4.10) happens before inline parsing,
  so an unescaped `|` splits the cell even inside math, a comment, or an
  embed alias. This is the caveat docs/WIKILINKS.md §7 already records.
- **Front matter:** stripped before the body parses, so none of these
  constructs is recognized inside it.

## 8. Not proposed (recorded so the question is closed)

- **Block identifiers** `^id` and block-reference resolution. They are
  in Obsidian's table, but knap doesn't emit them. That would be a
  separate spec.
- **Markdown image sizing** `![250](url)`. It would reinterpret
  CommonMark image alt text and is not proposed.
- **Embed resolution and transclusion.** Oliver parses the reference;
  consumers resolve it (EMBEDS §4). Oliver never touches the filesystem
  (AGENTS.md boundary 5).
- **Math typesetting** (TeX → MathML/SVG). Consumers run KaTeX/MathJax
  over the emitted markup.
- **Interactive folds** (`<details>`). See CALLOUTS §10 and open
  question 2.
- **An `obsidian` dialect** (`--from obsidian`). This is Markdown plus
  options, not a new frontend.

## 9. Recorded: an HTML *input* frontend is out of scope

**Decision: an HTML input frontend does not belong in Oliver.**

Three reasons:

1. **The k4o need sits in the engine, not the parser.** The knap
   filters that need HTML *input* are `html_to_json` and `remove_html`.
   They need DOM globals, and upstream itself moves them into
   `knap/html`. KNAP-FIDELITY.md marks them blocked even inside k4o.
   The HTML-cleanup filters k4o does plan (`strip_tags`, `remove_attr`,
   `replace_tags`, …) work on *template data* during rendering and need
   only a tag/attribute token stream. That is engine-side work k4o owns,
   not a bytes→Document parse.
2. **It fails Oliver's admission test** (a published spec, a
   conformance wall, and bytes→typed Document; docs/KNAP.md §1). "Tag
   soup" has no conformance wall short of the WHATWG HTML parsing
   algorithm, which is a browser-engine-sized commitment.
3. **No consumer asks for it.** Nobody needs arbitrary HTML turned into
   a Markdown-shaped Document.

If a consumer ever needs HTML normalized, that is a separate library
upstream of Oliver, behind the same boundary as Knap.

## 10. Test plan (aggregate)

Each feature page lists its fixtures. Across the family:

- **Fixture pairs** in `tests/fixtures/markdown/`, indexed in
  `tests/fixtures_test.zig` (docs/TESTS.md fixture convention), plus
  `.strict.html` goldens where HTML 4.01 Strict differs (highlights,
  embeds).
- **The XHTML well-formedness gate** covers every new node and every
  embed resolver kind.
- **Unit tests:** node shapes and spans; behavior with each flag
  disabled; preset equivalence (`obsidian` equals the individual
  flags); the `unclosed-comment` diagnostic; C ABI bits 8–11 and the
  mask.
- **Determinism and fuzzing:** a 10,000-node storm per construct, and
  fuzz seeds for `=`, `$`, `%`, and `![[` runs in `tests/fuzz.zig`.
- **Gates for every implementation PR:**
  - `zig build test` on Zig 0.16.0 and 0.17.0;
  - `zig build spec-conformance -- spec.txt --gate` (652/652 with
    default options);
  - `zig build c-example-run`.

## 11. Open questions

1. **Math output delimiters.** Emit bare TeX inside the `math` span/div
   (this spec), or wrap it in `\(…\)` / `\[…\]` for zero-config
   KaTeX/MathJax auto-render (MATH §4)?
2. **Fold rendering.** A class only (this spec), or also an opt-in
   `<details>`/`<summary>` render flag?
3. **Severity of `unclosed-comment`.** `warning` (this spec) or `note`?
4. **`Tag` stability.** Declare `document.Tag` open by contract before
   the first new tag lands?
5. **k4o-side fix.** KNAP-FIDELITY.md contradicts itself on `embed`:
   §2 and §7 say excluded, §6 says implemented. This needs fixing in
   k4o; Oliver's spec doesn't depend on the answer.

## Sources

User-facing documentation and published specifications only. The record
is in docs/CLEANROOM.md session 37:

- Obsidian Help: "Obsidian Flavored Markdown", "Basic formatting syntax",
  "Advanced formatting syntax", "Callouts", "Embed files";
- the Pandoc User's Guide (`tex_math_dollars`);
- k4o `KNAP-FIDELITY.md` (black-box knap 0.6.0 output);
- CommonMark 0.31.2;
- GFM §6.5.
