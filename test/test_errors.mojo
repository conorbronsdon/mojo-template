from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from template import render, Context
from template.errors import line_col, parse_error


def _assert_lc(source: String, offset: Int, line: Int, col: Int) raises:
    var lc = line_col(source.as_bytes(), offset)
    assert_equal(lc[0], line)
    assert_equal(lc[1], col)


def _msg(e: Error) -> String:
    return String.write(e)


# --------------------------------------------------------------------------
# line_col unit tests — every documented edge case.
# --------------------------------------------------------------------------


def test_line_col_offset_zero() raises:
    _assert_lc("abc", 0, 1, 1)


def test_line_col_empty_source() raises:
    _assert_lc("", 0, 1, 1)
    _assert_lc("", 7, 1, 1)


def test_line_col_negative_offset_clamps() raises:
    _assert_lc("abc", -5, 1, 1)


def test_line_col_middle_of_lines() raises:
    # "ab\ncd": a=0 b=1 \n=2 c=3 d=4
    _assert_lc("ab\ncd", 1, 1, 2)
    _assert_lc("ab\ncd", 3, 2, 1)
    _assert_lc("ab\ncd", 4, 2, 2)


def test_line_col_offset_at_newline() raises:
    # An offset AT a '\n' reports the line that newline terminates.
    _assert_lc("ab\ncd", 2, 1, 3)


def test_line_col_offset_past_end_clamps() raises:
    _assert_lc("ab\ncd", 5, 2, 3)  # == len
    _assert_lc("ab\ncd", 99, 2, 3)  # > len


def test_line_col_crlf_no_phantom_column() raises:
    # "ab\r\ncd": a=0 b=1 \r=2 \n=3 c=4 d=5. The byte after a CRLF is
    # column 1 of the next line — the '\r' contributes no phantom column.
    _assert_lc("ab\r\ncd", 4, 2, 1)
    _assert_lc("ab\r\ncd", 5, 2, 2)
    _assert_lc("ab\r\ncd", 2, 1, 3)  # at the '\r'
    _assert_lc("ab\r\ncd", 3, 1, 4)  # at the '\n' of the CRLF


def test_line_col_consecutive_newlines() raises:
    # "a\n\nb": a=0 \n=1 \n=2 b=3
    _assert_lc("a\n\nb", 2, 2, 1)
    _assert_lc("a\n\nb", 3, 3, 1)


def test_line_col_trailing_newline() raises:
    _assert_lc("ab\n", 3, 2, 1)


# --------------------------------------------------------------------------
# parse_error unit tests — exact message format + snippet behavior.
# --------------------------------------------------------------------------


def test_parse_error_exact_format() raises:
    var e = parse_error("boom", "hello".as_bytes(), 2)
    assert_equal(_msg(e), "boom at line 1, column 3: 'hello'")


def test_parse_error_multiline_source_single_line_message() raises:
    # Offset 8 is the 'n' of "line2"; snippet is that line only — the
    # message never embeds a newline.
    var e = parse_error("bad", "line1\nline2\nline3".as_bytes(), 8)
    assert_equal(_msg(e), "bad at line 2, column 3: 'line2'")


def test_parse_error_snippet_trims_whitespace() raises:
    # "   pad   ": offset 4 is the 'a'. Column counts the raw bytes, the
    # snippet is the trimmed line content.
    var e = parse_error("boom", "   pad   ".as_bytes(), 4)
    assert_equal(_msg(e), "boom at line 1, column 5: 'pad'")


def test_parse_error_offset_at_newline_snippet_is_ended_line() raises:
    var e = parse_error("boom", "ab\ncd".as_bytes(), 2)
    assert_equal(_msg(e), "boom at line 1, column 3: 'ab'")


def test_parse_error_crlf_line_has_no_stray_cr() raises:
    # The snippet for a CRLF-terminated line drops the '\r' (whitespace
    # trim), so the quoted snippet is clean.
    var e = parse_error("boom", "ab\r\ncd".as_bytes(), 1)
    assert_equal(_msg(e), "boom at line 1, column 2: 'ab'")


def test_parse_error_offset_past_end_clamps() raises:
    var e = parse_error("eof", "ab\ncd".as_bytes(), 99)
    assert_equal(_msg(e), "eof at line 2, column 3: 'cd'")


def test_parse_error_empty_source() raises:
    var e = parse_error("boom", "".as_bytes(), 0)
    assert_equal(_msg(e), "boom at line 1, column 1: ''")


