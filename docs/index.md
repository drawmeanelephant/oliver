# Oliver documentation

Oliver is a small, freestanding markup parsing and rendering library in
Zig: bytes in, a typed document (or Recipe) out, deterministic HTML on
request. This is the documentation home.

The documentation is written for two audiences:

- **Consumers** — applications (like Boris) that embed Oliver. Start
  with [Capabilities](CAPABILITIES.md) and the README's library-use and
  CLI sections, then the frontend pages that matter to you.
- **Contributors** — anyone changing Oliver. Start with
  [Architecture](ARCHITECTURE.md) and [Clean-room rules](CLEANROOM.md),
  then the per-feature parsing documents and the
  [work ledger](WORK-LEDGER.md).

## Conformance status

| wall | status |
| --- | --- |
| CommonMark 0.31.2 corpus | **652/652**, 0 mismatches |
| Cooklang canonical corpus | **60/60** |
| Textile fixture wall | fully green |
| Test suite | **251/251** |

Both conformance gates run in CI on every push/PR
(`zig build spec-conformance -- spec.txt --gate` and
`zig build cooklang-conformance`).

## Site map

[nav.json](nav.json) is the machine-readable manifest — sections,
pages, titles, audiences, and summaries — that any docs renderer can
consume directly. The map below mirrors it.

### Overview

- [Capabilities](CAPABILITIES.md) — what each frontend parses and
  renders today, with conformance status (start here as a user)
- [Architecture](ARCHITECTURE.md) — pipeline, the two document
  families, module map, the boundaries that matter
- [Document model](DOCUMENT-MODEL.md) — the shared normalized model and
  its invariants
- [Feature matrix](FEATURE-MATRIX.md) — every implemented feature
  across the dialects, with provenance
- [Tests and fixtures](TESTS.md) — the suites, the conformance walls,
  and the fixture convention
- [CommonMark expectations](COMMONMARK-EXPECTATIONS.md) — the
  classified conformance expectation set behind the 652/652 gate

### Markdown frontend

- [Block parsing](BLOCKS-PARSING.md) · [Leaf blocks](LEAF-BLOCKS.md) ·
  [Fenced code](FENCED-CODE.md) · [HTML blocks](HTML-BLOCKS.md) ·
  [Entities](ENTITIES.md)
- [Emphasis and strong](INLINE-PARSING.md) · [Autolinks](AUTOLINKS.md) ·
  [Raw HTML](RAW-HTML.md) · [Images](IMAGES-PARSING.md) ·
  [Reference images](REFERENCE-IMAGES.md) · [Tables (GFM)](TABLES.md)

### Textile frontend

- [Textile parity audit](TEXTILE-PARITY.md) · [Inline code
  contract](TEXTILE-INLINE-CODE.md)

### Cooklang frontend

- [Cooklang design contract](COOKLANG.md) — the typed Recipe model,
  the boundaries, and the serialize / scale / HTML / menu policies

### Process

- [Clean-room rules](CLEANROOM.md) · [Work ledger](WORK-LEDGER.md)

## Rendering as pages

`docs/nav.json` is the single source of navigation truth and is kept
renderer-agnostic: a later docs site (mdBook, mkdocs, Docusaurus, or a
hand-rolled generator) can consume it directly or transpile it to its
own sidebar format. The markdown files are self-contained and
cross-linked, so any static renderer with a markdown engine can serve
them as-is — no repository restructuring is needed to ship pages.
