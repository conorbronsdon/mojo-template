# Changelog

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
