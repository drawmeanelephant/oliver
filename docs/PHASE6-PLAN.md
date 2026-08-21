# Phase 6 — Rotkeeper Boundary Rationalization (S1–S5) — Plan & Notes

**Status:** planning only, no code changes yet  
**Date:** 2026-08-21  
**Source of truth:** `home/content/docs/oliver-contract.md:160` (rotkeeper, v1.10) + `bones/scripts/rc-oliver-adapter.sh` + `bones/scripts/rc-render.sh` + `bones/scripts/rc-test.sh`  
**Pin:** `OLIVER_PIN=6edb520cabb31220995e676a95bf59cfb0e1ce4b` (`rotkeeper/scripts/setup.sh:76`)  
**Open issues:** #107 (S1 meta), #108 (S2 wrap), #109 (S3 link rewrite), #110 (S4+S5 plan+manifest)

This doc records the pre-implementation review for the four open issues so the slices can land in one bump with no churn. It does not change behavior; it is the planning gate before any `src/` edit.

---

## 1. What the contract says today (no-OLIVER on current pin)

| Slice | What moves to Oliver | Fallback on `6edb520c` | Contract line | File that owns fallback today |
|-------|----------------------|------------------------|---------------|-------------------------------|
| S1 | `oliver meta --from <fmt> --format json < file > meta.json` (stdin → stdout JSON) + auto-strip in `oliver render` | `yq --front-matter extract` + `awk 'NR==1=="---" {skip; next} skip && $0=="---"{skip=0; next} !skip'` | `oliver-contract.md:79-103` + `rc-oliver-adapter.sh:91-129` | `rc-oliver-adapter.sh:99-120` (probe `oliver meta --help`) |
| S2 | `oliver wrap --template <file> --meta-json <json> --assets-root <prefix> --body <file> > page.html` (7-token dialect) | GAWK `literal_replace` + `evaluate_if` + `html_escape` | `oliver-contract.md:115-145` | `rc-oliver-adapter.sh:356-482` |
| S3 | `oliver render --from <fmt> [--to xhtml]` rewrites `href/src` `.md/.textile/.cook → .html` at AST level | GAWK regex `/(href|src)=("|\x27)([^"\x27]+)("|\x27)/` + suffix replace | `oliver-contract.md:160` + `rc-oliver-adapter.sh:77-89, 288-353` | `rc-oliver-adapter.sh:296-352` + `rc-test.sh:391-414` |
| S4 | `oliver plan --content-dir … --output-dir … --template-dir … --meta-dir … --default-template <file> --oliver-bin <bin> --root-dir <dir> --dry-run <bool> --verbose <bool> > batch.tsv` (13 cols, collision abort, `ASSETS_ROOT` depth) | Bash `find` + `strip_source_ext` + `rk_up_dirs` + `declare -A EXPECTED_OUTPUTS` collision check | `oliver-contract.md:162` | `rc-render.sh:289-358` |
| S5 | `oliver manifest --manifest <file> --add <rel>` (dedup) + `oliver manifest --manifest <file> --verify` | `grep -Fxq` / `echo >> manifest` | `oliver-contract.md:164` | `rc-render.sh:136-153` |

Harness shape (`rc-test.sh`):

* Hermetic (always): 3 layout passes `crypt`/`busy`/`sterile` through a `fake_oliver` that already mimics S1–S5 (so the adapter pipeline is green on the current pin). Checks: ugly-edge-case.md 8 link cases, `smoke-fixture-expected.html` golden body, `v051-test` escaping/sidecar, S1 multiline+scalar-only+line-1 rule, S2 custom template + `$if$` empty-removal + unknown-token verbatim, S3 rewrites, S4 `plan --help`, S5 manifest dedup.
* Real-`oliver` (when present, `RK_STRICT=1` gates it green in CI): re-renders same sources through the real binary; on S1–S5 the probe skips with `"binary lacks <cmd> (expected on pin 6edb520c, SX will bump)"` until performance is succeeded.
* Contract corpus: `bones/scripts/tests/fixtures/oliver-contract/{contract-inline.md,contract-blocks.md,contract-table.md}` rendered through real Oliver; asserts GFM tables, bold/autolink/entity/code-span, blockquote/ol/hr, etc. `RK_STRICT=1` + `xmllint` gates the XHTML profile.

