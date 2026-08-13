# Markdown tabs and indented code

**Status: implemented contract for CommonMark 0.31.2 §2.2 and §4.4.**

This slice is derived from the official CommonMark 0.31.2 prose and examples
only. Tabs are not expanded in the source or in ordinary text. Where block
structure depends on indentation, a tab advances to the next four-column tab
stop; content that remains after structural indentation keeps the original
tab bytes. A partially consumed tab is represented by a small synthetic-space
prefix in the Markdown line view, so the source span remains byte-true while
the normalized code payload preserves the spec's visual remainder.

## Indented-code leaf

At the document root, or after all matching quote/list containers have been
consumed, a nonblank line with at least four virtual indentation columns opens
an indented `.code_block`. It cannot interrupt an open paragraph. The open
leaf owns subsequent lines with at least four virtual columns; a shorter
nonblank line closes the leaf and is reprocessed as a new block. Indented code
has no lazy container continuation.

Blank lines while the leaf is open are provisional. They are retained only if
another indented content line follows, and are then normalized to one `\n` per
physical line after removing up to four structural columns. Initial and final
blank runs are discarded. Trailing spaces and internal tabs on content lines
are literal. Every included content line contributes one normalized `\n`,
including an unterminated final source line.

The node span is the byte-true union of the marker-stripped source lines. The
payload is arena-owned because line endings, indentation, and partially
consumed tabs cannot be represented as one borrowed source slice. No info
string is attached to an indented code block.

## Containers and tab stops

Container matching runs before leaf recognition. A block quote consumes `>`
and one following space or tab at the current virtual column. List marker
indentation and the post-marker separator use the same tab stops; a first
block with more than four separator columns selects the list's indented-code
rule, consuming one separator column and leaving the remaining visual code
indentation on the line view. Nested indentation is relative to the current
container, not to the document root.

When a tab is only partly consumed, the line view records the unconsumed
visual suffix as synthetic spaces before the next source byte. Code payload
emission writes those spaces, then copies the remaining raw bytes. This is
why `>\t\tfoo` and `-\t\tfoo` both produce code content beginning with two
spaces, while tabs after the code indentation remain literal tabs.

## Verification

The unit wall pins virtual tab stops, internal-tab preservation, quote/list
composition, provisional blank chunks, paragraph non-interruption, exact
container spans, list looseness after a code leaf, mixed line endings, and
deterministic rendering. The fixture wall includes direct tab/quote/list and
indented-code cases. The canonical CommonMark 0.31.2 gate now reports:

- Tabs: **11/11**
- Indented code: **12/12**
- Overall: **592/652**

The remaining failures are the explicitly deferred entity and HTML-block
families, plus their dependent examples; the classified gate records these
as not-yet rather than hiding them.
