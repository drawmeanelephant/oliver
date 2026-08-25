---
published_at: 2026-08-16T00:00:00Z
summary: "The stable C ABI for embedding Oliver from C, Rust, Python, Node, and other FFI consumers: the oliver_render / oliver_free surface, the memory-ownership contract, the error codes, and the CI-compiled example."
---

# C ABI

**Status:** implemented (issue #96, milestone v1.1; ledger card S2).  \
**Module:** `src/c_abi.zig` (exports), `include/oliver.h` (C
declaration), `examples/c_example.c` (CI-compiled consumer)  \
**Entry points:** `oliver_render(alloc, free, ctx, bytes, len, dialect,
frontmatter, markdown_flags, profile, raw_html, heading_ids,
footnotes) -> oliver_buffer`, `oliver_free(free, ctx, buffer)`

Oliver markets itself as markup infrastructure for consumers to build
around, but until v1.1 the only consumer surface was the Zig API. The
C ABI is the stable embedding seam: a minimal parse + render surface
declared in a plain C header, so C, Rust, Python, Node, and other FFI
consumers can embed Oliver without adopting Zig. The session record's
architectural concern (docs/SESSION-1-REPORT.md, concern 1) — that any
C-ABI surface must target the Zig 0.16 `std.Io` shapes and use
`std.Io.Writer.Allocating` for the render-to-buffer path — is what this
module implements.

## 1. Surface

```c
typedef void *(*oliver_alloc_fn)(void *ctx, size_t size);
typedef void (*oliver_free_fn)(void *ctx, void *ptr, size_t size);

typedef struct oliver_buffer {
    uint8_t *data;   /* owned on success; NULL on error */
    size_t len;      /* byte length of `data` on success; 0 on error */
    int error_code;  /* OLIVER_OK on success, else an OLIVER_ERR_* code */
} oliver_buffer;

oliver_buffer oliver_render(
    oliver_alloc_fn alloc, oliver_free_fn free, void *ctx,
    const uint8_t *bytes, size_t len,
    int dialect, int frontmatter, uint32_t markdown_flags,
    int profile, int raw_html, int heading_ids, int footnotes);

void oliver_free(oliver_free_fn free, void *ctx, oliver_buffer buf);
```

One call parses and renders: `oliver_render` runs the same pipeline as
the Zig API — `oliver.parse` (dialect dispatch, front matter pre-pass,
diagnostics) followed by `oliver.html.render` — into an owned buffer.
The Cooklang entry points (parse/scale/serialize) are a follow-up slice
of the ABI, per issue #96.

## 2. Memory-ownership contract

- The caller supplies the allocator: a malloc-style `alloc`/`free` pair
  plus an opaque context. `alloc` must provide at least `max_align_t`
  alignment (the malloc contract); Oliver's internal allocations never
  request more.
- On success, `buffer.data` points to `len` bytes **owned by the
  caller**, allocated through the supplied pair. Release them with
  `oliver_free`, passing the **same** `free` and `ctx` used at render
  time (the buffer's size is passed back to `free`, matching the
  allocation).
- On any error, `error_code` is non-zero, `data` is NULL, `len` is 0,
  and there is nothing to free.
- The input bytes are borrowed for the duration of the call only.
- Documented failures return error codes; **internal bugs abort** the
  process (they never return garbage). The module maps every documented
  Zig error onto a code; anything else is a bug and panics rather than
  crossing the boundary with a wrong result.

## 3. Parameters

`dialect`, `frontmatter`, `profile`, and `raw_html` are small integer
enums declared in the header (`OLIVER_MARKDOWN`/`OLIVER_TEXTILE`,
`OLIVER_FRONTMATTER_NONE`/`YAML`/`TOML`, `OLIVER_PROFILE_HTML`/`XHTML`,
`OLIVER_RAW_HTML_ALLOWED`/`ESCAPED`/`REJECTED`). Any out-of-range value
is `OLIVER_ERR_INVALID_ARGUMENT`, as is a null allocator pair or null
`bytes` with a non-zero `len`.

`markdown_flags` is the parse-extension bitmask (`OLIVER_MD_FOOTNOTES`
… `OLIVER_MD_TASK_LISTS`, bit 0 = footnotes); all extensions are off by
default, matching `markdown.Options`. `profile`, `raw_html`,
`heading_ids`, and `footnotes` are the render options
(`html.RenderOptions`). Note `footnotes` appears on **both** sides: the
`OLIVER_MD_FOOTNOTES` bit turns the parse extension on, the `footnotes`
argument turns the rendered section on — both are needed for footnote
output.

## 4. Error codes

| code | meaning |
| --- | --- |
| `OLIVER_OK` | success; `data`/`len` valid |
| `OLIVER_ERR_INPUT_TOO_LARGE` | input exceeds `source.max_input_len` (u32 spans) |
| `OLIVER_ERR_OUT_OF_MEMORY` | the caller's allocator returned NULL |
| `OLIVER_ERR_RAW_HTML_REJECTED` | `raw_html = REJECTED` and raw content was found (docs/RAW-HTML.md §3) |
| `OLIVER_ERR_RAW_HTML_NOT_XML_WELL_FORMED` | XHTML profile, raw content present — the fail-closed error (docs/XHTML.md) |
| `OLIVER_ERR_INVALID_ARGUMENT` | null allocator, null bytes with `len > 0`, out-of-range enum |

## 5. Implementation notes

- **Allocator bridge.** The caller's pair is wrapped in a Zig
  `std.mem.Allocator` for the duration of the call (a stack-local state
  struct holds the two function pointers plus the user context). The
  pair has no realloc, so `resize` returns false and `remap` returns
  null; the Allocator wrapper handles growth by allocating, copying, and
  freeing.
- **Render-to-buffer path.** `std.Io.Writer.Allocating` accumulates the
  output; the result is then copied into a fresh, exactly-sized
  allocation so the caller's `free` (which receives the returned `len`)
  matches the allocation size exactly.
- **No panics across the boundary for documented failures.** Argument
  validation and every mapped error return codes. The one remaining
  `@panic` is the `else` arm of the error map — unreachable for
  documented errors, and the documented contract for internal bugs.
- **Thread-safety.** A call is pure: no global state, no hidden caches.
  Distinct calls may run on distinct threads; sharing one allocator pair
  across threads is the caller's concern (as with malloc).

## 6. Example and CI

`examples/c_example.c` is a self-checking C consumer: a plain
`malloc`/`free` pair, then byte-assertions over Markdown, Textile,
front matter, the extension surface under the XHTML profile with escaped
raw HTML, the two raw-content error codes, and the invalid-argument
paths. It exits non-zero on any failed assertion, so the build step is
also the gate:

```text
zig build c-example-run     # compiles examples/c_example.c against
                            # include/oliver.h and the static library,
                            # then runs it
```

CI runs it as its own leg after the conformance gates (`.github/
workflows/ci.yml`, "C ABI example (compile + run)"), proving the header
compiles from C and the ABI round-trips end to end on every change. The
exports are forced into the static archive by the `comptime { _ = c_abi; }`
block in `src/oliver.zig`.