---

## 2. Sequencing — why one bump, strict order, but S1→S2→S3→S4→S5

* The contract orders S1 first for a reason: without `oliver meta`, `oliver render` can’t reliably auto-strip frontmatter and the adapter’s `awk` remains authoritative. S1 unlocks the invariant “render never sees frontmatter bytes.”
* S2 depends on S1’s `meta.json` shape (the 7 fields). GAWK currently builds `wrap_meta` from 5 fields via `jq`; the contract wants 7 → wrap must read the S1 JSON. Implementing wrap before meta would force a second change.
* S3 is independent of S1/S2 at the CLI surface, but the contract-corpus harness asserts rewritten links (`href="my-first-page.html"`). If S1/S2 ship without S3, the corpus moves from “hermetic-only” to “real-OLIVER-only” and `RK_STRICT=1` would fail.
* S4 (`plan`) determines where `soul` lives (`meta_dir/$(strip_source_ext rel).soul.md`) and what `ASSETS_ROOT` is. S5 (`manifest`) logs each `outfile`. S4 must be correct before S5’s verify matters. Both are pure filesystem planning — no markup — so they can be built last, but they must ship together so the `rc-render.sh` batch TSV (13 columns) is the single wire.

**Recommended branch order:** one branch, 4 commits (S1, S2, S3, S4+S5) → one PR, one pin bump in `rotkeeper/scripts/setup.sh:76`. Do not bump the pin per slice; each intermediate pin would be green only in hermetic mode and would confuse `RK_STRICT=1` bisect.

---

## 3. Cross-cutting risks & invariants to preserve

1. **No filesystem in the core** (`docs/ARCHITECTURE.md: "core has no host dependencies: no filesystem, clock, network, or threads — ready for later WASM embedding"`). S4/S5 read directories and write `manifest.txt`, S2 reads `template`/`meta-json`/`body` files. These must live in `src/main.zig` (the CLI adapter), not in `src/oliver.zig`/`src/frontmatter.zig`/`src/html.zig`. Library stays embeddable; CLI stays a thin adapter.
2. **BOM / line-1 rule:** S1 issue body says “line 1 `---`, no BOM, `...` not honored”. The shared `frontmatter.zig:preprocess` already handles CRLF via `source.Lines` and rejects BOM implicitly (first three bytes are `0xEF 0xBB 0xBF`, not `---`), but it currently allows a BOM-free file with a leading blank line to fail open (no block) — which matches the harness’s `frontmatter-s1b.md` expectation. Keep that; add a test that `"\xEF\xBB\xBF---\ntitle: x\n---\n"` yields `metadata==null` and body is the raw bytes.
3. **Scalar-only & `null`→"" contract:** Existing `frontmatter.zig` supports nested maps/lists/double-quoted decoding. S1 wants “scalar strings only, lists/maps ignored, `null`/empty → `""`” for the 7 fields. Do **not** restrict `frontmatter.zig` itself; instead gate inside the `oliver meta` command: parse via `frontmatter.preprocess(... parse=true ...)` then project only `title/description/author/date/template/palette/render_profile` where `Value == .scalar`, else `""`. `Value.list`/`Value.map` → `""`.
4. **`...` not honored:** Current `preprocess` closes only at the same fence (`---` ↔ `---`, `+++` ↔ `+++`). It does not treat `...` as a close, which already matches the contract. Add a pinning test: `"---\ntitle: x\n...\n---\nbody"` → block is `"title: x\n...\n"` + body is empty string, not `"title: x"` + body `"...\n---\nbody"`.
5. **`html_escape` is Oliver’s renderer escape, not shell escape:** Contract says `& < > " '` → `&amp; &lt; &gt; &quot; &#39;` for 5 fields, `$assets_root$`/`$body$` literal. Reuse `html.zig:writeEscaped` (text policy: `&`/`</>/"/NUL`) plus the single-quote `&#39;` the GAWK `html_escape` uses. Verify `title="Cats & Dogs <v0.5.1>"` → `Cats &amp; Dogs &lt;v0.5.1&gt;`.
6. **Link rewriting must be AST-level, not regex.** The GAWK fallback regex leaks `<`/`>`/`%3C` stripping. At AST level the link’s `href`/`src` is already percent-decoded and entity-decoded (`src/markdown.zig` link dest/title, `src/html.zig:writeEscapedHref` re-encodes). The transform should be applied between `oliver.parse` and `oliver.html.render` by rewriting the document’s `link.href`/`link.src`/`image.src` leaves (and possibly `autolink.href` already contains `foo.md` text) — do not mangle rendered HTML bytes.
7. **`OLIVER_PIN` bump must re-run `rk-test.sh` under `RK_STRICT=1` and `xmllint`.** Issue bodies explicitly say “Pin: bump → re-run harness, update contract table.” Plan a CI matrix leg that builds Oliver `zig build`, installs it, then `bash rotkeeper.sh test` in rotkeeper’s checkout.

