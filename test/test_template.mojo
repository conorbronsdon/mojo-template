"""Test suite for mojo-template.

Two layers:

1. Hand-written per-feature tests (every syntax construct, every filter,
   escaping, loop metadata, nested structures, and the documented error
   cases).
2. A parity test that replays `test/data/fixtures/manifest.txt` — templates
   rendered by Jinja2 (`test/data/gen_fixtures.py`, autoescape=True) — and
   asserts mojo-template reproduces each output byte-for-byte. The context
   built by `sample_context()` mirrors the generator's `CONTEXT`.
"""

from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from template import render, TemplateValue, Context, escape_html


# ---- shared contexts ----------------------------------------------------

def sample_context() raises -> Context:
    """Mirror of `CONTEXT` in test/data/gen_fixtures.py."""
    var ctx = Context()
    ctx["name"] = TemplateValue("Conor & Kate")
    ctx["greeting"] = TemplateValue("hello world")
    ctx["count"] = TemplateValue(3)
    ctx["price"] = TemplateValue(2.5)
    ctx["active"] = TemplateValue(True)
    ctx["html"] = TemplateValue("<b>Hi</b>")
    ctx["items"] = TemplateValue.list(
        [TemplateValue("apple"), TemplateValue("banana"), TemplateValue("cherry")]
    )
    ctx["nums"] = TemplateValue.list(
        [TemplateValue(1), TemplateValue(2), TemplateValue(3)]
    )
    ctx["user"] = TemplateValue.dict(
        ["name", "role"], [TemplateValue("Conor"), TemplateValue("lead")]
    )
    ctx["people"] = TemplateValue.list(
        [
            TemplateValue.dict(
                ["name", "admin"], [TemplateValue("Ann"), TemplateValue(True)]
            ),
            TemplateValue.dict(
                ["name", "admin"], [TemplateValue("Bob"), TemplateValue(False)]
            ),
        ]
    )
    ctx["empty"] = TemplateValue.list([])
    ctx["word"] = TemplateValue("the QUICK brown fox")
    ctx["long"] = TemplateValue("the quick brown fox jumps over the lazy dog")
    return ctx^


def r(source: String) raises -> String:
    return render(source, sample_context())


# ---- output, escaping, safe --------------------------------------------

def test_plain_text() raises:
    assert_equal(render("no tags here", Context()), "no tags here")


def test_variable() raises:
    assert_equal(r("{{ greeting }}"), "hello world")


def test_autoescape_ampersand() raises:
    assert_equal(r("{{ name }}"), "Conor &amp; Kate")


def test_autoescape_html_tags() raises:
    assert_equal(r("{{ html }}"), "&lt;b&gt;Hi&lt;/b&gt;")


def test_safe_filter_opts_out() raises:
    assert_equal(r("{{ html | safe }}"), "<b>Hi</b>")


def test_escape_filter_forces() raises:
    assert_equal(r("{{ html | escape }}"), "&lt;b&gt;Hi&lt;/b&gt;")


def test_string_literal_is_escaped() raises:
    assert_equal(r("{{ 'a & b' }}"), "a &amp; b")


def test_escape_html_helper() raises:
    assert_equal(escape_html(String("<a href=\"x\">'&")), "&lt;a href=&#34;x&#34;&gt;&#39;&amp;")


# ---- access -------------------------------------------------------------

def test_dotted_access() raises:
    assert_equal(r("{{ user.name }}"), "Conor")


def test_index_numeric() raises:
    assert_equal(r("{{ items[0] }}"), "apple")


def test_index_string_key() raises:
    assert_equal(r("{{ user['role'] }}"), "lead")


def test_nested_access() raises:
    assert_equal(r("{{ people[0].name }}"), "Ann")


def test_negative_index() raises:
    assert_equal(r("{{ items[-1] }}"), "cherry")


# ---- filters ------------------------------------------------------------

def test_filter_upper() raises:
    assert_equal(r("{{ greeting | upper }}"), "HELLO WORLD")


