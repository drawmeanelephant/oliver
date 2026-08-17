/*
 * oliver.h — the stable C ABI for embedding Oliver.
 *
 * A minimal parse + render surface over the public Zig API
 * (docs/C-ABI.md). Consumers in C, Rust, Python, Node, and other FFI
 * languages can embed Oliver without adopting Zig.
 *
 * Memory-ownership contract:
 *   - The caller supplies the allocator: a malloc-style `alloc`/`free`
 *     pair plus an opaque context. `alloc` must provide at least
 *     `max_align_t` alignment (the malloc contract); Oliver's internal
 *     allocations never request more.
 *   - `oliver_render` returns a buffer. On success (`error_code ==
 *     OLIVER_OK`) the buffer's `data` points to `len` bytes that are
 *     owned by the caller. Release them with `oliver_free`, passing the
 *     SAME `free` function and `ctx` used at render time.
 *   - On any error, `error_code` is non-zero and `data` is NULL with
 *     `len == 0`; there is nothing to free.
 *   - The input bytes are borrowed for the duration of the call only.
 *   - Documented failures return error codes; internal bugs abort the
 *     process (they never return garbage).
 *
 * Thread-safety: a call is pure — no global state, no hidden caches.
 * Distinct calls may run on distinct threads; sharing one allocator pair
 * across threads is the caller's concern (as with malloc).
 */

#ifndef OLIVER_H
#define OLIVER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The caller-supplied allocator pair. `ctx` is passed through unchanged. */
typedef void *(*oliver_alloc_fn)(void *ctx, size_t size);
typedef void (*oliver_free_fn)(void *ctx, void *ptr, size_t size);

/* Error codes (the Zig side mirrors them; values are part of the ABI). */
enum {
    OLIVER_OK = 0,
    OLIVER_ERR_INPUT_TOO_LARGE = 1,          /* input exceeds 4 GiB (u32 spans) */
    OLIVER_ERR_OUT_OF_MEMORY = 2,            /* the caller's allocator returned NULL */
    OLIVER_ERR_RAW_HTML_REJECTED = 3,        /* raw_html = OLIVER_RAW_HTML_REJECTED and raw content was found */
    OLIVER_ERR_RAW_HTML_NOT_XML_WELL_FORMED = 4, /* XHTML profile, raw content present (fail closed) */
    OLIVER_ERR_INVALID_ARGUMENT = 5,         /* null allocator, null bytes with len > 0, out-of-range enum */
};

/* Input dialect. */
enum {
    OLIVER_MARKDOWN = 0,
    OLIVER_TEXTILE = 1,
};

/* Front matter handling (shared by all frontends, off by default). */
enum {
    OLIVER_FRONTMATTER_NONE = 0,
    OLIVER_FRONTMATTER_YAML = 1,
    OLIVER_FRONTMATTER_TOML = 2,
};

/* Renderer output profile. */
enum {
    OLIVER_PROFILE_HTML = 0,
    OLIVER_PROFILE_XHTML = 1,
};

/* Raw-content policy (Markdown raw HTML inline tags and HTML blocks,
 * Textile ==/notextile. escapes and pre. verbatim blocks). */
enum {
    OLIVER_RAW_HTML_ALLOWED = 0,  /* verbatim (default; XHTML still fails closed) */
    OLIVER_RAW_HTML_ESCAPED = 1,  /* HTML-escaped; well-formed under both profiles */
    OLIVER_RAW_HTML_REJECTED = 2, /* fail with OLIVER_ERR_RAW_HTML_REJECTED */
};

/* Markdown parse-extension bitmask (all off by default). */
enum {
    OLIVER_MD_FOOTNOTES = 1 << 0,
    OLIVER_MD_DEFINITION_LISTS = 1 << 1,
    OLIVER_MD_HEADING_ATTRIBUTES = 1 << 2,
    OLIVER_MD_STRIKETHROUGH = 1 << 3,
    OLIVER_MD_WIKILINKS = 1 << 4,
    OLIVER_MD_CALLOUTS = 1 << 5,
    OLIVER_MD_SMARTYPANTS = 1 << 6,
    OLIVER_MD_TASK_LISTS = 1 << 7,
};

/* An owned render result. */
typedef struct oliver_buffer {
    uint8_t *data;      /* owned on success; NULL on error */
    size_t len;         /* byte length of `data` on success; 0 on error */
    int error_code;     /* OLIVER_OK on success, else an OLIVER_ERR_* code */
} oliver_buffer;

/* Renders `bytes[0..len]` in the given dialect to an owned buffer.
 *
 * `alloc`/`free`/`ctx` are the caller's allocator pair (see the contract
 * above). `markdown_flags` is the OLIVER_MD_* bitmask. `profile`,
 * `raw_html`, `heading_ids`, and `footnotes` are the render options;
 * note `footnotes` appears on both sides — OLIVER_MD_FOOTNOTES turns the
 * parse extension on, the `footnotes` argument turns the rendered
 * section on, and both are needed for footnote output.
 */
oliver_buffer oliver_render(
    oliver_alloc_fn alloc,
    oliver_free_fn free,
    void *ctx,
    const uint8_t *bytes,
    size_t len,
    int dialect,
    int frontmatter,
    uint32_t markdown_flags,
    int profile,
    int raw_html,
    int heading_ids,
    int footnotes);

/* Releases a buffer returned by `oliver_render`. `free` and `ctx` must be
 * the same pair passed at render time. */
void oliver_free(oliver_free_fn free, void *ctx, oliver_buffer buf);

#ifdef __cplusplus
}
#endif

#endif /* OLIVER_H */