---

## 4. Issue #107 — `oliver meta` (S1) — Detailed notes

### CLI shape (from issue + rc-test.sh probe)
```
oliver meta --from <markdown|textile|cooklang> --format json < file.md > meta.json
oliver meta --help   # must exit 0, print "Usage: oliver meta --from ... --format json"
```
* `--from` is required, values exactly `markdown|textile|cooklang` (fail `error.Usage` otherwise).
* `--format` is required, value exactly `json` (only one format today; keeps the wire extensible).
* Reads stdin → writes stdout JSON. No file args; `rc-oliver-adapter.sh:101-102` does `< "$src_path"`.
* Exit 0 on success, 1 on usage error, never on frontmatter parse fallback — out-of-subset stays `""`.
* `oliver render --from <fmt>` still works with no flag change; its implementation will call the same `frontmatter.preprocess(..., mode=.yaml, parse=true, ...)` and `result.metadata` rather than the adapter’s `awk`.

### Input rules (contract + harness)
* **Leading YAML only:** `---` on line 1, column 1, no BOM, no leading blank line. First `---` opens, next `---` closes. `...` does **not** close (contract `oliver-contract.md:110`).
* **Scalar-only:** only the 7 keys matter; value must be a scalar. Lists/maps → treated as missing (`""`). This matches `rc-test.sh:612-621` (`tags: [ignored, list]` + `extra_map: {key: value}` ignored).
* **`null`→"" and empty →"" :** `yq -r '.title // ""'` already does this; Oliver’s JSON must emit `""` for `null`, missing, or out-of-subset. The fake uses `{"title": .title, ...}` → JSON `null` when missing; adapter normalizes `[[ "$doc_title" == "null" ]] && doc_title=""`. Oliver should emit `""` directly so the normalization stays but isn’t required.
* **BOM, `...`, sidecar precedence:** S1 does **not** handle sidecars; `rc-oliver-adapter.sh` stays authoritative for per-field `bones/meta/*.soul.md` (sidecar wins when non-empty and not `null`). S1 only extracts source file; sidecar is a second `oliver meta` call.

### Output shape
```json
{"title":"","description":"","author":"","date":"","template":"","palette":"","render_profile":""}
```
* Exactly those 7 keys, always present, always strings. No extra keys (adapter’s `yq eval '.'` validates shape).
* Values are raw lexical scalars (e.g. `"  hello "` stays `"  hello "`? Contract says scalar strings, HTML-escaped later in S2, not here; keep raw).
* JSON is stdout only; stderr is warnings (if any) but not body HTML.

### Where to implement
* New file `src/meta.zig` or `src/cli/meta.zig`? Prefer `src/meta.zig` (pure projection) + wired in `src/main.zig` `Command.meta`/`parseArgs` branch. Library export `oliver.meta` can be a thin helper `extractMeta(allocator, input, dialect, &json)`. Keep `src/frontmatter.zig` unchanged for generic parsing; `meta.zig` projects.
* Tests: `src/main.zig` unit tests for arg parsing + `tests/meta_test.zig` or fixture `tests/fixtures/meta-s1-*`.

