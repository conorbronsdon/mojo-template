# Changelog

## Unreleased

- New `template.errors` module (exported from the package), following the
  error-reporting pattern shared across the mojo-* parser suite:
  `line_col(source, offset)` maps a byte offset to a 1-based (line, column)
  pair — the column is the 1-based BYTE offset within the line, no UTF-8
  decoding — and `parse_error(msg, source, offset)` builds an `Error`
  reading `<msg> at line <L>, column <C>: '<snippet>'`, where the snippet
  is up to ~30 bytes of the offending line centered on the column,
  whitespace-trimmed, with `...` where truncated, and never multi-line.
- Every lexer and parser error now carries that position + snippet
  (previously a bare `(line L)` suffix): unclosed tags and unclosed
  `{% if %}` / `{% for %}` point at the tag opener, and expression errors
  (unexpected character, unterminated string literal, bad/trailing tokens,
  missing `]` / `)` / filter or attribute name, depth-cap errors) point at
  the offending byte inside the tag. Tokens now carry byte offsets instead
  of line numbers; render-time errors (undefined variables, eval depth) are
  unchanged — the AST does not carry source positions.
- No mechanism change: parsing still `raise`s a plain `Error(...)`, no new
  error types.

## 0.1.0 — 2026-07-05

Initial release. A standalone Jinja-flavored template engine in pure Mojo:
`{{ }}` output with HTML autoescaping (and `| safe`), `{% if/elif/else %}`,
`{% for %}` with `loop.index`/`first`/`last`, `{% set %}`, `{# comments #}`,
and whitespace-control trim markers (`{%- -%}`). Expressions support
variables, dotted/index access, literals, `and`/`or`/`not`, comparisons,
`+`/`-` arithmetic and string concat, and a pipe-filter chain with 13
built-in filters (`upper`, `lower`, `title`, `trim`, `length`, `default`,
`join`, `escape`, `safe`, `truncate`, `replace`, `first`, `last`).

The value model and AST use the same flat index-arena pattern as
mojo-markdown's `BlockTree`, since a self-referential struct is not
implicitly destructible in Mojo. Errors carry line numbers (computed lazily
on the error path). Depth cap of 256 guards against pathological nesting.

Correctness is anchored to Jinja2: `test/data/gen_fixtures.py` renders 43
templates with Jinja2 (`autoescape=True`), and the test suite reproduces
every one byte-for-byte. 59 tests total, all green; fuzz target runs clean
on malformed input.

Out of scope for v0.1 (documented): template inheritance
(`{% extends %}`/`{% block %}`), `{% include %}`, macros, and custom
filters.