def test_filter_lower() raises:
    assert_equal(r("{{ word | lower }}"), "the quick brown fox")


def test_filter_title() raises:
    assert_equal(r("{{ greeting | title }}"), "Hello World")


def test_filter_trim() raises:
    assert_equal(r("{{ '  hi  ' | trim }}"), "hi")


def test_filter_length_list() raises:
    assert_equal(r("{{ items | length }}"), "3")


def test_filter_length_string() raises:
    assert_equal(r("{{ greeting | length }}"), "11")


def test_filter_default_missing() raises:
    assert_equal(r("{{ missing | default('N/A') }}"), "N/A")


def test_filter_default_present() raises:
    assert_equal(r("{{ user.name | default('anon') }}"), "Conor")


def test_filter_join() raises:
    assert_equal(r("{{ items | join(', ') }}"), "apple, banana, cherry")


def test_filter_truncate() raises:
    assert_equal(r("{{ long | truncate(20) }}"), "the quick brown...")


def test_filter_truncate_short_untouched() raises:
    assert_equal(r("{{ greeting | truncate(20) }}"), "hello world")


def test_filter_replace() raises:
    assert_equal(r("{{ greeting | replace('o', '0') }}"), "hell0 w0rld")


def test_filter_first() raises:
    assert_equal(r("{{ items | first }}"), "apple")


def test_filter_last() raises:
    assert_equal(r("{{ items | last }}"), "cherry")


def test_chained_filters() raises:
    assert_equal(r("{{ greeting | upper | replace('O', '0') }}"), "HELL0 W0RLD")


# ---- arithmetic & concatenation ----------------------------------------

def test_arith_add() raises:
    assert_equal(r("{{ count + 2 }}"), "5")


def test_arith_sub() raises:
    assert_equal(r("{{ count - 1 }}"), "2")


def test_unary_minus() raises:
    assert_equal(r("{{ -count }}"), "-3")


def test_string_concat() raises:
    assert_equal(r("{{ 'Hi ' + user.name }}"), "Hi Conor")


# ---- comparisons & logic ------------------------------------------------

def test_cmp_eq() raises:
    assert_equal(r("{% if count == 3 %}yes{% else %}no{% endif %}"), "yes")


def test_cmp_ne() raises:
    assert_equal(r("{% if user.role != 'admin' %}x{% endif %}"), "x")


def test_cmp_chain_elif() raises:
    assert_equal(
        r("{% if count > 5 %}big{% elif count > 1 %}mid{% else %}small{% endif %}"),
        "mid",
    )


def test_cmp_le_ge() raises:
    assert_equal(r("{% if count <= 3 and count >= 3 %}exact{% endif %}"), "exact")


def test_logic_and() raises:
    assert_equal(r("{% if active and count > 0 %}on{% else %}off{% endif %}"), "on")


def test_logic_not() raises:
    assert_equal(r("{% if not active %}off{% else %}on{% endif %}"), "on")


def test_logic_or_returns_operand() raises:
    assert_equal(r("{{ empty or 'fallback' }}"), "fallback")


# ---- for loops & metadata ----------------------------------------------

def test_for_basic() raises:
    assert_equal(r("{% for i in items %}{{ i }} {% endfor %}"), "apple banana cherry ")


def test_for_loop_index() raises:
    assert_equal(
        r(
            "{% for i in items %}{{ loop.index }}:{{ i }}"
            "{% if not loop.last %}, {% endif %}{% endfor %}"
        ),
        "1:apple, 2:banana, 3:cherry",
    )


def test_for_loop_first_last() raises:
    assert_equal(
        r(
            "{% for i in nums %}{% if loop.first %}[{% endif %}{{ i }}"
            "{% if loop.last %}]{% else %},{% endif %}{% endfor %}"
        ),
        "[1,2,3]",
    )


def test_nested_for_if() raises:
    assert_equal(
        r("{% for p in people %}{{ p.name }}{% if p.admin %}*{% endif %} {% endfor %}"),
        "Ann* Bob ",
    )