### Harness probe expectations
```bash
$fake_bin meta --help | grep -q 'meta'
$fake_bin meta --from markdown --format json < probe.md | grep -q '"title": "Probe"'
# real probe on current pin must skip, not fail
```
* Our real probe in `rc-test.sh:678-691` must flip to `"Pass: real Oliver meta extraction probe"` after the bump. The hermetic `smoke-fixture-*` tests stay green regardless.

### Open question for #107
* Should `oliver meta` honor `frontmatter.Option` TOML (`+++`) or only YAML (`---`)? Issue says `--from <fmt>` but output contract lists YAML only. Harness’s `frontmatter-s1.md` uses `---`. Safer to implement YAML only for now and reject `+++` as “no frontmatter → empty strings”, with a `// TODO: TOML` note.

---

## 5. Issue #108 — `oliver wrap` (S2) — Detailed notes

### CLI shape (from contract + rc-test.sh probe)
```
oliver wrap --template <file> --meta-json <json> --assets-root <prefix> --body <file> > page.html
oliver wrap --help  # must exit 0, print "Usage: oliver wrap --template ..."
```
* All four flags required; `--template` is a filesystem path, `--meta-json` is a path to the S1 JSON, `--assets-root` is a literal prefix (e.g. `./assets/` or `../../assets/`), `--body` is a path to the body fragment (output of `oliver render`). Reads those files, writes stdout.
* No stdin use (unlike `oliver meta`/`render`). The adapter’s GAWK currently reads `body_file` and `template_file` via `getline`; Oliver will do `std.fs`.

### Dialect (exact, from contract + GAWK)
| Token | Source | Escaping |
|-------|--------|----------|
| `$title$` | `meta_json.title` | `html_escape` (`& < > " '` → `&amp; &lt; &gt; &quot; &#39;`) |
| `$description$` | `meta_json.description` | same |
| `$author$` | `meta_json.author` | same |
| `$date$` | `meta_json.date` | same |
| `$palette$` | `meta_json.palette` | same |
| `$assets_root$` | `--assets-root` flag | literal, never escaped |
| `$body$` | `--body` file | literal, never escaped (trusted HTML) |

* Unknown `$word$` passes verbatim.
* `$if(name)$ … $endif$` only for `title|description|author|date|palette` (not `assets_root`/`body`/`template`/`unknown`). One pass `title→description→author→date→palette`; **first** `$endif$` in the document closes the opener; no nesting; verbatim unknown; empty or `null` → block removed including interior newlines, else interior kept.
* Order: all `$if$` resolved first, then the 7 literal substitutions.

### Design choice
* Reuse `src/html.zig:writeEscaped` plus `'` for `html_escape`, not a second encoder. Ensure parity with GAWK’s `gsub(/&/, "\\&amp;", s)` chain (order `&` first to avoid double-escaping).
* Implement as `src/wrap.zig` with `pub fn wrap(allocator, template_path, meta_json_path, assets_root, body_path, writer) !void`. Keep I/O in `src/main.zig`.

### Tests
* Use `rc-test.sh:697-802` verbatim as the oracle: `custom-s2.html` with `$title$` + 3 `$if$` + `assets:$assets_root$` + `body:$body$` + `unknown:$unknown$`. Assert escaped title, gates kept, assets literal, body literal with `$body$`, unknown verbatim, empty-title removal (`TITLE:` absent).

---

## 6. Issue #109 — `oliver render` link rewriting (S3) — Detailed notes

### What changes
* `oliver render --from <fmt> [--to xhtml]` already exists (`src/main.zig:parseArgs` with `--to html|xhtml`). S3 adds a post-parse, pre-render AST walk that rewrites `href`/`src` leaves where the URL is an **internal** reference ending in `.md`/`.textile`/`.cook`.

