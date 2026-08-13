# Textile emphasis and strong: clean-room design contract

This document fixes Oliver's Textile `_..._` and `*...*` behavior before the
implementation milestone. It is derived only from published, user-facing
Textile documentation. No Textile parser implementation was consulted.

## 1. Authoritative syntax

The Hobix **Textile Reference** describes `_believe_` as emphasis (`<em>`),
`*fell*` as strong (`<strong>`), and says that doubling the operators forces
the same two families (`__know__` and `**really**`) into italic and bold
output. The Movable Type **Textile 2 Syntax** page lists the same operators,
states that inline operators must be placed up against their text or
punctuation, and gives `Textile is way c*oo*l.` as a non-example because its
operators occur in the middle of a word. Its forcing examples (`[*oo*]`) are
part of a later bracket/brace milestone.

Sources:

- Dean Allen, [Hobix Textile Reference](https://hobix.com/textile),
  "Quick Phrase Modifiers / Structural Emphasis".
- Brad Choate, [Movable Type Textile 2 Syntax](https://movabletype.org/documentation/author/textile-2-syntax.html),
  "Inline Formatting" and its boundary examples.

The references do not define a formal delimiter stack, mixed marker crossing,
three-or-more marker runs, escaped emphasis markers, or cross-line phrases.
Oliver pins those edges below rather than inheriting behavior from an
implementation.

## 2. Oliver's pinned grammar

Each paragraph, heading, and single-period block quote line is scanned
independently. A phrase delimiter is a run of exactly one or two identical
`_` or `*` bytes. Runs of three or more remain literal until a later milestone
chooses a combined-emphasis grammar.

An opening run qualifies when the next Unicode code point exists and is not
whitespace, and the code point before the run is absent or is Unicode
whitespace/punctuation/symbol. A closing run qualifies when the preceding
code point exists and is not whitespace, and the following code point is
absent or is Unicode whitespace/punctuation/symbol. This allows punctuation
around a phrase while rejecting intraword forms such as `c*oo*l` and
`foo_bar_baz`. Invalid UTF-8 is ordinary text.

The scanner keeps an explicit last-in-first-out delimiter stack. A closing
run pairs only with the top opener when its marker byte and run length match;
otherwise it stays literal (and may open a fresh phrase only when its own
boundary rules allow). This produces deterministic, properly nested output in
the documented cases and rejects unspecified crossing/mixed-length shapes.
Empty pairs are not formed: the opener and closer must cover at least one
source byte.

The shared semantic IR has only `.emphasis` and `.strong`. Therefore `_` and
`__` both become `.emphasis`/`<em>`, while `*` and `**` both become
`.strong`/`<strong>`. This is an explicit Oliver convergence choice: the
historical Hobix examples show `<i>`/`<b>` for doubled spellings, but adding
renderer-only tags would violate the shared model. A future renderer profile
can add those presentational aliases without changing this parser contract.

## 3. Precedence, opacity, and spans

The existing same-line `@...@` scanner runs before phrase tokenization. A
recognized code span is an opaque `.code_span` leaf: `_` and `*` bytes inside
its payload never become phrase delimiters, but an outer emphasis pair may
contain the code leaf. Code payload bytes remain verbatim and arena-owned per
`docs/TEXTILE-INLINE-CODE.md`.

No backslash escape is introduced here; the cited references reserve escaping
for the later `==...==` mechanism. Bracket/brace forcing is likewise deferred.
Line endings terminate the inline scope, so `_open` and `close_` on adjacent
Textile lines remain literal with the existing hard-break node between them.

An emphasis/strong node span covers both delimiter runs and all source bytes
between them. Its children cover only emitted content; consumed delimiter
bytes belong to no child. Literal near-miss delimiters keep source spans as
ordinary `.text` nodes.

## 4. Complexity and acceptance wall

The implementation has three forward-only phases per line: discover opaque
code spans, tokenize non-code text and phrase runs, then pair a delimiter
stack and emit through an explicit frame stack. No substring is rescanned, so
time is `O(n)` and parser call-stack depth is independent of nesting depth.

Fixtures and unit tests pin:

- Hobix's basic `_emphasis_` and `*strong*` shapes;
- nested mixed markers (`*_way_*`);
- doubled spellings mapped to the shared semantic tags;
- whitespace/punctuation boundaries, intraword near-misses, and Unicode
  boundaries;
- code opacity plus an outer phrase containing `@...@`;
- same-line behavior across a Textile hard break;
- exact outer/inner/text spans and arena-owned code payloads; and
- a large alternating matched/near-miss marker storm rendered twice for
  deterministic linear behavior.