def test_for_over_dict_yields_keys() raises:
    assert_equal(r("{% for k in user %}{{ k }} {% endfor %}"), "name role ")


def test_for_empty() raises:
    assert_equal(r("{% for i in empty %}x{% endfor %}"), "")


# ---- set, comments, whitespace -----------------------------------------

def test_set() raises:
    assert_equal(r("{% set x = count + 10 %}{{ x }}"), "13")


def test_comment_dropped() raises:
    assert_equal(r("a{# hidden #}b"), "ab")


def test_whitespace_trim() raises:
    assert_equal(r("{% for i in nums -%} {{ i }} {%- endfor %}"), "123")


# ---- scalar output ------------------------------------------------------

def test_bool_output() raises:
    assert_equal(r("{{ active }}"), "True")


def test_float_output() raises:
    assert_equal(r("{{ price }}"), "2.5")


def test_none_output() raises:
    assert_equal(r("{{ none }}"), "None")


# ---- error cases (documented behavior) ---------------------------------

def test_error_unclosed_tag() raises:
    with assert_raises():
        _ = render("{{ name ", Context())


def test_error_unknown_filter() raises:
    with assert_raises():
        _ = r("{{ greeting | bogus }}")


def test_error_unknown_variable_render() raises:
    with assert_raises():
        _ = render("{{ nope }}", Context())


def test_error_unclosed_if() raises:
    with assert_raises():
        _ = r("{% if active %}yes")


def test_error_unclosed_for() raises:
    with assert_raises():
        _ = r("{% for i in items %}{{ i }}")


def test_error_iterate_undefined() raises:
    with assert_raises():
        _ = render("{% for i in nope %}x{% endfor %}", Context())


def test_error_bad_expression() raises:
    with assert_raises():
        _ = r("{{ count + }}")


# ---- hardening: parse-depth guard (no segfault on deep nesting) --------


