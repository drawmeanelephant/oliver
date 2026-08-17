/*
 * c_example.c — a self-checking C consumer of the Oliver C ABI.
 *
 * Built and run by `zig build c-example-run` (and the CI gate) to prove
 * the ABI compiles from C and round-trips: render Markdown, Textile, and
 * an extension combination; assert the exact bytes; exercise the explicit
 * error-code paths and the ownership contract. Exits 0 only if every
 * check passes.
 *
 * The allocator pair is plain malloc/free — the minimal compliant
 * implementation (max_align_t alignment, context unused).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oliver.h"

static void *my_alloc(void *ctx, size_t size) {
    (void)ctx;
    return malloc(size);
}

static void my_free(void *ctx, void *ptr, size_t size) {
    (void)ctx;
    (void)size;
    free(ptr);
}

static int checks = 0;

static void check_bytes(const char *what, oliver_buffer buf, const char *expected) {
    checks++;
    size_t want = strlen(expected);
    if (buf.error_code != OLIVER_OK) {
        fprintf(stderr, "FAIL %s: error %d\n", what, buf.error_code);
        exit(1);
    }
    if (buf.len != want || memcmp(buf.data, expected, want) != 0) {
        fprintf(stderr, "FAIL %s: got %zu bytes, expected %zu\n", what, buf.len, want);
        fprintf(stderr, "  got:      %.*s\n", (int)buf.len, (const char *)buf.data);
        fprintf(stderr, "  expected: %s\n", expected);
        exit(1);
    }
    oliver_free(my_free, NULL, buf);
}

static void check_error(const char *what, oliver_buffer buf, int want_error) {
    checks++;
    if (buf.error_code != want_error) {
        fprintf(stderr, "FAIL %s: got error %d, expected %d\n", what, buf.error_code, want_error);
        exit(1);
    }
    if (buf.data != NULL || buf.len != 0) {
        fprintf(stderr, "FAIL %s: error buffer must be empty\n", what);
        exit(1);
    }
    /* Nothing to free on an error buffer. */
}

int main(void) {
    const char *md = "# Hello *world*\n";
    oliver_buffer buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)md, strlen(md),
        OLIVER_MARKDOWN, OLIVER_FRONTMATTER_NONE, 0,
        OLIVER_PROFILE_HTML, OLIVER_RAW_HTML_ALLOWED, 0, 0);
    check_bytes("markdown basic", buf, "<h1>Hello <em>world</em></h1>\n");

    const char *textile = "h1. Hello *world*\n";
    buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)textile, strlen(textile),
        OLIVER_TEXTILE, OLIVER_FRONTMATTER_NONE, 0,
        OLIVER_PROFILE_HTML, OLIVER_RAW_HTML_ALLOWED, 0, 0);
    check_bytes("textile basic", buf, "<h1>Hello <strong>world</strong></h1>\n");

    /* Extensions: wikilinks + smartypants + task lists (parse bits), with
     * the XHTML profile (the XML-form void element) and escaped raw HTML. */
    const char *ext = "- [x] done [[Page|label]] \"hi\" <br/>\n";
    buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)ext, strlen(ext),
        OLIVER_MARKDOWN, OLIVER_FRONTMATTER_NONE,
        OLIVER_MD_WIKILINKS | OLIVER_MD_SMARTYPANTS | OLIVER_MD_TASK_LISTS,
        OLIVER_PROFILE_XHTML, OLIVER_RAW_HTML_ESCAPED, 0, 0);
    check_bytes("extensions + xhtml + escaped raw html", buf,
                "<ul>\n<li><input type=\"checkbox\" disabled=\"\" checked=\"\" />done <a href=\"Page\">label</a> \xe2\x80\x9chi\xe2\x80\x9d &lt;br/&gt;</li>\n</ul>\n");

    /* Front matter: yaml fence stripped, body rendered. */
    const char *fm = "---\ntitle: Doc\n---\n\n# Body\n";
    buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)fm, strlen(fm),
        OLIVER_MARKDOWN, OLIVER_FRONTMATTER_YAML, 0,
        OLIVER_PROFILE_HTML, OLIVER_RAW_HTML_ALLOWED, 0, 0);
    check_bytes("yaml front matter", buf, "<h1>Body</h1>\n");

    /* Explicit error codes: rejected raw HTML and XHTML fail-closed. */
    const char *raw = "before <script>bad()</script> after\n";
    buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)raw, strlen(raw),
        OLIVER_MARKDOWN, OLIVER_FRONTMATTER_NONE, 0,
        OLIVER_PROFILE_HTML, OLIVER_RAW_HTML_REJECTED, 0, 0);
    check_error("raw html rejected", buf, OLIVER_ERR_RAW_HTML_REJECTED);

    buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)raw, strlen(raw),
        OLIVER_MARKDOWN, OLIVER_FRONTMATTER_NONE, 0,
        OLIVER_PROFILE_XHTML, OLIVER_RAW_HTML_ALLOWED, 0, 0);
    check_error("xhtml raw html fail-closed", buf, OLIVER_ERR_RAW_HTML_NOT_XML_WELL_FORMED);

    /* Invalid arguments return OLIVER_ERR_INVALID_ARGUMENT, not a crash. */
    buf = oliver_render(
        NULL, my_free, NULL,
        (const uint8_t *)md, strlen(md),
        OLIVER_MARKDOWN, OLIVER_FRONTMATTER_NONE, 0,
        OLIVER_PROFILE_HTML, OLIVER_RAW_HTML_ALLOWED, 0, 0);
    check_error("null allocator", buf, OLIVER_ERR_INVALID_ARGUMENT);

    buf = oliver_render(
        my_alloc, my_free, NULL,
        (const uint8_t *)md, strlen(md),
        99, OLIVER_FRONTMATTER_NONE, 0,
        OLIVER_PROFILE_HTML, OLIVER_RAW_HTML_ALLOWED, 0, 0);
    check_error("bad dialect", buf, OLIVER_ERR_INVALID_ARGUMENT);

    printf("c-example: %d checks passed\n", checks);
    return 0;
}
