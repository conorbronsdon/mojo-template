"""Tokenizer: splits template source into text, `{{ }}`, and `{% %}` tokens.

Comments (`{# #}`) are recognized and dropped. Whitespace-control markers
are honored: a `-` immediately inside a tag's opening (`{{-`, `{%-`, `{#-`)
strips trailing whitespace off the preceding text, and a `-` immediately
inside a tag's close (`-}}`, `-%}`, `-#}`) strips leading whitespace off the
following text. This mirrors Jinja's defaults (`trim_blocks` and
`lstrip_blocks` off), so only explicit `-` markers trim.

Each token carries the 1-based line on which its tag opened, so the parser
can attach line numbers to errors without re-scanning.
"""

comptime TT_TEXT = 0
comptime TT_OUTPUT = 1  # {{ expr }}
comptime TT_BLOCK = 2  # {% stmt %}

comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _PCT = UInt8(ord("%"))
comptime _HASH = UInt8(ord("#"))
comptime _MINUS = UInt8(ord("-"))
comptime _NL = UInt8(0x0A)


@fieldwise_init
struct Token(Copyable, Movable):
    var kind: Int
    var text: String  # literal text, or the inner source of the tag (trimmed)
    var line: Int


def _is_ws(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


def _slice(bytes: Span[UInt8, _], start: Int, end: Int) -> String:
    if end <= start:
        return String()
    return String(StringSlice(unsafe_from_utf8=bytes[start:end]))


def _rstrip(s: String) -> String:
    var b = s.as_bytes()
    var end = len(b)
    while end > 0 and _is_ws(b[end - 1]):
        end -= 1
    return _slice(b, 0, end)


def _lstrip(s: String) -> String:
    var b = s.as_bytes()
    var start = 0
    while start < len(b) and _is_ws(b[start]):
        start += 1
    return _slice(b, start, len(b))


def tokenize(source: String) raises -> List[Token]:
    var bytes = source.as_bytes()
    var n = len(bytes)
    var tokens = List[Token]()
    var i = 0
    var line = 1
    var text_start = 0
    var lstrip_next = False  # a preceding `-}}`/`-%}`/`-#}` asked to lstrip

    while i < n:
        var is_open = (
            bytes[i] == _LBRACE
            and i + 1 < n
            and (
                bytes[i + 1] == _LBRACE
                or bytes[i + 1] == _PCT
                or bytes[i + 1] == _HASH
            )
        )
        if not is_open:
            if bytes[i] == _NL:
                line += 1
            i += 1
            continue

        # Flush the text run that precedes this tag.
        var text = _slice(bytes, text_start, i)
        var trim_left = i + 2 < n and bytes[i + 2] == _MINUS
        if trim_left:
            text = _rstrip(text)
        if lstrip_next:
            text = _lstrip(text)
        if text.byte_length() > 0:
            tokens.append(Token(TT_TEXT, text^, line))

        var kind_byte = bytes[i + 1]
        var tag_line = line
        # Locate the matching close sequence.
        var content_start = i + 2 + (1 if trim_left else 0)
        var closer_first = _RBRACE if kind_byte == _LBRACE else kind_byte
        var j = content_start
        var close_at = -1
        while j + 1 < n:
            if bytes[j] == closer_first and bytes[j + 1] == _RBRACE:
                close_at = j
                break
            if bytes[j] == _NL:
                line += 1
            j += 1
        if close_at == -1:
            raise Error(
                "mojo-template: unclosed tag opened on line "
                + String(tag_line)
            )
        var trim_right = (
            close_at > content_start and bytes[close_at - 1] == _MINUS
        )
        var content_end = close_at - (1 if trim_right else 0)
        var inner = _slice(bytes, content_start, content_end)

        if kind_byte == _LBRACE:
            tokens.append(Token(TT_OUTPUT, inner^, tag_line))
        elif kind_byte == _PCT:
            tokens.append(Token(TT_BLOCK, inner^, tag_line))
        # `#` comment: emit nothing.

        lstrip_next = trim_right
        i = close_at + 2
        text_start = i

    # Trailing text after the last tag.
    var tail = _slice(bytes, text_start, n)
    if lstrip_next:
        tail = _lstrip(tail)
    if tail.byte_length() > 0:
        tokens.append(Token(TT_TEXT, tail^, line))
    return tokens^
