"""Parser: tokens -> a `Template` (statement + expression arenas).

Like the value model and mojo-markdown's `BlockTree`, the AST is stored as
flat arenas of non-recursive nodes referenced by index — `stmts` for
statements, `exprs` for expressions — so the recursive grammar never needs
a self-referential struct.

Expression grammar, lowest to highest precedence (matching Jinja):

    or  <  and  <  not  <  comparison  <  +/-  <  unary-  <  postfix( . [] | )

Filters (`|`) bind at the postfix level — tighter than arithmetic, looser
than attribute/item access — so `a.b | upper` is `(a.b) | upper` and
`x + y | f` is `x + (y | f)`, as in Jinja.
"""

from template.errors import parse_error
from template.lexer import Token, TT_TEXT, TT_OUTPUT, TT_BLOCK, tokenize
from template.value import TemplateValue

# Maximum nesting depth accepted by the parser, for both block statements
# (nested if/for) and expressions (chained `not`/unary-`-`, parenthes-
# ized/indexed/filter-arg subexpressions). Recursive-descent parsing and
# recursive `_eval` both consume native stack per level, so an unbounded
# nest (e.g. a 50k-deep `not` chain or thousands of nested `{% if %}`)
# would overflow the stack and crash the process. Matches the renderer's
# `_MAX_DEPTH` so a template that parses can also render.
comptime _MAX_PARSE_DEPTH = 256

# ---- expression node kinds ----------------------------------------------
comptime EX_LIT = 0
comptime EX_VAR = 1
comptime EX_ATTR = 2
comptime EX_ITEM = 3
comptime EX_FILTER = 4
comptime EX_NOT = 5
comptime EX_NEG = 6
comptime EX_AND = 7
comptime EX_OR = 8
comptime EX_CMP = 9
comptime EX_ADD = 10
comptime EX_SUB = 11

# comparison operators
comptime CMP_EQ = 0
comptime CMP_NE = 1
comptime CMP_LT = 2
comptime CMP_GT = 3
comptime CMP_LE = 4
comptime CMP_GE = 5

# ---- statement node kinds -----------------------------------------------
comptime ST_TEXT = 0
comptime ST_OUTPUT = 1
comptime ST_IF = 2
comptime ST_FOR = 3
comptime ST_SET = 4

# ---- expression tokens --------------------------------------------------
comptime ET_NAME = 0
comptime ET_INT = 1
comptime ET_FLOAT = 2
comptime ET_STR = 3
comptime ET_PUNCT = 4
comptime ET_EOF = 5


@fieldwise_init
struct _Expr(Copyable, Movable):
    var kind: Int
    var a: Int  # left / base child expr index (-1 if none)
    var b: Int  # right / index child expr index (-1 if none)
    var op: Int  # comparison op code for EX_CMP
    var name: String  # variable / attribute / filter name
    var args: List[Int]  # filter argument expr indices
    var lit: TemplateValue  # literal value for EX_LIT


@fieldwise_init
struct _Stmt(Copyable, Movable):
    var kind: Int
    var text: String  # ST_TEXT literal
    var expr: Int  # ST_OUTPUT / ST_SET value / ST_FOR iterable
    var name: String  # ST_FOR loop variable / ST_SET target
    var body: List[Int]  # ST_FOR body statement indices
    var conds: List[Int]  # ST_IF: one condition expr index per if/elif branch
    var branches: List[List[Int]]  # ST_IF: bodies, parallel to conds
    var else_body: List[Int]  # ST_IF: else branch (empty if none)
    var has_else: Bool


@fieldwise_init
struct _ETok(Copyable, Movable):
    var kind: Int
    var text: String
    var ival: Int
    var fval: Float64
    var off: Int  # absolute byte offset of the token start in the source


struct Template(Copyable, Movable):
    var stmts: List[_Stmt]
    var exprs: List[_Expr]
    var root_body: List[Int]

    def __init__(
        out self,
        var stmts: List[_Stmt],
        var exprs: List[_Expr],
        var root_body: List[Int],
    ):
        self.stmts = stmts^
        self.exprs = exprs^
        self.root_body = root_body^


def _is_ident_start(b: UInt8) -> Bool:
    return (
        (Int(b) >= ord("a") and Int(b) <= ord("z"))
        or (Int(b) >= ord("A") and Int(b) <= ord("Z"))
        or Int(b) == ord("_")
    )