### Rules (from contract + GAWK + harness)
* Internal `href="foo.md"` → `href="foo.html"` (same for `src`). Preserve fragment `#sec` and query `?v=1` + `#f` tail. So `foo.md?v=1#f2` → `foo.html?v=1#f2`.
* Strip `<>`/`%3C`/`&lt;`/`%3E`/`&gt;` wrapper before testing — the GAWK strips `^(\<|%3C|&lt;).*(>|%3E|&gt;)$`. At AST level the wrapper is already removed by `scanLink` (`"<url>"` → `url` without brackets), but keep a defensive strip for `raw_html` `<a href="...">` fallback if any.
* Skip external `://` (`^[a-zA-Z][a-zA-Z0-9+.-]*://`) and `mailto:`.
* Do **not** rewrite `https://example.com/docs.md` or `mailto:a@b` (harness asserts).
* Must be deterministic and respect `html.escape`/`percent_encode` already done in `writeEscapedHref`.

### Static vs. regex
* The fallback GAWK loops `while (match(line, /(href|src)=("|\x27)([^"\x27]+)("|\x27)/,a))` — which will mangle bytes that happen to look like `href=` inside code spans. AST-level avoids that entirely: walk the document tree (`document.Document.Iterator`) and rewrite node leaves:
  * `.link { href, title }` → rewrite `href`
  * `.image { src, alt, title }` → rewrite `src`
  * `.autolink { href, label }` → rewrite when `href` is `foo.md` text? (low priority — autolink content is already `mailto:`-free per contract)
  * `.html_block`/`.raw_html`: leave verbatim (fail-closed XSS risk if rewriting inside raw HTML). Only document-leaves are trusted.
* Helper `rewriteUrl(allocator, url) []const u8`:
  ```
  if startsWith "mailto:" or matches scheme:// → return url
  strip angle wrappers
  find “.md”/“.textile”/“.cook” before (?|#|$) → splice to “.html” + tail
  else return url
  ```
  Use owned copies in the arena (like `slugify` scratch) so the rewrite is arena-backed.

### Harness probes (rc-test.sh:804-850)
```
printf '[x](foo.md)\n'        | oliver render --from markdown | grep -q 'foo.html'  # internal
printf '[x](foo.textile)\n'   | oliver render --from markdown | grep -q 'foo.html'
printf '[x](foo.cook)\n'      | oliver render --from markdown | grep -q 'foo.html'
printf '[x](<foo.md#sec>)\n'  | oliver render --from markdown | grep -q 'foo.html#sec'
printf '[x](foo.md?v=1#f2)\n' | oliver render --from markdown | grep -q 'foo.html?v=1#f2'
printf '[x](https://example.com/foo.md)\n' | oliver render --from markdown | grep foo.html → must NOT match
```
Plus contract-corpus: `contract-inline.md` lines like `[Internal](my-first-page.md)` → `my-first-page.html`.

### Where to implement
* In `src/main.zig:renderWithDiag` after `try oliver.parse(...)` and before `try oliver.html.render(...)`. Check if `cfg` actually needs a pass — always run for `render`, since the cost is one traversal and no flag is needed (probe caches `OLIVER_REWRITES` = true to skip GAWK).

---

## 7. Issue #110 — `oliver plan` + `oliver manifest` (S4+S5) — Detailed notes

### `oliver plan` — 13-column batch TSV

**CLI (from `rc-render.sh:299-306`):**
```
oliver plan \
  --content-dir <dir> --output-dir <dir> --template-dir <dir> --meta-dir <dir> \
  --default-template <file> --oliver-bin <bin> --root-dir <dir> \
  --dry-run <bool> --verbose <bool> > batch.tsv
# Columns (TSV, tab-separated, no header):
# 1 src  2 dst  3 template  4 assets_root  5 soul  6 oliver_bin
# 7 root 8 content 9 output 10 template_dir 11 meta_dir 12 dry_run 13 verbose
```

**Semantics (from `rc-render.sh:211-358`):**

