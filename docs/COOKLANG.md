# Cooklang frontend: design contract

Status: **CK1 — design and provenance contract** (see docs/WORK-LEDGER.md).

Oliver gains a first-class Cooklang (`*.cook`) frontend: bytes → a typed
`Recipe` semantic model with precise source spans and structured
diagnostics, plus an optional deterministic HTML rendering policy. This
document records the source hierarchy, the provenance of every upstream
artifact used, the chosen design, and the boundary between Cooklang
language semantics and ecosystem application behavior.

## 1. Mission and boundary

Oliver parses Cooklang. It does not cook.

```
Oliver:  bytes -> typed Recipe semantics -> optional deterministic
         serialization/rendering
Boris:   files, metadata authority, graph, recipe-reference resolution,
         templates, routes, publication, indexes, collection semantics,
         output policy
```

- Cooklang parsing has **no filesystem, network, or global-state
  dependencies**. Recipe references (`@./sauces/Hollandaise{150%g}`) are
  parsed as semantic references — the path string is preserved; resolving
  it against a recipe corpus is a consumer responsibility.
- The current spec's YAML front matter is recognized at its boundary and
  preserved as a raw borrowed payload with exact spans. Oliver does **not**
  parse arbitrary YAML (it has no YAML layer, and faking a subset would
  corrupt Boris's metadata authority). The canonical conformance harness
  (a dev-only tool) reads the corpus's flat `key: value` forms only.
- Application/ecosystem behavior — shopping lists, checked state, pantry,
  aisles, image discovery, collection indexing, search, meal scheduling,
  scaling *application logic*, publication — is explicitly out of scope
  (conventions.md documents these as ecosystem conventions, not language).
  `.menu` files are valid Cooklang (sections + recipe references) and parse
  through the same frontend; no meal-planning logic is built.

## 2. Source hierarchy and provenance

The mission's hierarchy, with the exact upstream artifacts used:

1. **Published language specification** — https://cooklang.org/docs/spec/
   (fetched 2026-08-13): ingredients, steps, comments, metadata,
   cookware, timers, notes, sections, shorthand preparations, recipe
   references.
2. **Formal EBNF** — `cooklang/spec` `EBNF.md`, commit
   `6c4788644004e604ae1da110af6d2400e3c9c7b0` — **explicitly marked
   "WIP, the EBNF is outdated and doesn't contain latest changes yet"**
   (recorded conflict in §4).
3. **Canonical test corpus** — `cooklang/spec` `tests/canonical.yaml`
   (`version: 7`), same commit, **MIT licensed** (LICENSE in the same
   repo). 60 tests covering text/ingredient/cookware/timer semantics and
   metadata. Fetched via raw.githubusercontent.com at the pinned commit;
   provenance recorded in docs/CLEANROOM.md session 21 and this doc.
4. **Official examples/user docs** — `cooklang/spec` `examples/*.cook`
   (4 recipes), same commit.
5. **Conventions documentation** — `cooklang/spec` `conventions.md`,
   same commit — used **only** for explicitly conventional behavior
   (`.menu` files, scaling semantics that must be *preserved*, canonical
   metadata keys). Scaling *application logic* is deferred.

Released spec proposals used for the current syntax of features absent
from the corpus and the outdated EBNF (both marked **Released** in the
same repo, same commit):

- `proposals/0005-note-blocks.md` — the `>` note block.
- `proposals/0006-sections.md` — `=` section headers.

No parser implementation source was consulted (no cooklang-rs, no
CookCLI internals, no tree-sitter grammar, no third-party parsers). See
docs/CLEANROOM.md session 21 for the full record.

## 3. The typed Recipe model

Cooklang is semantically richer than prose markup, so it does **not**
converge on the Markdown/Textile `document.Document` node tree. It has
its own typed model in `src/cooklang.zig`, reusing Oliver's
infrastructure (spans, diagnostics, arena ownership, byte borrowing,
`source.Lines`, unicode predicates, allocators/writers).

```
Recipe
  source: source.Source            (borrowed bytes)
  arena: ArenaAllocator            (owns nothing but the block list itself;
                                   text payloads are borrowed slices)
  frontmatter: ?Frontmatter        (raw YAML payload + exact spans)
  blocks: []Block

Frontmatter { raw: []const u8, span: source.Span }

Block = union(enum) { step: Step, section: Section, note: Note }

Section { name: []const u8, name_span, span, blocks: []Block }
Note    { text: []const u8, span }
Step    { parts: []Part, span }

Part = union(enum) {
  text:      []const u8 (borrowed, span),
  ingredient: Ingredient,
  cookware:   Cookware,
  timer:      Timer,
  line_break: void,
}

Ingredient {
  name: []const u8, name_span: Span,
  quantity: ?[]const u8,   // source text inside {} before %; null when absent
  units:    ?[]const u8,   // source text after %; null when absent
  preparation: ?[]const u8, // shorthand ( ... ) after the braces
  is_recipe_reference: bool, // name begins with "./"
  span: Span,               // whole token (marker through closing })
}
Cookware { name, name_span, quantity: ?[]const u8, span }
Timer    { name, quantity: ?[]const u8, units: ?[]const u8, span }
```

Design decisions:

- **Quantity is source text, never coerced.** `@thyme{few%sprigs}` keeps
  `"few"`; `#frying pan{two small}` keeps `"two small"`; `@milk{1/2%cup}`
  keeps `"1/2"`. A derived numeric view (`numeric: ?Number` where Number
  is int/decimal/fraction) is exposed **only** for pure numeric forms
  (`2`, `1.5`, `01/2` does **not** qualify) so the canonical harness and
  future scaling can compare canonically without losing the source text.
- **Canonical defaults are applied by the conformance harness, not the
  model.** `@chilli` (no braces) has `quantity: null` in the model; the
  canonical semantics default ingredients to `"some"`, cookware to `1`,
  timers to `""`. The harness maps null per type; the model stays
  faithful to the source.
- **Comments are omitted from the semantic tree** (canonical evidence:
  `-- testing comments` parses to `steps: []`). They are consumed as
  trivia; every semantic node retains exact source spans.
- **Notes and sections are blocks, not steps.** Note text is plain text
  (not scanned for ingredients/cookware/timers — proposal 0005: notes are
  "not part of the cooking steps"). Section titles are plain text
  (proposal 0006: "The text of the section title is not parsed for
  ingredients or cookware"). Steps after a section header belong to that
  section until the next header or EOF; steps before any header are
  top-level.
- **Steps are paragraphs.** Blank-line-separated. Multi-line steps join
  with a single space (canonical `testCommentsAfterIngredients`:
  newline → space); a line ending in `\` produces an explicit
  `line_break` part (current spec "Forced line breaks").
- **Recipe references are a flag on Ingredient**, not a separate node:
  the syntax is the `@` ingredient syntax; the reference-ness is in the
  name shape (`./` prefix, per conventions.md: "paths are relative to the
  root recipe directory, without the .cook extension").

## 4. Grammar decisions and recorded conflicts

Every decision below is a *choice* recorded here, pinned by tests in
src/cooklang.zig and/or fixtures, never an accident.

- **EBNF vs current spec.** The EBNF is explicitly outdated: it lacks
  YAML front matter (its `metadata = ">", ">", ...` is the pre-frontmatter
  form), sections, shorthand preparations, and recipe references. The
  current spec + released proposals (0005, 0006) are authoritative for
  those. Where the EBNF is silent, the corpus and spec govern.
- **Multiword lookahead.** The EBNF's `multiword component = word,
  { text item - "{" }-, "{", ...` is outdated on this point: taken
  literally it makes `@salt and @pepper{1%tsp}` name the whole run up to
  the first `{`, but the current spec page's own example — "Add @salt
  and @ground black pepper{}" — proves `@salt` must stay single-word.
  The chosen rule (pinned by Oliver-owned tests): the name region runs
  to the first `{` **but stops early at a following token marker
  (`@`/`#`/`~`), at P-category punctuation, or at a `-`-free boundary**
  (hyphens and the `.`/`/` of recipe-reference paths are name
  characters, as the corpus's `#7-inch nonstick frying pan{ }` requires
  — and `-` itself ends a *single-word* name, since it is Pd and the
  EBNF's `word` excludes all P categories). So `@salt and @pepper{1%tsp}`
  is two ingredients; `@salt, @ground black pepper{2}` keeps `@salt`
  single-word at the comma; `@1000 island dressing{ }` keeps the whole
  phrase.
- **Single-word boundary = Unicode whitespace (Zs + TAB) or P-category
  punctuation only.** Symbols (S categories) are *not* boundaries — the
  corpus's `@🧂` (So category) requires this. A new P-only predicate in
  `src/unicode.zig` backs this (deliberately generalized shared
  primitive; see CLEANROOM session 21).
- **Invalid tokens degrade to text, not errors.** `Message me @ example`
  → one text part (corpus: invalid single/multi-word tests are text).
  The marker must be immediately followed by a word character.
- **Block comments** `[- ... -]` may span lines (EBNF). An unclosed `[-`
  with no `-]` to end of input is **literal text** (the construct fails
  to form — the same literal-fallback policy; no diagnostic, because the
  corpus treats failed constructs as text).
- **Frontmatter** requires both fences: the file's first line must be
  `---` (trailing whitespace/CR allowed) and a later line must be
  exactly `---`. Without a closing fence, the opener is ordinary step
  text (narrowest reading of the spec's "add --- at the beginning of a
  file and --- at the end"). `hello ---` mid-file is not a fence
  (corpus `testMetadataBreak`).
- **Line comments** `--` run to end of line; the space *before* `--`
  remains text (corpus: `"  and some text"` from `" "` + newline-space +
  `"and some text"`).
- **NUL / malformed UTF-8**: bytes are opaque; the P/whitespace
  predicates classify only valid decodable code points, so malformed
  sequences fall through as name/text bytes (Oliver's byte contract;
  NUL is not whitespace/punctuation, so it stays in runs).

## 5. Diagnostics

Malformed input follows the established Oliver frontend philosophy:
where the dialect permits, degradation to text **is** the documented
behavior (corpus-confirmed). Two tiers, both literal-fallback:

- **Corpus-pinned near-misses stay silent.** `@ example{}`, `~ {5}`,
  `~ 5`, `hello ---` mid-file — the corpus proves these are *correct*
  Cooklang text, so they produce no diagnostics at all.
- **Structural malformation warns.** Where the source clearly intends a
  construct that cannot be satisfied, the construct degrades to literal
  text (unchanged parse) **and** a warning diagnostic carries the exact
  location so consumers can surface it:
  - `unclosed-braces` — a `{` with no `}` on the line.
  - `unclosed-preparation` — a `(` immediately after a token's `}` with
    no `)` on the line (the `(` stays text; the token still parses).
  - `unclosed-block-comment` — a `[-` with no `-]` anywhere in the step.
  - `unclosed-frontmatter` — a leading `---` fence never closed (the
    opener stays ordinary step text).

Diagnostics are `severity: warning`, carry 1-based `offset`/`line`/
`column` plus the half-open byte `span`, and are allocated in the
recipe's arena (owned by the result). Resource/API failures (OOM, input
too large) remain Zig errors from the parse entry point, never
diagnostics.

## 6. Public API and CLI

- `oliver.cooklang.parse(allocator, input, options) -> CooklangResult`
  where `CooklangResult { recipe: Recipe, diagnostics: []Diagnostic }`.
  This is an explicit entry point because the result type is a typed
  Recipe, not a `document.Document` — shoehorning it into
  `oliver.parse(..., .markdown/.textile, ...)` would force the recipe
  semantics through an IR that cannot carry them. The existing
  Markdown/Textile API is untouched (source-compatible).
- CLI: `oliver render --from cooklang` renders the recipe through the
  Cooklang HTML policy.

## 7. HTML rendering policy (Oliver-owned, not Cooklang-conformant)

The Cooklang spec defines recipe semantics, not an HTML vocabulary.
Oliver therefore documents its own deterministic policy in
`src/cooklang_html.zig` — separate from `src/html.zig`'s single entry —
and never claims Cooklang conformance for it. Consumers (e.g. Boris)
may instead consume the `Recipe` IR directly and own layout.

Vocabulary (as implemented):

- recipe wrapper: `<article class="recipe">`
- step list: `<ol class="steps">` with `<li>`; a section contributes its
  own `<ol>` inside `<section>` + `<h2>`; a note renders `<aside
  class="note">`; a forced line break renders `<br>`
- ingredient: `<span class="ingredient" data-quantity="…"
  data-units="…">name</span>` — `data-quantity`/`data-units` emitted
  only when present; the name (or `./…` reference) is the content;
  preparations render `<span class="preparation">…</span>` inside their
  ingredient
- recipe reference: `<span class="recipe-ref"
  data-ref="./sauces/Hollandaise">./sauces/Hollandaise</span>` —
  distinct from a plain ingredient; never resolved
- cookware: `<span class="cookware" …>`, timer: `<span class="timer"
  data-quantity data-units>25 minutes</span>` (named timers render the
  quantity text; unnamed timers show the quantity value)
- text: HTML-escaped like Markdown/Textile text
- frontmatter is **not** rendered into HTML (it is data; the Recipe IR
  carries it)

## 8. Conformance wall

- **Canonical corpus**: `tools/cooklang_conformance.zig` runs every test
  in `tests/cooklang/canonical.yaml` (vendored from the pinned commit,
  MIT, provenance in this doc and docs/CLEANROOM.md) through
  `cooklang.parse`, comparing parts and metadata against the canonical
  expectations (YAML numbers compared via the derived numeric view;
  YAML strings via source text; null quantity mapped to the canonical
  default per type). Registered as `zig build cooklang-conformance`.
- **Owned tests**: 31 unit tests in `src/cooklang.zig` (exact spans and
  model shape, every semantic family, diagnostics, bounded behavior),
  fixture pairs in `tests/fixtures/cooklang/` (input + expected HTML:
  `cooklang-basic`, `cooklang-sections`, `cooklang-frontmatter`,
  `cooklang-literal`), and adversarial/resource tests in
  `tests/fixtures_test.zig` (huge delimiter runs, thousands of
  ingredients, deep preparations, an unterminated block comment, many
  steps/sections, a 100 KB single line) proving deterministic output and
  no pathological rescans.
- **Regression wall**: the CommonMark gate stays 652/652 with 0
  mismatches; the Textile suite stays green; `zig fmt --check` clean.

## 9. Explicitly deferred (documented, not built)

Canonical Cooklang serializer (stretch, after the model is proven);
richer generic HTML recipe renderer; `.menu` profile support beyond "it
already parses"; a pure `scaleRecipe()` semantic operation; and all of
conventions.md's application features (shopping lists, pantry, aisles,
image discovery, search, meal scheduling, publication). These are
consumer/ecosystem responsibilities, per §1.