def _is_ident(b: UInt8) -> Bool:
    return _is_ident_start(b) or (Int(b) >= ord("0") and Int(b) <= ord("9"))


def _is_digit(b: UInt8) -> Bool:
    return Int(b) >= ord("0") and Int(b) <= ord("9")


def _lex_expr(
    src: String, base: Int, tsrc: Span[UInt8, _]
) raises -> List[_ETok]:
    """Tokenize an expression string into `_ETok`s (with trailing EOF).

    `src` is a slice of the template source starting at byte `base`; each
    token records its absolute offset (`base` + position in `src`) so
    errors can point into the full template `tsrc`.
    """
    var bytes = src.as_bytes()
    var n = len(bytes)
    var i = 0
    var toks = List[_ETok]()
    while i < n:
        var b = bytes[i]
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D:
            i += 1
            continue
        if _is_ident_start(b):
            var start = i
            while i < n and _is_ident(bytes[i]):
                i += 1
            toks.append(
                _ETok(
                    ET_NAME,
                    String(StringSlice(unsafe_from_utf8=bytes[start:i])),
                    0,
                    0.0,
                    base + start,
                )
            )
            continue
        if _is_digit(b):
            var start = i
            var is_float = False
            while i < n and _is_digit(bytes[i]):
                i += 1
            if (
                i < n
                and Int(bytes[i]) == ord(".")
                and i + 1 < n
                and _is_digit(bytes[i + 1])
            ):
                is_float = True
                i += 1
                while i < n and _is_digit(bytes[i]):
                    i += 1
            var text = String(StringSlice(unsafe_from_utf8=bytes[start:i]))
            if is_float:
                toks.append(
                    _ETok(ET_FLOAT, text^, 0, Float64(atof(text)), base + start)
                )
            else:
                toks.append(
                    _ETok(ET_INT, text^, Int(atol(text)), 0.0, base + start)
                )
            continue
        if Int(b) == ord('"') or Int(b) == ord("'"):
            var quote = b
            var qstart = i
            i += 1
            var buf = String()
            while i < n and bytes[i] != quote:
                if Int(bytes[i]) == ord("\\") and i + 1 < n:
                    var e = bytes[i + 1]
                    if Int(e) == ord("n"):
                        buf += "\n"
                    elif Int(e) == ord("t"):
                        buf += "\t"
                    elif Int(e) == ord("\\"):
                        buf += "\\"
                    elif Int(e) == ord("'"):
                        buf += "'"
                    elif Int(e) == ord('"'):
                        buf += '"'
                    else:
                        buf += String(
                            StringSlice(unsafe_from_utf8=bytes[i + 1 : i + 2])
                        )
                    i += 2
                    continue
                buf += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
                i += 1
            if i >= n:
                raise parse_error(
                    "mojo-template: unterminated string literal",
                    tsrc,
                    base + qstart,
                )
            i += 1  # closing quote
            toks.append(_ETok(ET_STR, buf^, 0, 0.0, base + qstart))
            continue
        # Punctuation. Two-character operators first.
        if i + 1 < n:
            var two = String(StringSlice(unsafe_from_utf8=bytes[i : i + 2]))
            if two == "==" or two == "!=" or two == "<=" or two == ">=":
                toks.append(_ETok(ET_PUNCT, two^, 0, 0.0, base + i))
                i += 2
                continue
        var one = String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
        if (
            one == "<"
            or one == ">"
            or one == "+"
            or one == "-"
            or one == "|"
            or one == "."
            or one == "["
            or one == "]"
            or one == "("
            or one == ")"
            or one == ","
            or one == "="
        ):
            toks.append(_ETok(ET_PUNCT, one^, 0, 0.0, base + i))
            i += 1
            continue
        raise parse_error(
            "mojo-template: unexpected character '" + one + "' in expression",
            tsrc,
            base + i,
        )
    toks.append(_ETok(ET_EOF, String(), 0, 0.0, base + n))
    return toks^