1. **Discovery:** `find "$CONTENT_DIR" -type f \( -name "*.md" -o -name "*.textile" -o -name "*.cook" \) -print0 | while read -d ''`. Use `std.fs.walk` + filter by extension exactly `.md`/`.textile`/`.cook`. No `*.MD` case sensitivity — keep lowercase only (contract says those three).
2. **`strip_source_ext`:** `foo.md`/`foo.textile`/`foo.cook` → `foo` (remove exactly one suffix, not greedy). Anything else (e.g. `foo.txt`) is impossible because discovery filtered it.
3. **`dst` derivation:** `rel = src relative to content_dir` → `base = strip_source_ext(basename(rel))` → `reldir = dirname(rel)` (`.` for root). If `reldir == "."` → `dst = output_dir/base.html` else `dst = output_dir/reldir/base.html`.
4. **Collision abort:** two distinct sources map to same `dst` (basename collision) → print error, exit 1. The harness’s `declare -A EXPECTED_OUTPUTS` / `OUTPUT_SOURCES` already does this. In Oliver, use `std.StringHashMap([]const u8)` from `dst` → `rel`.
5. **`ASSETS_ROOT` depth:** if `reldir == "."` → `./assets/` else `depth = count('/') in reldir` → `ASSETS_ROOT = rk_up_dirs(depth+1) + "assets/"` where `rk_up_dirs(n) = "../" * n`. Example: `content/docs/x/y/foo.md` (`reldir=docs/x/y`, depth=2) → `../../../assets/`. `src/meta.zig` already not involved; keep helper `upDirs(allocator, depth) []const u8`.
6. **`soul` derivation:** `soul = meta_dir / strip_source_ext(rel) + ".soul.md"` canonicalized; if file exists use its canonical path else `"NONE"` literal (the adapter tests `[[ "$soul_path" == "NONE" ]]`). Keep the `NONE` sentinel.
7. **Passthrough cols 3/6/7/8/9/10/11/12/13:** `template = template_dir/default_template`, `oliver_bin = --oliver-bin`, `root = --root-dir`, etc. These are opaque; the plan just threads them so the adapter can `read -r src dst template assets_root soul oliver_bin …`.

**Fallback:** probe `oliver plan --help` (must print usage). If probe fails, `rc-render.sh` falls back to the Bash loop. After the bump, plan always succeeds.

**Where:** `src/plan.zig` with `pub fn plan(allocator, args) !void` reading no stdin, writing TSV to stdout, exiting 1 on collision with a message to stderr. Tests mock `content_dir` with `std.testing.tmpDir`.

### `oliver manifest` — deduped manifest log

**CLI (from `rc-render.sh:142-152`):**
```
oliver manifest --manifest <file> --add <rel>   # dedup: grep -Fxq || echo >> file
oliver manifest --manifest <file> --verify      # (no-op today, but must exist)
oliver manifest --help                          # prints usage
```
* `--manifest` is required; `--add <rel>` appends `<rel>` (relative path `rel = "$MANIFEST_TSV" minus "$ROOT_DIR"/` or `output/probe.html`) only if not already present (line-exact `grep -Fxq`). Create `manifest` + parent dirs if missing (`touch`).
* `--verify` is a future hook; today it just exits 0 (the fake does `exit 0`).
* No `--format`, no JSON — plain text, one rel per line.

**Where:** `src/manifest.zig` with a 10-line writer plus `std.fs` existence check. Tests assert dedup and `--verify`.

---

## 8. Implementation checklist (what NOT to do)

* Do not change `src/frontmatter.zig`’s subset or `src/markdown.zig`’s block precedence — the 652/652 gate is green and the contract-corpus `contract-table.md` pins `|---` parsing.
* Do not move filesystem I/O into `src/oliver.zig`; keep `plan`/`manifest`/`wrap` in `src/main.zig` + companion CLI modules.
* Do not emit `null` in S1 JSON — always `""`.
* Do not HTML-escape `$body$` or `$assets_root$` in S2.
* Do not rewrite inside `.html_block` / `.raw_html` in S3 — only typed leaves.
* Do not add a `--verify` that fails on missing entries yet — the fake returns 0; match it.
* Do not bump `OLIVER_PIN` until all four slices are merged and `zig build test` + `bash rotkeeper.sh test --strict` pass.

