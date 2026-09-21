---
published_at: 2026-09-18T00:00:00Z
summary: "Knap is not an Oliver frontend: it is a template language that emits Markdown, which Oliver already parses."
---

# Knap boundary

**Status:** out of scope — recorded, not scheduled, not a frontend.  \
**Fixture:** `knap-literal` (default Markdown: `{{ }}` / `{% %}` / `{# #}` stay text)

Oliver does not support Knap.

Knap is a template language that turns data into Markdown
(<https://knap.md>, MIT, currently 0.6.x). It powers templating in
Obsidian Web Clipper and Obsidian Importer. Variables (`{{ title }}`),
filters (`{{ plot | blockquote }}`), and logic (`{% if %}` / `{% for %}`)
run against host-supplied data and emit Markdown bytes. That is a
different job from Oliver's: Oliver parses those bytes.

```text
data + knap template
        │
        v
   knap engine                 (not Oliver)
        │
        v
   markdown bytes
        │
        v
   oliver.parse (.markdown)    (wikilinks, callouts, tables, footnotes, …)
        │
        v
   Document ──> HTML / XHTML
        │
        v
   oliver wrap                 (HTML chrome; $title$ dialect, not knap)
```

## 1. Why it is not a frontend

Oliver admits a language when it is markup (or a markup-adjacent typed
document) with a published specification and a conformance wall:
CommonMark 0.31.2, documented Textile syntax, Cooklang's spec plus
canonical corpus. The parser takes a byte slice and returns a typed
document or Recipe. It has no data environment, no filter registry, no
host resolvers, and no plugin surface
([Architecture](ARCHITECTURE.html) non-goals).

Knap fails that test on every axis:

- **Wrong layer.** Knap *produces* Markdown. Oliver *consumes* Markdown.
  The composition is `knap render` then `oliver.parse`. Putting the
  engine inside Oliver would invert the pipeline.
- **Wrong inputs.** A Knap render needs variables (JSON/CSV), optional
  asynchronous resolvers, a filter registry, and execution limits. Some
  filters (`html_to_json`, `remove_html`) need DOM globals. Oliver's
  public parse is `bytes + dialect + options` and is filesystem-,
  network-, and host-free so it can embed and fuzz.
- **No frozen language spec.** Behavior lives in the Knap documentation
  and a TypeScript implementation that is still breaking (0.6.0 changed
  how filters preserve types). Cooklang was admitted because
  cooklang.org published a spec, EBNF, and an MIT canonical corpus.
  Reimplementing Knap clean-room from prose, against a moving engine,
  is not the same kind of work.
- **Oliver already parses the output.** Knap's Markdown filters emit
  headings, lists, tables, footnotes, YAML front matter, wikilinks,
  callouts, and strikethrough — syntax Oliver already implements
  (several as opt-in, Obsidian-adjacent extensions). Supporting Knap
  inside Oliver would be reimplementing the generator of documents
  Oliver already reads.

Cooklang is the contrast that matters. Cooklang is a source language
whose typed Recipe cannot be deformed through the Document IR.
Knap's output *is* the Document IR's usual input.

## 2. `oliver wrap` is not a precedent

`oliver wrap` interpolates HTML page chrome *after* render: `$title$`,
`$body$`, `$if(name)$…$endif$`, plus any `--meta-json` key. It is a
small, filesystem-free token dialect for publication shells
(`src/wrap.zig`). It does not interpret Markdown, does not have
filters or loops over arrays, and does not accept `{{ }}` / `{% %}`.

Wrap and Knap sit at opposite ends of the pipeline and speak different
token languages. Wrap will not grow Knap syntax.

## 3. What Oliver does with Knap-looking source

An unrendered `.knap.md` file is Markdown. CommonMark has no template
constructs, so `{{ title }}`, `{% if cast %}`, and `{# comment #}` are
plain text. That is the correct behavior for displaying a template as a
document, and the `knap-literal` fixture pins it.

A leading `---` fence in a Knap template is a CommonMark thematic break
unless `ParseOptions.frontmatter` is on. Even then Oliver strips the
fence and does not evaluate interpolations inside the payload.

A fenced block with info string `knap` is an ordinary code block.

None of these grow a Knap node type, a template AST, or a "knap"
dialect.

## 4. Where Knap belongs

Consumers (Boris, rotkeeper, an importer, a clipper) own data, templates,
and publication. If a consumer wants Knap, it runs the official engine
and hands Oliver the Markdown. That keeps one implementation of Knap
(the one that ships the language) and one implementation of Markdown
(Oliver).

A Zig Knap engine, if anyone ever needs one, is a separate library. It
would still emit Markdown for Oliver to parse. Popularity, Obsidian
adjacency, or "it is a language" are not reasons to reopen this.

## 5. Explicitly not built

- `--from knap` / a Knap dialect
- opt-in recognition of `{{ }}`, `{% %}`, or `{# #}`
- evaluating filters, logic, or host variables
- wrapping the official `knap` npm package
- growing `oliver wrap` into Knap

## Sources consulted

User-facing documentation only (clean-room:
[CLEANROOM](CLEANROOM.html) session 36). No Knap parser source.

- <https://knap.md> — variables, filters, logic, API
- <https://github.com/obsidianmd/knap> README, CHANGELOG, package.json
  (version 0.6.0, MIT)
- <https://md-handbook.com/blog/obsidian-ceo-creates-language-turns-data-into-markdown/>