struct _Parser(Copyable, Movable):
    var tokens: List[Token]
    var source: String  # full template source, for error positions
    var pos: Int
    var stmts: List[_Stmt]
    var exprs: List[_Expr]

    def __init__(out self, var tokens: List[Token], var source: String):
        self.tokens = tokens^
        self.source = source^
        self.pos = 0
        self.stmts = List[_Stmt]()
        self.exprs = List[_Expr]()

    def _finish(deinit self, var root: List[Int]) -> Template:
        return Template(self.stmts^, self.exprs^, root^)

    def _err(self, msg: String, offset: Int) -> Error:
        """`msg` located at byte `offset` of the template source."""
        return parse_error(msg, self.source.as_bytes(), offset)

    # -- expression arena helpers -----------------------------------------
    def _emit(mut self, var e: _Expr) -> Int:
        self.exprs.append(e^)
        return len(self.exprs) - 1

    def _emit_stmt(mut self, var s: _Stmt) -> Int:
        self.stmts.append(s^)
        return len(self.stmts) - 1

    # -- expression parsing (over an _ETok list + cursor) -----------------
    def parse_expr_string(mut self, src: String, base: Int) raises -> Int:
        var toks = _lex_expr(src, base, self.source.as_bytes())
        var p = 0
        var idx = self._p_or(toks, p, 0)
        if toks[p].kind != ET_EOF:
            raise self._err(
                "mojo-template: trailing tokens in expression", toks[p].off
            )
        return idx

    def _p_or(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        if depth > _MAX_PARSE_DEPTH:
            raise self._err(
                "mojo-template: maximum expression nesting depth exceeded",
                toks[p].off,
            )
        var left = self._p_and(toks, p, depth)
        while toks[p].kind == ET_NAME and toks[p].text == "or":
            p += 1
            var right = self._p_and(toks, p, depth)
            left = self._emit(
                _Expr(EX_OR, left, right, 0, String(), [], TemplateValue.none())
            )
        return left

    def _p_and(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        var left = self._p_not(toks, p, depth)
        while toks[p].kind == ET_NAME and toks[p].text == "and":
            p += 1
            var right = self._p_not(toks, p, depth)
            left = self._emit(
                _Expr(
                    EX_AND, left, right, 0, String(), [], TemplateValue.none()
                )
            )
        return left

    def _p_not(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        if depth > _MAX_PARSE_DEPTH:
            raise self._err(
                "mojo-template: maximum expression nesting depth exceeded",
                toks[p].off,
            )
        if toks[p].kind == ET_NAME and toks[p].text == "not":
            p += 1
            var operand = self._p_not(toks, p, depth + 1)
            return self._emit(
                _Expr(
                    EX_NOT, operand, -1, 0, String(), [], TemplateValue.none()
                )
            )
        return self._p_cmp(toks, p, depth)

    def _p_cmp(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        var left = self._p_add(toks, p, depth)
        if toks[p].kind == ET_PUNCT:
            ref t = toks[p].text
            var op = -1
            if t == "==":
                op = CMP_EQ
            elif t == "!=":
                op = CMP_NE
            elif t == "<":
                op = CMP_LT
            elif t == ">":
                op = CMP_GT
            elif t == "<=":
                op = CMP_LE
            elif t == ">=":
                op = CMP_GE
            if op >= 0:
                p += 1
                var right = self._p_add(toks, p, depth)
                return self._emit(
                    _Expr(
                        EX_CMP,
                        left,
                        right,
                        op,
                        String(),
                        [],
                        TemplateValue.none(),
                    )
                )
        return left

    def _p_add(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        var left = self._p_unary(toks, p, depth)
        while toks[p].kind == ET_PUNCT and (
            toks[p].text == "+" or toks[p].text == "-"
        ):
            var is_add = toks[p].text == "+"
            p += 1
            var right = self._p_unary(toks, p, depth)
            left = self._emit(
                _Expr(
                    EX_ADD if is_add else EX_SUB,
                    left,
                    right,
                    0,
                    String(),
                    [],
                    TemplateValue.none(),
                )
            )
        return left

    def _p_unary(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        if depth > _MAX_PARSE_DEPTH:
            raise self._err(
                "mojo-template: maximum expression nesting depth exceeded",
                toks[p].off,
            )
        if toks[p].kind == ET_PUNCT and toks[p].text == "-":
            p += 1
            var operand = self._p_unary(toks, p, depth + 1)
            return self._emit(
                _Expr(
                    EX_NEG, operand, -1, 0, String(), [], TemplateValue.none()
                )
            )
        return self._p_postfix(toks, p, depth)

    def _p_postfix(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        var node = self._p_primary(toks, p, depth)
        # `.attr`, `[idx]`, and `| filter` links accumulate iteratively here,
        # so a long postfix chain parses at constant recursion depth — but it
        # builds an equally long `e.a` spine that `_eval` walks recursively at
        # render time. Count the spine so a pathological chain is rejected up
        # front (bounding both arena growth and eval recursion) under the same
        # cap the prefix/structural guards use, rather than only failing later
        # in `_eval` after the whole arena is materialized.
        var spine_depth = depth
        while True:
            ref t = toks[p]
            var is_postfix = t.kind == ET_PUNCT and (
                t.text == "." or t.text == "[" or t.text == "|"
            )
            if is_postfix:
                spine_depth += 1
                if spine_depth > _MAX_PARSE_DEPTH:
                    raise self._err(
                        (
                            "mojo-template: maximum expression nesting depth"
                            " exceeded"
                        ),
                        t.off,
                    )
            if t.kind == ET_PUNCT and t.text == ".":
                p += 1
                if toks[p].kind != ET_NAME:
                    raise self._err(
                        "mojo-template: expected attribute name after '.'",
                        toks[p].off,
                    )
                var attr = toks[p].text.copy()
                p += 1
                node = self._emit(
                    _Expr(EX_ATTR, node, -1, 0, attr^, [], TemplateValue.none())
                )
            elif t.kind == ET_PUNCT and t.text == "[":
                p += 1
                var index = self._p_or(toks, p, depth + 1)
                if not (toks[p].kind == ET_PUNCT and toks[p].text == "]"):
                    raise self._err("mojo-template: expected ']'", toks[p].off)
                p += 1
                node = self._emit(
                    _Expr(
                        EX_ITEM,
                        node,
                        index,
                        0,
                        String(),
                        [],
                        TemplateValue.none(),
                    )
                )
            elif t.kind == ET_PUNCT and t.text == "|":
                p += 1
                if toks[p].kind != ET_NAME:
                    raise self._err(
                        "mojo-template: expected filter name after '|'",
                        toks[p].off,
                    )
                var fname = toks[p].text.copy()
                p += 1
                var args = List[Int]()
                if toks[p].kind == ET_PUNCT and toks[p].text == "(":
                    p += 1
                    if not (toks[p].kind == ET_PUNCT and toks[p].text == ")"):
                        args.append(self._p_or(toks, p, depth + 1))
                        while toks[p].kind == ET_PUNCT and toks[p].text == ",":
                            p += 1
                            args.append(self._p_or(toks, p, depth + 1))
                    if not (toks[p].kind == ET_PUNCT and toks[p].text == ")"):
                        raise self._err(
                            "mojo-template: expected ')' after filter args",
                            toks[p].off,
                        )
                    p += 1
                node = self._emit(
                    _Expr(
                        EX_FILTER,
                        node,
                        -1,
                        0,
                        fname^,
                        args^,
                        TemplateValue.none(),
                    )
                )
            else:
                break
        return node

    def _p_primary(
        mut self, toks: List[_ETok], mut p: Int, depth: Int
    ) raises -> Int:
        if depth > _MAX_PARSE_DEPTH:
            raise self._err(
                "mojo-template: maximum expression nesting depth exceeded",
                toks[p].off,
            )
        ref t = toks[p]
        if t.kind == ET_INT:
            p += 1
            return self._emit(
                _Expr(EX_LIT, -1, -1, 0, String(), [], TemplateValue(t.ival))
            )
        if t.kind == ET_FLOAT:
            p += 1
            return self._emit(
                _Expr(EX_LIT, -1, -1, 0, String(), [], TemplateValue(t.fval))
            )
        if t.kind == ET_STR:
            p += 1
            return self._emit(
                _Expr(
                    EX_LIT,
                    -1,
                    -1,
                    0,
                    String(),
                    [],
                    TemplateValue(t.text.copy()),
                )
            )
        if t.kind == ET_NAME:
            var nm = t.text
            if nm == "true" or nm == "True":
                p += 1
                return self._emit(
                    _Expr(EX_LIT, -1, -1, 0, String(), [], TemplateValue(True))
                )
            if nm == "false" or nm == "False":
                p += 1
                return self._emit(
                    _Expr(EX_LIT, -1, -1, 0, String(), [], TemplateValue(False))
                )
            if nm == "none" or nm == "None":
                p += 1
                return self._emit(
                    _Expr(EX_LIT, -1, -1, 0, String(), [], TemplateValue.none())
                )
            p += 1
            return self._emit(
                _Expr(EX_VAR, -1, -1, 0, nm.copy(), [], TemplateValue.none())
            )
        if t.kind == ET_PUNCT and t.text == "(":
            p += 1
            var inner = self._p_or(toks, p, depth + 1)
            if not (toks[p].kind == ET_PUNCT and toks[p].text == ")"):
                raise self._err("mojo-template: expected ')'", toks[p].off)
            p += 1
            return inner
        raise self._err(
            "mojo-template: unexpected token '" + t.text + "' in expression",
            t.off,
        )

    # -- statement parsing ------------------------------------------------
    def _block_word(self, inner: String) -> String:
        var b = inner.as_bytes()
        var i = 0
        while i < len(b) and (b[i] == 0x20 or b[i] == 0x09):
            i += 1
        var start = i
        while i < len(b) and not (
            b[i] == 0x20 or b[i] == 0x09 or b[i] == 0x0A or b[i] == 0x0D
        ):
            i += 1
        return String(StringSlice(unsafe_from_utf8=b[start:i]))

    def _word_end(self, inner: String, word: String) -> Int:
        """Byte offset within `inner` just past its leading whitespace and
        `word` — i.e. where `_after_word`'s result starts."""
        var b = inner.as_bytes()
        var i = 0
        while i < len(b) and (b[i] == 0x20 or b[i] == 0x09):
            i += 1
        return i + word.byte_length()

    def _after_word(self, inner: String, word: String) -> String:
        var b = inner.as_bytes()
        var i = self._word_end(inner, word)
        return String(StringSlice(unsafe_from_utf8=b[i : len(b)]))

    def parse_body(
        mut self, stops: List[String], depth: Int, opened_at: Int
    ) raises -> List[Int]:
        """Parse statements until a block whose keyword is in `stops`
        (left unconsumed) or EOF. Returns the statement indices.
        `opened_at` is the byte offset of the block tag that opened this
        body (0 for the template root), used to position depth errors."""
        if depth > _MAX_PARSE_DEPTH:
            raise self._err(
                "mojo-template: maximum block nesting depth exceeded",
                opened_at,
            )
        var body = List[Int]()
        while self.pos < len(self.tokens):
            var tok = self.tokens[self.pos].copy()
            if tok.kind == TT_TEXT:
                body.append(
                    self._emit_stmt(
                        _Stmt(
                            ST_TEXT,
                            tok.text.copy(),
                            -1,
                            String(),
                            [],
                            [],
                            [],
                            [],
                            False,
                        )
                    )
                )
                self.pos += 1
                continue
            if tok.kind == TT_OUTPUT:
                var e = self.parse_expr_string(tok.text, tok.content_offset)
                body.append(
                    self._emit_stmt(
                        _Stmt(
                            ST_OUTPUT,
                            String(),
                            e,
                            String(),
                            [],
                            [],
                            [],
                            [],
                            False,
                        )
                    )
                )
                self.pos += 1
                continue
            # TT_BLOCK
            var word = self._block_word(tok.text)
            for s in stops:
                if s == word:
                    return body^
            if word == "if":
                body.append(
                    self._parse_if(
                        tok.text, tok.offset, tok.content_offset, depth
                    )
                )
            elif word == "for":
                body.append(
                    self._parse_for(
                        tok.text, tok.offset, tok.content_offset, depth
                    )
                )
            elif word == "set":
                body.append(self._parse_set(tok.text, tok.content_offset))
            else:
                raise self._err(
                    "mojo-template: unknown or misplaced block tag '"
                    + word
                    + "'",
                    tok.offset,
                )
        return body^

    def _parse_if(
        mut self, inner: String, opened_at: Int, content_off: Int, depth: Int
    ) raises -> Int:
        var conds = List[Int]()
        var branches = List[List[Int]]()
        var cond_src = self._after_word(inner, String("if"))
        var cond_base = content_off + self._word_end(inner, String("if"))
        conds.append(self.parse_expr_string(cond_src, cond_base))
        self.pos += 1  # consume the {% if %}
        var stops = [String("elif"), String("else"), String("endif")]
        branches.append(self.parse_body(stops, depth + 1, opened_at))
        var else_body = List[Int]()
        var has_else = False
        while True:
            if self.pos >= len(self.tokens):
                raise self._err("mojo-template: unclosed {% if %}", opened_at)
            var tok = self.tokens[self.pos].copy()
            var word = self._block_word(tok.text)
            if word == "elif":
                var c = self._after_word(tok.text, String("elif"))
                var c_base = tok.content_offset + self._word_end(
                    tok.text, String("elif")
                )
                conds.append(self.parse_expr_string(c, c_base))
                self.pos += 1
                branches.append(self.parse_body(stops, depth + 1, tok.offset))
            elif word == "else":
                self.pos += 1
                has_else = True
                else_body = self.parse_body(
                    [String("endif")], depth + 1, tok.offset
                )
            elif word == "endif":
                self.pos += 1
                break
            else:
                raise self._err(
                    "mojo-template: expected elif/else/endif, got '"
                    + word
                    + "'",
                    tok.offset,
                )
        return self._emit_stmt(
            _Stmt(
                ST_IF,
                String(),
                -1,
                String(),
                [],
                conds^,
                branches^,
                else_body^,
                has_else,
            )
        )

    def _parse_for(
        mut self, inner: String, opened_at: Int, content_off: Int, depth: Int
    ) raises -> Int:
        var rest = self._after_word(inner, String("for"))
        var rest_base = content_off + self._word_end(inner, String("for"))
        var toks = _lex_expr(rest, rest_base, self.source.as_bytes())
        if toks[0].kind != ET_NAME:
            raise self._err(
                "mojo-template: expected loop variable in for", toks[0].off
            )
        var loop_var = toks[0].text.copy()
        if not (toks[1].kind == ET_NAME and toks[1].text == "in"):
            raise self._err("mojo-template: expected 'in' in for", toks[1].off)
        var p = 2
        var iter_expr = self._p_or(toks, p, 0)
        if toks[p].kind != ET_EOF:
            raise self._err(
                "mojo-template: trailing tokens in for", toks[p].off
            )
        self.pos += 1  # consume {% for %}
        var body = self.parse_body([String("endfor")], depth + 1, opened_at)
        if self.pos >= len(self.tokens):
            raise self._err("mojo-template: unclosed {% for %}", opened_at)
        self.pos += 1  # consume {% endfor %}
        return self._emit_stmt(
            _Stmt(
                ST_FOR,
                String(),
                iter_expr,
                loop_var^,
                body^,
                [],
                [],
                [],
                False,
            )
        )

    def _parse_set(mut self, inner: String, content_off: Int) raises -> Int:
        var rest = self._after_word(inner, String("set"))
        var rest_base = content_off + self._word_end(inner, String("set"))
        var toks = _lex_expr(rest, rest_base, self.source.as_bytes())
        if toks[0].kind != ET_NAME:
            raise self._err("mojo-template: expected name in set", toks[0].off)
        var target = toks[0].text.copy()
        if not (toks[1].kind == ET_PUNCT and toks[1].text == "="):
            raise self._err("mojo-template: expected '=' in set", toks[1].off)
        var p = 2
        var value_expr = self._p_or(toks, p, 0)
        if toks[p].kind != ET_EOF:
            raise self._err(
                "mojo-template: trailing tokens in set", toks[p].off
            )
        self.pos += 1
        return self._emit_stmt(
            _Stmt(ST_SET, String(), value_expr, target^, [], [], [], [], False)
        )


def parse_template(source: String) raises -> Template:
    var tokens = tokenize(source)
    var parser = _Parser(tokens^, source.copy())
    var root = parser.parse_body(List[String](), 0, 0)
    if parser.pos < len(parser.tokens):
        var tok = parser.tokens[parser.pos].copy()
        raise parser._err(
            "mojo-template: unexpected '"
            + parser._block_word(tok.text)
            + "' with no matching opener",
            tok.offset,
        )
    return parser^._finish(root^)