def _repeat(s: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += s
    return out^


def test_deep_not_chain_raises() raises:
    # A pathological `not` chain must raise, not overflow the stack.
    with assert_raises():
        _ = r("{{ " + _repeat("not ", 5000) + "active }}")


def test_deep_nested_if_raises() raises:
    # A pathological nested-if must raise, not overflow the stack.
    with assert_raises():
        _ = r(
            _repeat("{% if active %}", 5000)
            + "x"
            + _repeat("{% endif %}", 5000)
        )


def test_deep_paren_chain_raises() raises:
    with assert_raises():
        _ = r("{{ " + _repeat("(", 5000) + "count" + _repeat(")", 5000) + " }}")


def test_legal_nesting_still_parses() raises:
    # 200 levels is comfortably under the 256 cap and must still work;
    # `not` applied an even number of times to `active` (True) is True.
    assert_equal(r("{{ " + _repeat("not ", 200) + "active }}"), "True")


# ---- hardening: render/eval-depth guard (no segfault on deep chains) ----
#
# The parse-depth guard only bounds parser-recursive constructs. Left-
# associative operator chains (`+`, `and`, `or`) and postfix chains
# (`.attr`, `[idx]`, `| filter`) are parsed iteratively, so they parse at
# constant depth no matter how long they are — but `_eval` recurses down
# `e.a` once per link at render time, so an unbounded chain would overflow
# the native stack and SIGSEGV. These must raise cleanly instead.


def test_deep_add_chain_raises() raises:
    # `{{ 1 + 1 + ...(50k) }}` parses fine (iterative) then blows the eval
    # stack without the guard. Must raise.
    with assert_raises():
        _ = r("{{ 1 " + _repeat("+ 1 ", 50000) + "}}")


def test_deep_and_chain_raises() raises:
    with assert_raises():
        _ = r("{{ active " + _repeat("and active ", 50000) + "}}")


def test_deep_or_chain_raises() raises:
    with assert_raises():
        _ = r("{{ active " + _repeat("or active ", 50000) + "}}")


def test_deep_attr_chain_raises() raises:
    # `{{ user.x.x.x...(50k) }}` builds a deep EX_ATTR spine.
    with assert_raises():
        _ = r("{{ user" + _repeat(".x", 50000) + " }}")


def test_deep_item_chain_raises() raises:
    # `{{ user['x']['x']...(50k) }}` builds a deep EX_ITEM spine.
    with assert_raises():
        _ = r("{{ user" + _repeat("['x']", 50000) + " }}")


def test_deep_filter_chain_raises() raises:
    # `{{ greeting | upper | upper ...(50k) }}` builds a deep EX_FILTER spine.
    with assert_raises():
        _ = r("{{ greeting " + _repeat("| upper ", 50000) + "}}")


def test_postfix_chain_over_cap_raises() raises:
    # A postfix `.attr` spine just past the 256 cap must be rejected at parse
    # time by `_p_postfix` — before the arena is fully materialized — not only
    # later by the `_eval` recursion guard. 300 links is over the cap but far
    # too shallow to overflow the native stack, so a crash here would mean the
    # parser spine guard is missing.
    with assert_raises():
        _ = r("{{ user" + _repeat(".x", 300) + " }}")


def test_legal_operator_chain_renders() raises:
    # 200 additions is well under the 256 eval cap and must still render.
    assert_equal(r("{{ 1" + _repeat(" + 1", 200) + " }}"), "201")


def test_legal_filter_chain_renders() raises:
    # 200 chained `| upper` filters is under the cap and must still render.
    assert_equal(
        r("{{ greeting " + _repeat("| upper ", 200) + "}}"), "HELLO WORLD"
    )


# ---- hardening: Jinja Markup / safe semantics --------------------------


def test_escape_is_idempotent() raises:
    # `x | escape | escape` escapes once, matching Jinja's Markup.
    assert_equal(r("{{ html | escape | escape }}"), "&lt;b&gt;Hi&lt;/b&gt;")


def test_safe_survives_set() raises:
    assert_equal(r("{% set y = html | safe %}{{ y }}"), "<b>Hi</b>")


def test_safe_survives_string_filter() raises:
    assert_equal(r("{{ html | safe | upper }}"), "<B>HI</B>")


def test_escape_of_safe_is_noop() raises:
    assert_equal(r("{% set y = html | safe %}{{ y | escape }}"), "<b>Hi</b>")


# ---- hardening: {% set %} loop scoping (Jinja semantics) ---------------


def test_set_in_for_does_not_leak() raises:
    assert_equal(
        r(
            "{% set counter = 0 %}{% for i in nums %}"
            "{% set counter = counter + 1 %}{% endfor %}{{ counter }}"
        ),
        "0",
    )


def test_set_in_for_resets_each_iteration() raises:
    assert_equal(
        r(
            "{% set c = 0 %}{% for i in nums %}{% set c = c + 1 %}{{ c }}"
            "{% endfor %}|{{ c }}"
        ),
        "111|0",
    )


# ---- Jinja2 byte-for-byte parity ---------------------------------------

def _split(s: String, delim: UInt8) -> List[String]:
    var b = s.as_bytes()
    var out = List[String]()
    var start = 0
    for i in range(len(b)):
        if b[i] == delim:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
    out.append(String(StringSlice(unsafe_from_utf8=b[start : len(b)])))
    return out^


def test_jinja2_fixture_parity() raises:
    var manifest = open("test/data/fixtures/manifest.txt", "r").read()
    var records = _split(manifest, 0x1D)
    var matched = 0
    for rec in records:
        var fields = _split(rec, 0x1E)
        if len(fields) != 3:
            continue
        var name = fields[0]
        var template = fields[1]
        var expected = fields[2]
        var got = render(template, sample_context())
        if got != expected:
            raise Error(
                "fixture '" + name + "' mismatch:\n  template: " + template
                + "\n  expected: [" + expected + "]\n  got:      [" + got + "]"
            )
        matched += 1
    assert_true(matched >= 25, "expected >= 25 fixtures, got " + String(matched))
    print("jinja2 fixture parity: matched", matched, "of", len(records))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
