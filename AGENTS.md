# Oliver — Agent Operating Manual

Read this first. Then `docs/CAPABILITIES.md` (what it does),
`docs/TESTS.md` (how it's proven), and `docs/CLEANROOM.md` (the
provenance rules). `docs/ARCHITECTURE.md` is the map; the rest of
`docs/` is per-feature spec record.

## What this is

A freestanding markup parsing/rendering library in Zig. Markdown (full
CommonMark 0.31.2 — 652/652 corpus byte-exact, opt-in extensions beyond),
Textile, and Cooklang each parse into a normalized typed document (a typed
Recipe for Cooklang) and render deterministic HTML/XHTML. Library-first —
no filesystem, templates, or site logic — plus a small CLI and a stable C
ABI (`include/oliver.h`).

## Hard boundaries

1. **Clean-room.** Implement from published specs (CommonMark spec,
   Textile docs, Cooklang spec + canonical corpus) — never from a
   reference implementation's source. `docs/CLEANROOM.md` is the record.
2. **Deterministic.** Same input bytes → same output bytes, always. No
   global state, no ambient authority; the caller supplies the allocator,
   documents own an arena and borrow the input, rendering streams to a
   writer.
3. **CommonMark bytes are pinned.** A change that shifts emitted bytes
   is a conformance change — run the scorecard and update the manifest
   deliberately; don't let it drift silently.
4. **Opt-in stays opt-in.** Footnotes, task lists, wikilinks, callouts,
   smart typography, front matter must not alter default CommonMark
   behavior.
5. **Library boundaries.** No filesystem, no template language, no site
   graph inside the library — consumers build those around it (k4o,
   dogbed, Solipsist). Knap is not a frontend.
6. **Generated tables come from generators.** Entity/unicode tables in
   `tools/gen-*.py` outputs — never hand-edit.
7. **The C ABI is a contract.** `include/oliver.h` + `src/c_abi.zig`:
   explicit error codes, caller frees via `oliver_free`. Breaking it
   breaks FFI consumers.
8. **`docs/` is the spec record.** Behavior changes update the matching
   doc in the same change; the docs-gate workflow checks sync.

## Build / test / gates

Requires Zig 0.16.0 (CI pins it).

```sh
zig build                                    # library + CLI -> zig-out/
zig build test                               # all suites — the gate
zig build spec-conformance -- spec.txt       # CommonMark scorecard
zig build cooklang-conformance -- canonical.yaml   # Cooklang corpus
zig build spec-conformance-test              # the harness's own tests
zig build c-example-run                      # C ABI consumer smoke test
```

The spec harness verifies the official corpus by SHA-256 and classifies
every example in a reviewed manifest; `--gate` makes the corpus a
regression wall. Fuzz coverage lives in `tests/fuzz.zig`.

## Layout

- `src/markdown.zig`, `src/textile.zig` — the two markup parsers.
- `src/cooklang*.zig` — the Recipe model, renderer, serializer, scaling,
  menu views (own entry points: `oliver.cooklang.parse`, `cooklang_html`,
  `cooklang_serialize`, `cooklang_scale`, `cooklang_menu`).
- `src/document.zig`, `src/html.zig` — normalized document + renderers.
- `include/oliver.h`, `src/c_abi.zig` — the stable C ABI.
- `tests/` — unit, fixture, XHTML/HTML4-strict, fuzz.
- `tools/` — conformance harnesses + table generators.
- `docs/` — the spec record (see the index in `docs/index.md` /
  `nav.json`).

## Conventions

- `zig build test` before declaring done; report the exact commands and
  results. For parse changes, also run the relevant scorecard and quote
  its summary — corpus counts are the evidence.
- `main` is the clean merge target; feature work is a branch + PR.
- The `builds` release republishes from every push to main, gated on a
  real smoke test of the shipped artifact — don't bypass.

## Downstream consumers

[k4o](https://github.com/drawmeanelephant/k4o) emits Textile/Markdown for
Oliver to parse; [dogbed](https://github.com/drawmeanelephant/dogbed)
embeds Oliver as a commit-pinned zig package; Solipsist bundles the CLI.
Breaking the parse or render surface breaks all three.
