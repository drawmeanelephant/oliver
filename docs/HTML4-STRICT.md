---
published_at: 2026-09-27T00:00:00Z
summary: "HTML 4.01 Strict fragment output: mappings, semantic tradeoffs, fail-closed cases, and the hermetic validation gate."
---

# HTML 4.01 Strict output profile

`html4_strict` is an opt-in serializer of the same Document or Recipe used
by HTML and XHTML. It does not change parsing, add a document wrapper, or
emit a DOCTYPE. Embed the fragment in an HTML 4.01 Strict document whose
encoding can represent its Unicode text, for example UTF-8.

```bash
oliver render --from markdown --to html4-strict < document.md
oliver render --from textile --to html4-strict < document.textile
oliver render --from cooklang --to html4-strict < recipe.cook
```

```zig
try oliver.html.render(allocator, &writer, &doc, .{ .profile = .html4_strict });
try oliver.cooklang_html.render(allocator, &writer, &recipe, .{ .profile = .html4_strict });
```

The C ABI uses `OLIVER_PROFILE_HTML4_STRICT = 2`; existing HTML (0) and
XHTML (1) values are unchanged. The default remains HTML.

## Differences from HTML and XHTML

| Construct | HTML 4.01 Strict output | Tradeoff |
| --- | --- | --- |
| Void elements (`br`, `hr`, `img`, `input`) | `<br>`, `<hr>`, `<img ...>`, `<input ...>` even if `void_trailing_slash` is set | HTML 4.01 SGML syntax, not XML syntax |
| Cooklang `article`, `section`, `aside` | `div`, preserving existing classes | No HTML5 sectioning outline; named sections remain flat `h2` headings |
| Cooklang `time` | `span class="timer"` | No machine-readable `datetime` |
| Cooklang `data-quantity`, `data-units`, `data-ref` | Omitted; quantities, units, names, and references remain visible text | Machine-readable quantity/units/reference contract is **not** available |
| Markdown footnote `section`, `data-*`, `aria-label` | `div class="footnotes"`; data markers omitted; backrefs keep their `href` and use `title="Back to reference N"` | No data markers; title is not a full replacement for the accessible name |
| Task-list `disabled=""`, `checked=""` | `disabled="disabled"`, `checked="checked"` | Required enumerated attribute tokens in the Strict DTD |
| GFM table-cell `align`, Textile `style`/`class`/`id` | Unchanged | These attributes *are* permitted by Strict |
| Textile flat table rows | Wrapped in `<tbody>`; HTML and XHTML remain flat | Strict requires an explicit table body in Oliver's output |
| GFM table with only a header row | The `<th>` row moves into `<tbody>` instead of a lone `<thead>` | Strict requires `TBODY+`; header cells remain `th` |
| Empty table in a caller-built document | `error.EmptyTableNotHtml4Strict` | No rows can satisfy the required table body |
| Ordered list starting at another number | `error.OrderedListStartNotHtml4Strict` | Strict has no `ol start`; renumbering would silently change meaning |
| Invalid explicit or generated `id` | `error.InvalidHtml4StrictId` | Strict IDs must start with an ASCII letter; anchors are never silently renamed |
| Repeated `id` (including auto-heading slugs and footnote anchors) | `error.DuplicateHtml4StrictId` | Strict IDs must be unique within a document |
| Markdown raw inline/block HTML, Textile `==`/`notextile.` and `pre.` | `error.RawHtmlNotHtml4Strict` under `raw_html = .allowed` | Verbatim source cannot be certified against the DTD |

For raw content, `raw_html = .escaped` emits escaped text and is allowed;
`raw_html = .rejected` keeps the existing `error.RawHtmlRejected` behavior.
Cooklang has no raw-HTML nodes. The CLI prints actionable messages for both
Strict-specific failures. The C ABI returns
`OLIVER_ERR_RAW_HTML_NOT_HTML4_STRICT = 6` and
`OLIVER_ERR_ORDERED_LIST_START_NOT_HTML4_STRICT = 7`, respectively.
Invalid IDs return `OLIVER_ERR_INVALID_HTML4_STRICT_ID = 8`.
Repeated IDs return `OLIVER_ERR_DUPLICATE_HTML4_STRICT_ID = 9`.
Empty tables return `OLIVER_ERR_EMPTY_TABLE_NOT_HTML4_STRICT = 10`.
Rendering to a streaming writer can have written earlier bytes when an
unsupported node is reached; discard the fragment on any render error.

## Validation and limits

`tests/html4_strict_test.zig` wraps representative fragments in a minimal
`html`/`head`/`title`/`body` document *only for testing*. The hermetic
`tests/html4_strict_valid.zig` gate checks the emitted element vocabulary,
per-element attributes, enumerated checkbox tokens, selected nesting rules,
and the required nonempty `tbody` under each table. It does not check every
DTD content-model cardinality or ordering constraint. The test corpus
exercises Markdown, Textile, Cooklang, and opt-in Markdown extensions. It
also asserts byte agreement with ordinary HTML where no Strict mapping
is required. The existing HTML fixture wall and XHTML paired tests still
run under `zig build test`.

This gate is **not** a general SGML validator or a proof of full DTD
conformance for arbitrary caller-built documents. The W3C HTML 4.01 Strict
DTD uses SGML features that an XML DTD parser such as `xmllint` cannot
read. A full DTD gate would require a pinned SGML validator and catalog
in CI. Do not use this profile to certify raw HTML, arbitrary manually
constructed node trees, or arbitrary invalid attribute values. No full
HTML document validity or accessibility guarantee is claimed by the
fragment serializer. Consumers needing the Cooklang `data-*` contract
should use `.html` or `.xhtml`, or consume the typed Recipe directly.

## Golden-file wall

`tests/html4_strict_goldens.zig` runs the entire committed fixture corpus
(`tests/fixtures/**`, every pair indexed in `fixtures_test.zig`) through
`--to html4-strict` under the same option family each entry uses, in three
asserted classes:

- **agree** — 278 fixtures whose strict output is byte-identical to the
  committed `.html` golden. No `.strict.html` file exists; the `.html`
  wall is the golden for both profiles.
- **divergent** — 106 fixtures where the profile owns a serialization
  delta (void-tag slashes, `tbody` wrapping, Cooklang HTML5-to-`div`
  mappings, footnote and task-list attribute forms). A committed
  `.strict.html` golden pins those exact bytes.
- **fail-closed** — 41 fixtures that cannot be expressed in Strict
  (36 verbatim-HTML shapes, 5 ordered lists starting other than 1); the
  renderer error is asserted per fixture.

The wall also re-renders every fixture through the default profile and
compares against the committed `.html` first, so any change that perturbs
HTML output fails the wall even when strict output still matches its
golden. The classification tables are generated by
`tools/gen-strict-goldens.py` (requires a built `zig-out/bin/oliver`);
re-run it after adding fixtures or changing a serialization delta.
