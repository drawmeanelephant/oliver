---
published_at: 2026-08-16T00:00:00Z
summary: Pre-implementation contract for YAML/TOML front-matter extraction with a parsed metadata object for all three frontends.
---

# Front matter (extension) — contract

**Status:** planned — contract only; nothing is parsed or stripped yet
beyond Cooklang's existing boundary handling. Implementation is tracked
as issue #66 (milestone v0.5, "The Green Pastures Release"), ledger card
F1, and the "front matter (extension)" row of the feature matrix
(docs/FEATURE-MATRIX.md).  \
**Modules:** new `src/frontmatter.zig` (shared pre-pass), `oliver.parse`
+ `ParseResult` (dispatch boundary), `src/cooklang.zig`
(`tryFrontmatter` convergence)  \
**Options (proposed):** `ParseOptions.frontmatter: enum { none, yaml,
toml } = .none` (shared by all three frontends)

## 1. Current state and provenance

Cooklang already owns **boundary-only** front matter: `tryFrontmatter`
in `src/cooklang.zig` sniffs `---` at index 0, preserves the raw payload
with exact spans (`Frontmatter { raw, span }`), emits the
`unclosed-frontmatter` diagnostic on a dangling fence, and — per the
docs — is *never faked as parsed YAML* (docs/COOKLANG.md,
FEATURE-MATRIX "YAML front matter | implemented (boundary only)"). The
Markdown/Textile frontends have no front-matter concept: at index 0,
`---` is a §4.1 thematic break and the rest is a paragraph.

This contract extends the boundary rule into parsing — but honestly:
the parsing is a **documented, bounded Oliver-chosen subset**, not a
reference YAML/TOML implementation (clean-room session to be recorded).
Anything outside the subset stays raw with a diagnostic; Oliver never
guesses.

## 2. Detection and stripping

- **Sniff at index 0:** an opening fence is a line whose first three
  bytes are `---` (YAML) or `+++` (TOML) — exactly at offset 0, no
  leading whitespace. BOM policy: **no BOM handling** (recorded).
- The closing fence is a line that is exactly `---` / `+++` with
  optional trailing whitespace. Line endings are handled by the shared
  line iterator (LF/CRLF/CR).
- **Strip before dispatch:** a shared pre-pass at the `oliver.parse`
  boundary removes the opening fence, the payload, and the closing
  fence from the bytes passed to the chosen parser. No frontend ever
  parses fence text; the clean body reaches Markdown, Textile, and
  Cooklang identically.
- **Unclosed opener:** the opener is not front matter; the bytes reach
  the parser unchanged (an index-0 `---` stays a thematic break, etc.)
  and the `unclosed-frontmatter` diagnostic fires — the Cooklang
  contract extended to all three frontends.

## 3. The option and the ambiguity

`ParseOptions.frontmatter` defaults to `.none`, and the reasons are
recorded here:

- At index 0, `---` is genuinely ambiguous with a §4.1 thematic break
  (`---` alone is a valid break; `---\ntitle: x` is a break + paragraph
  today). Opting in is the only unambiguous contract.
- `+++` at index 0 is not currently any CommonMark construct (a
  paragraph), so TOML has no conflict — recorded for completeness.
- Default `.none` keeps the corpus and every existing consumer
  byte-identical; the 652/652 gate is untouched.

## 4. The YAML subset

- **Top-level mappings only:** `key: value` lines at the base
  indentation; a key is non-empty, contains no `: `, and is followed by
  `:` plus a space/tab or end of line.
- **Scalars:** bare strings (no leading `*&!|>` YAML indicators), quoted
  strings (`"…"` with `\"`/`\\` escapes, `'…'` literal), integers
  (decimal, optional `-`/`+`), floats (decimal point or exponent), and
  the booleans/null as case-insensitive `true` / `false` / `null`.
- **Lists:** a `- item` line under a key (`key:\n- a\n- b`); items are
  scalars (nested list-of-lists and list-of-maps are outside the
  subset).
- **Nested maps:** a map value by indentation — the nested keys must be
  indented deeper than their parent key; the indent rule is pinned at
  **2 spaces** (a document may use one consistent deeper indent; the
  exact rule is "any consistent deeper indentation, pinned by fixture").
- **Comments:** a full-line `#` comment is skipped. Inline comments
  (`value # comment`) are outside the subset.

## 5. The TOML subset

- `key = value` with the same scalar vocabulary (TOML bare/quoted keys:
  `key`, `"key"`, `'key'`).
- `[table]` headers open a nested map; `[[array-of-tables]]` headers
  open a list of maps.
- Dotted keys (`a.b = 1`), multi-line strings, dates, and inline tables
  (`a = { x = 1 }`) are outside the subset.

## 6. Out-of-subset policy

- If **any** line of the payload fails the subset, the **entire payload
  stays raw and unparsed** — no partial metadata, nothing guessed — with
  one structured diagnostic (proposal: code
  `frontmatter-parse-unsupported`, span at the first offending line).
- The body strip still happens: front matter is never content, parsed or
  not.

## 7. Metadata model

```zig
pub const Metadata = struct {
    entries: []Entry, // arena-owned, document order
};
pub const Entry = struct { key: []const u8, value: Value };
pub const Value = union(enum) {
    scalar: []const u8, // raw lexical bytes — no coercion
    list: []Value,
    map: Metadata,
};
```

- Scalars keep their **raw lexical bytes** (`"42"` stays `42` as bytes,
  `true` stays `true`) — no type coercion, matching the Cooklang
  quantity philosophy.
- Duplicate keys: **last wins** (the YAML convention), pinned.
- `ParseResult` gains `metadata: ?Metadata` (null when there is no front
  matter or when the option is off). Cooklang's `Recipe` gains a parsed
  view beside `frontmatter.raw`.

## 8. Cooklang convergence

- `tryFrontmatter` moves onto the shared pre-pass; `Recipe.frontmatter`
  keeps its `raw`/`span` contract (serialization, scaling, and the menu
  view read the raw payload and must not change).
- With `ParseOptions.frontmatter` on, the Recipe additionally exposes
  the parsed metadata; scaling's `.servings` mode may later read the
  parsed view (out of scope here — behavior unchanged).

## 9. Diagnostics

- `unclosed-frontmatter` — existing Cooklang code, extended to
  Markdown/Textile when the option is on.
- `frontmatter-parse-unsupported` — new, when a payload is outside the
  subset (whole payload stays raw).

## 10. Acceptance and fixtures

- `---\ntitle: Hello\n---\n\n# Doc` parses to
  `metadata.title == "Hello"` with the body exactly `# Doc` →
  `<h1>Doc</h1>`, across markdown, textile, and cooklang.
- YAML subset fixtures: scalars (bare/quoted/typed), lists, nested maps,
  comments, empty front matter `---\n---` (must not panic — the CK2 fix
  is the precedent), `+++`/`---` fence correctness.
- TOML fixtures: `key = value`, `[table]`, `[[array-of-tables]]`.
- Out-of-subset fixture: payload stays raw + `frontmatter-parse-unsupported`.
- Unclosed-opener fixtures per frontend (`unclosed-frontmatter`).
- Default options: byte-identical output — 652/652 + full suite green.

## 11. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration). Cooklang boundary behavior is unchanged
until the option is on. The fixture wall lives at
`tests/fixtures/{markdown,textile,cooklang}/frontmatter-*`.
