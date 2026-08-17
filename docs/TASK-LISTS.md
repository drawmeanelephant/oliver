---
published_at: 2026-08-16T00:00:00Z
summary: The opt-in GFM task list items extension ([ ] / [x] / [X] checkboxes) in the Markdown frontend: shape, recognition rules, chosen behaviors, and rendering.
---

# Task lists (extension)

**Status:** implemented — opt-in Markdown dialect extension (issue #92,
milestone v1.1; ledger card E5).  \
**Modules:** `src/markdown.zig` (parse), `src/document.zig` (model),
`src/html.zig` (render)  \
**Options:** `markdown.Options.task_lists: bool = false` (parse; the
renderer needs no option — the `.task_checkbox` node carries the state)

Task lists are GFM's §6.5 extension: a checkbox run at the start of a
list item's content turns the item into a task item. The checkbox is a
disabled `<input type="checkbox">` element; the rest of the paragraph is
its label. GFM is a published spec and clean-room allowed; the
provenance record is docs/CLEANROOM.md. The extension is **off by
default**, so default-option output stays byte-exact CommonMark and the
652/652 gate is untouched.

## 1. Shape

A checkbox is exactly three bytes — `[ ]` (unchecked), `[x]`, or `[X]`
(checked) — immediately followed by a space or tab:

```text
- [ ] unchecked task
- [x] checked task
```

Rendered (GFM example 279 shape):

```html
<ul>
<li><input type="checkbox" disabled="" />unchecked task</li>
<li><input type="checkbox" disabled="" checked="" />checked task</li>
</ul>
```

The checkbox is a leaf inline node `.task_checkbox` whose span covers
the three bytes; `data.task_checkbox.checked` distinguishes the
`[x]`/`[X]` forms. The rest of the paragraph is ordinary inline content
(emphasis, links, and the other extensions work inside a label), so the
label is scanned after the checkbox and its trailing whitespace.

## 2. Recognition rules

A checkbox is recognized **only** when all of these hold:

1. `Options.task_lists` is on.
2. The block is the **first paragraph** of a **list item** — the item's
   first block, directly under the `.list_item` node. A checkbox in a
   later paragraph (after a heading or code block, say), in a plain
   paragraph, or anywhere outside a list item stays literal.
3. The checkbox is at the **very start** of the paragraph content. The
   container pass has already consumed the item's marker and content
   indentation, so "content start" is the first bytes of the item's
   first line; leading whitespace before the checkbox disqualifies it
   (the GFM examples always put the checkbox immediately after the
   marker).
4. A space or tab follows the `]`. Per the GFM spec the checkbox is
   "followed by whitespace"; a checkbox at the end of the content
   (`- [ ]` with nothing after) stays literal.

Checked and unchecked forms are case-consistent with GFM: `[x]` and
`[X]` both render checked; `[ ]` renders unchecked. Any other byte in
the second position (`[-]`, `[~]`, …) stays literal.

## 3. Rendering

The `.task_checkbox` node renders as a disabled checkbox input:

```html
<input type="checkbox" disabled="" />          <!-- [ ] -->
<input type="checkbox" disabled="" checked="" /> <!-- [x] / [X] -->
```

- The `disabled` and `checked` attributes are valueless (GFM's shape),
  in that fixed order.
- The `<input>` is a void element and follows the render profile:
  under `.xhtml` (and the CommonMark-reference `void_trailing_slash`
  default) it serializes with the trailing slash. GFM's own HTML output
  always uses ` />`; Oliver instead routes the void through its
  `html`/`xhtml` profile machinery (docs/XHTML.md), so the two profiles
  agree byte-for-byte here.
- The checkbox contributes **no** plain text: heading-slug extraction
  and image-alt flattening skip it (it never reaches either in
  practice — recognition is limited to list-item content starts).

## 4. Fixtures and tests

- Fixture pair: `tests/fixtures/markdown/ext-task-lists.md` /
  `ext-task-lists.html`, pinned through the all-extensions wall
  (`tests/fixtures_test.zig`).
- XHTML hermetic gate: `tests/xhtml_test.zig` pins the html and xhtml
  bytes and the well-formedness of a task list fragment.
- CLI: `oliver render --from markdown --task-lists` (scoped with the
  other Markdown-only flags) has an end-to-end test in `src/main.zig`,
  including the off-by-default control and the literal shapes.
