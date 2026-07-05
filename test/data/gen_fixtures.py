#!/usr/bin/env python3
"""Generate byte-for-byte fixture pairs for mojo-template.

Renders a fixed set of templates against a shared context with Jinja2
(autoescape=True — the same escaping/whitespace defaults mojo-template
targets) and writes a single manifest that the Mojo test harness reads.

The Mojo side (`test/test_template.mojo`, `sample_context()`) builds the
same context by hand; keep the two in sync. Run:

    .venv/bin/python test/data/gen_fixtures.py

Manifest format (`test/data/fixtures/manifest.txt`): records separated by
0x1D (group separator); within a record three fields separated by 0x1E
(record separator): name, template source, expected output. These control
bytes never appear in the fixtures themselves.
"""

import os

try:
    from jinja2 import Environment
except ImportError:  # pragma: no cover
    raise SystemExit(
        "jinja2 not installed. Run: uv pip install jinja2 (in the project venv)"
    )

# Shared context. Mirror this exactly in sample_context() on the Mojo side.
CONTEXT = {
    "name": "Conor & Kate",
    "greeting": "hello world",
    "count": 3,
    "price": 2.5,
    "active": True,
    "html": "<b>Hi</b>",
    "items": ["apple", "banana", "cherry"],
    "nums": [1, 2, 3],
    "user": {"name": "Conor", "role": "lead"},
    "people": [
        {"name": "Ann", "admin": True},
        {"name": "Bob", "admin": False},
    ],
    "empty": [],
    "word": "the QUICK brown fox",
    "long": "the quick brown fox jumps over the lazy dog",
}

# (name, template) pairs. Every template stays inside the v0.1 supported
# subset and references only defined variables (except the `default`
# cases, which deliberately exercise a missing name).
CASES = [
    ("var", "{{ name }}"),
    ("var_safe", "{{ name | safe }}"),
    ("dotted", "{{ user.name }}"),
    ("index_num", "{{ items[0] }}"),
    ("index_str", "{{ user['role'] }}"),
    ("nested_access", "{{ people[0].name }}"),
    ("filter_upper", "{{ greeting | upper }}"),
    ("filter_lower", "{{ word | lower }}"),
    ("filter_title", "{{ greeting | title }}"),
    ("filter_trim", "{{ '  hi  ' | trim }}"),
    ("filter_length_list", "{{ items | length }}"),
    ("filter_length_str", "{{ greeting | length }}"),
    ("filter_default_missing", "{{ missing | default('N/A') }}"),
    ("filter_default_present", "{{ user.name | default('anon') }}"),
    ("filter_join", "{{ items | join(', ') }}"),
    ("filter_escape", "{{ html | escape }}"),
    ("filter_safe", "{{ html | safe }}"),
    ("autoescape_default", "{{ html }}"),
    ("filter_truncate", "{{ long | truncate(20) }}"),
    ("filter_replace", "{{ greeting | replace('o', '0') }}"),
    ("filter_first", "{{ items | first }}"),
    ("filter_last", "{{ items | last }}"),
    ("chained_filters", "{{ greeting | upper | replace('O', '0') }}"),
    ("arith_add", "{{ count + 2 }}"),
    ("arith_sub", "{{ count - 1 }}"),
    ("concat_plus", "{{ 'Hi ' + user.name }}"),
    ("cmp_eq", "{% if count == 3 %}yes{% else %}no{% endif %}"),
    (
        "cmp_chain",
        "{% if count > 5 %}big{% elif count > 1 %}mid{% else %}small{% endif %}",
    ),
    ("logic_and", "{% if active and count > 0 %}on{% else %}off{% endif %}"),
    ("logic_not", "{% if not active %}off{% else %}on{% endif %}"),
    ("logic_or", "{{ empty or 'fallback' }}"),
    ("for_basic", "{% for i in items %}{{ i }} {% endfor %}"),
    (
        "for_loop_meta",
        "{% for i in items %}{{ loop.index }}:{{ i }}"
        "{% if not loop.last %}, {% endif %}{% endfor %}",
    ),
    (
        "for_first_last",
        "{% for i in nums %}{% if loop.first %}[{% endif %}{{ i }}"
        "{% if loop.last %}]{% else %},{% endif %}{% endfor %}",
    ),
    (
        "nested_for_if",
        "{% for p in people %}{{ p.name }}{% if p.admin %}*{% endif %} "
        "{% endfor %}",
    ),
    ("set_stmt", "{% set x = count + 10 %}{{ x }}"),
    ("comment", "a{# hidden #}b"),
    ("ws_trim", "{% for i in nums -%} {{ i }} {%- endfor %}"),
    ("bool_output", "{{ active }}"),
    ("float_output", "{{ price }}"),
    ("str_literal", "{{ 'literal & text' }}"),
    ("cmp_ne", "{% if user.role != 'admin' %}not-admin{% endif %}"),
    ("cmp_le_ge", "{% if count <= 3 and count >= 3 %}exact{% endif %}"),
]


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, "fixtures")
    os.makedirs(out_dir, exist_ok=True)
    env = Environment(autoescape=True)
    records = []
    for name, template in CASES:
        rendered = env.from_string(template).render(**CONTEXT)
        for field in (name, template, rendered):
            assert "\x1e" not in field and "\x1d" not in field, name
        records.append("\x1e".join((name, template, rendered)))
    manifest = "\x1d".join(records)
    with open(os.path.join(out_dir, "manifest.txt"), "w", encoding="utf-8") as f:
        f.write(manifest)
    # Also emit individual .out files for human inspection / diffing.
    for name, template in CASES:
        rendered = env.from_string(template).render(**CONTEXT)
        with open(os.path.join(out_dir, name + ".out"), "w", encoding="utf-8") as f:
            f.write(rendered)
    print(f"wrote {len(CASES)} fixtures to {out_dir}")


if __name__ == "__main__":
    main()
