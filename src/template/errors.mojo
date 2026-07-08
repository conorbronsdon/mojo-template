"""Position-aware parse errors.

`line_col` maps a byte offset in a source buffer to a 1-based
(line, column) pair, and `parse_error` builds an `Error` whose message
carries that position plus a short snippet of the offending line:

    <msg> at line <L>, column <C>: '<snippet>'

Positions are byte-based: the column is the 1-based BYTE offset within
the line, not a codepoint or display column. That keeps the computation
deterministic and free of UTF-8 decode cost; for ASCII-heavy markup the
byte column and the visual column coincide.

This module is the error-reporting pattern shared across the mojo-*
parser suite.
"""

comptime _LF = UInt8(0x0A)
comptime _CR = UInt8(0x0D)

# Snippet size budget, in bytes, before the `...` truncation markers are
# added. Wide enough to show meaningful context, narrow enough that error
# messages stay one readable line.
comptime _SNIPPET_BUDGET = 30


def _is_ws(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == _CR or b == _LF


def line_col(source: Span[UInt8, _], offset: Int) -> Tuple[Int, Int]:
    """1-based (line, column) of byte `offset` in `source`.

    The column is the 1-based BYTE offset within the line — codepoints
    are never decoded, so the result is cheap and deterministic even on
    invalid UTF-8. Only LF (0x0A) terminates a line: after a CRLF
    sequence the next byte is column 1 of the next line, with no phantom
    column contributed by the CR. An offset pointing AT an LF reports
    the line that newline terminates (column = line length + 1). Offsets
    past the end of `source` clamp to the end; an empty source yields
    (1, 1).
    """
    var limit = offset
    if limit > len(source):
        limit = len(source)
    if limit < 0:
        limit = 0
    var line = 1
    var last_nl = -1
    for i in range(limit):
        if source[i] == _LF:
            line += 1
            last_nl = i
    return (line, limit - last_nl)


def _snippet(source: Span[UInt8, _], offset: Int) -> String:
    """Up to ~`_SNIPPET_BUDGET` bytes of the line containing `offset`.

    The line is trimmed of leading/trailing whitespace (which also drops
    the CR of a CRLF line ending), then windowed around the offset with
    `...` marking each side that was cut. Window edges are nudged off
    UTF-8 continuation bytes so the result is always valid UTF-8. The
    result never contains a newline.
    """
    var n = len(source)
    var anchor = offset
    if anchor > n:
        anchor = n
    if anchor < 0:
        anchor = 0
    # Line bounds around the anchor; an anchor sitting AT an LF belongs
    # to the line that newline terminates.
    var line_start = anchor
    while line_start > 0 and source[line_start - 1] != _LF:
        line_start -= 1
    var line_end = anchor
    while line_end < n and source[line_end] != _LF:
        line_end += 1
    # Trim surrounding whitespace.
    while line_start < line_end and _is_ws(source[line_start]):
        line_start += 1
    while line_end > line_start and _is_ws(source[line_end - 1]):
        line_end -= 1
    var win_start = line_start
    var win_end = line_end
    var cut_left = False
    var cut_right = False
    if line_end - line_start > _SNIPPET_BUDGET:
        win_start = anchor - _SNIPPET_BUDGET // 2
        if win_start > line_end - _SNIPPET_BUDGET:
            win_start = line_end - _SNIPPET_BUDGET
        if win_start < line_start:
            win_start = line_start
        win_end = win_start + _SNIPPET_BUDGET
        # Never split a multi-byte UTF-8 sequence at a window edge.
        while win_start < win_end and (source[win_start] & 0xC0) == 0x80:
            win_start += 1
        while win_end < line_end and (source[win_end] & 0xC0) == 0x80:
            win_end += 1
        cut_left = win_start > line_start
        cut_right = win_end < line_end
    var out = String()
    if cut_left:
        out += "..."
    out += String(StringSlice(unsafe_from_utf8=source[win_start:win_end]))
    if cut_right:
        out += "..."
    return out^


def parse_error(msg: String, source: Span[UInt8, _], offset: Int) -> Error:
    """An `Error` locating `msg` at byte `offset` of `source`.

    The message is exactly:

        <msg> at line <L>, column <C>: '<snippet>'

    where line/column come from `line_col` (1-based; column is a byte
    offset within the line) and the snippet is the offending line,
    whitespace-trimmed and truncated to ~30 bytes centered on the
    column, with `...` where truncated. The message never contains a
    newline, so it renders on one line in test output and logs.
    """
    var lc = line_col(source, offset)
    return Error(
        msg
        + " at line "
        + String(lc[0])
        + ", column "
        + String(lc[1])
        + ": '"
        + _snippet(source, offset)
        + "'"
    )