def test_parse_error_truncates_both_sides() raises:
    # An 80-byte line with the offending '!' at offset 40: the snippet is
    # a 30-byte window centered on it, with '...' on both cut sides.
    var source = String()
    for _ in range(40):
        source += "x"
    source += "!"
    for _ in range(39):
        source += "x"
    var e = parse_error("bang", source.as_bytes(), 40)
    assert_equal(
        _msg(e),
        "bang at line 1, column 41: '...xxxxxxxxxxxxxxx!xxxxxxxxxxxxxx...'",
    )


def test_parse_error_truncates_right_only() raises:
    var source = String("abcde")
    for _ in range(75):
        source += "x"
    var e = parse_error("bang", source.as_bytes(), 0)
    assert_equal(
        _msg(e),
        "bang at line 1, column 1: 'abcdexxxxxxxxxxxxxxxxxxxxxxxxx...'",
    )


def test_parse_error_truncates_left_only() raises:
    var source = String()
    for _ in range(79):
        source += "x"
    source += "!"
    var e = parse_error("bang", source.as_bytes(), 79)
    assert_equal(
        _msg(e),
        "bang at line 1, column 80: '...xxxxxxxxxxxxxxxxxxxxxxxxxxxxx!'",
    )


def test_parse_error_snippet_never_splits_utf8() raises:
    # 40 'é' (2 bytes each, 80 bytes total); an offset landing mid-sequence
    # still yields a valid-UTF-8 snippet: window edges are nudged off
    # continuation bytes, so the snippet is whole codepoints only.
    var source = String()
    for _ in range(40):
        source += "é"
    var e = parse_error("bang", source.as_bytes(), 40)
    var rendered = _msg(e)
    assert_true(rendered.startswith("bang at line 1, column 41: '..."))
    # 30-byte budget at a 2-byte-char boundary nudge = 15 whole 'é'.
    var expected_snippet = String("'...")
    for _ in range(15):
        expected_snippet += "é"
    expected_snippet += "...'"
    assert_true(expected_snippet in rendered)


# --------------------------------------------------------------------------
# Integration — real malformed templates report hand-verified positions.
# --------------------------------------------------------------------------


def test_integration_unclosed_output_tag_position() raises:
    # "hello {{ name": the unterminated '{{' opens at byte 6 — line 1,
    # column 7. The position is the tag opener, not the useless EOF.
    with assert_raises(
        contains=(
            "mojo-template: unclosed tag at line 1, column 7: 'hello {{ name'"
        )
    ):
        _ = render("hello {{ name", Context())


def test_integration_bad_block_tag_on_line_3_position() raises:
    # "a\nb\n{% bogus %}": the offending tag opens at byte 4 — line 3
    # (newlines at 1 and 3), column 1.
    with assert_raises(
        contains=(
            "mojo-template: unknown or misplaced block tag 'bogus' at line 3,"
            " column 1: '{% bogus %}'"
        )
    ):
        _ = render("a\nb\n{% bogus %}", Context())


def test_integration_unexpected_character_position() raises:
    # "{{ name @ }}": the '@' is at byte 8 — line 1, column 9. Expression
    # errors point at the offending byte, not just the tag.
    with assert_raises(
        contains=(
            "mojo-template: unexpected character '@' in expression at line 1,"
            " column 9: '{{ name @ }}'"
        )
    ):
        _ = render("{{ name @ }}", Context())


def test_integration_unclosed_if_position() raises:
    # "{% if active %}yes": the '{% if %}' opens at byte 0 — line 1,
    # column 1.
    with assert_raises(
        contains=(
            "mojo-template: unclosed {% if %} at line 1, column 1:"
            " '{% if active %}yes'"
        )
    ):
        _ = render("{% if active %}yes", Context())


def test_integration_bad_expression_on_line_2_position() raises:
    # "ok\n{{ count + }}": the dangling '+' leaves the parser at the
    # closing '}' (byte 14) — line 2, column 12.
    with assert_raises(contains="at line 2, column 12: '{{ count + }}'"):
        _ = render("ok\n{{ count + }}", Context())


def test_integration_unterminated_string_literal_position() raises:
    # "{{ 'abc }}": the opening quote is at byte 3 — line 1, column 4.
    with assert_raises(
        contains=(
            "mojo-template: unterminated string literal at line 1, column 4"
        )
    ):
        _ = render("{{ 'abc }}", Context())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