---

## 9. Suggested commit stack (single PR)

```
feat(meta): oliver meta --from <fmt> --format json (S1) + render auto-strip
  - src/meta.zig (project frontmatter → 7-string JSON)
  - src/main.zig (Command.meta, parseArgs, dispatch)
  - tests/meta_test.zig (line-1, BOM, ... not honored, scalar-only, null→"", CRLF, empty block)
  docs/FRONTMATTER.md: add S1 CLI note

feat(wrap): oliver wrap dialect (S2)
  - src/wrap.zig (7 tokens, 5 html_escape, assets/body literal, $if$ one-pass)
  - src/main.zig (Command.wrap)
  - tests/wrap_test.zig (custom-s2 + empty-title + unknown-token)

feat(render): native link rewriting .md/.textile/.cook → .html (S3)
  - src/rewrite.zig (isExternal, stripAngle, spliceSuffix)
  - src/main.zig:renderWithDiag walk (link/image/src leaves)
  - tests/rewrite_test.zig (8 ugly-edge-case + contract-inline + textile/cook)

feat(plan+manifest): output planning + manifest (S4+S5)
  - src/plan.zig (find+strip+soul+assets_root+collision)
  - src/manifest.zig (--add dedup, --verify)
  - src/main.zig (Command.plan/manifest)
  tests/plan_test.zig, tests/manifest_test.zig

chore(pin): bump rotkeeper pin + re-run harness
  rotkeeper/scripts/setup.sh:76 OLIVER_PIN=<new HEAD>
  home/content/docs/oliver-contract.md: update “Pin moved” table
```

Each commit must keep `zig build test` green and the adapter’s hermetic harness green (the fake still passes; the real probe starts passing slice-by-slice).

---

## 10. Verification before marking issues ready

* `zig build test` — all suites including new `meta`/`wrap`/`rewrite`/`plan`/`manifest`.
* `zig build spec-conformance -- spec.txt` — 652/652 (S3 must not break link dest parsing).
* `zig build cooklang-conformance` — 60/60 (meta with `--from cooklang` must not break ` Recipe.metadata`).
* `./rotkeeper.sh test` in the rotkeeper checkout with the new binary on `PATH` (or `RK_OLIVER_BIN`) — crypt/busy/sterile green.
* `RK_STRICT=1 ./rotkeeper.sh test` — same, but real-OLIVER probes must show “Pass: real Oliver meta/wrap/plan/manifest probe” not “Skipping … lacks …”.
* `xmllint --noout bones/manifest.txt` is not needed, but `xmllint --noout` over the XHTML profile page must stay green.
* Manual spot checks:
  ```bash
  printf '---\ntitle: "A & <B>"\n---\n# hi\n' | ./zig-out/bin/oliver meta --from markdown --format json
  # → {"title":"A & <B>", ...}  (raw, not escaped yet)
  printf '[x](foo.md)\n' | ./zig-out/bin/oliver render --from markdown | grep foo.html
  printf '---\ntitle: x\n---\nBody' | ./zig-out/bin/oliver render --from markdown # body must not contain title line
  ```

---

## 11. Notes filed on issues (to be posted)

* #107 — Added analysis comment with scalar-only / line-1 / BOM / `...` notes and the JSON shape.
* #108 — Added note with 7-token table, escape split, `$if$` one-pass/first-`$endif$` rule, unknown verbatim.
* #109 — Added note with AST vs regex, skip `://`/`mailto:`, fragment/query preservation, bare angle strip.
* #110 — Added note with 13-col TSV, collision abort, `ASSETS_ROOT` `rk_up_dirs(depth+1)`, manifest dedup.

> This file is the planning gate. A human reviewer should ack it before any `src/` edit lands; the per-issue GitHub comments are the terse pointers (this doc is the durable artifact).

