"""Renderer: walk a parsed `Template` against a context and produce output.

Output is HTML-escaped by default (Jinja `autoescape=True` semantics);
`{{ x | safe }}` opts a value out and `{{ x | escape }}` forces escaping.
Expression results that are undefined (a missing variable / attribute /
key) are an error to render directly — this is stricter than Jinja, which
would emit an empty string — but the `default` filter still catches them,
so `{{ missing | default('x') }}` works.
"""

from template.value import TemplateValue, Context, VK_STRING, VK_FLOAT
from template.parser import (
    Template,
    _Expr,
    _Stmt,
    parse_template,
    EX_LIT,
    EX_VAR,
    EX_ATTR,
    EX_ITEM,
    EX_FILTER,
    EX_NOT,
    EX_NEG,
    EX_AND,
    EX_OR,
    EX_CMP,
    EX_ADD,
    EX_SUB,
    CMP_EQ,
    CMP_NE,
    CMP_LT,
    CMP_GT,
    CMP_LE,
    CMP_GE,
    ST_TEXT,
    ST_OUTPUT,
    ST_IF,
    ST_FOR,
    ST_SET,
)

# Maximum recursive render depth (nested if/for). Guards against
# pathological templates, matching the sibling libraries' 256 cap.
comptime _MAX_DEPTH = 256


@fieldwise_init
struct _Eval(Copyable, Movable):
    """An evaluated expression plus whether its string form is already
    safe (must not be re-escaped on output)."""

    var value: TemplateValue
    var safe: Bool


# ---- HTML escaping ------------------------------------------------------

def _push(mut out: List[UInt8], s: StaticString):
    for b in s.as_bytes():
        out.append(b)


def escape_html(s: String) -> String:
    """Escape `& < > ' "` exactly as MarkupSafe/Jinja autoescape does."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    for k in range(len(b)):
        var c = b[k]
        if Int(c) == ord("&"):
            _push(out, "&amp;")
        elif Int(c) == ord("<"):
            _push(out, "&lt;")
        elif Int(c) == ord(">"):
            _push(out, "&gt;")
        elif Int(c) == ord("'"):
            _push(out, "&#39;")
        elif Int(c) == ord('"'):
            _push(out, "&#34;")
        else:
            out.append(c)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


# ---- string filter helpers ----------------------------------------------

def _is_alpha(b: UInt8) -> Bool:
    return (Int(b) >= ord("a") and Int(b) <= ord("z")) or (
        Int(b) >= ord("A") and Int(b) <= ord("Z")
    )


def _title(s: String) -> String:
    """Jinja `title`: capitalize each word, lowercasing the rest. Word
    boundaries are whitespace and `- ( [ { <` (Jinja's split set)."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var at_boundary = True
    for k in range(len(b)):
        var c = b[k]
        var is_boundary = (
            c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D
            or Int(c) == ord("-") or Int(c) == ord("(") or Int(c) == ord("[")
            or Int(c) == ord("{") or Int(c) == ord("<")
        )
        if _is_alpha(c):
            if at_boundary and Int(c) >= ord("a") and Int(c) <= ord("z"):
                out.append(c - 32)
            elif not at_boundary and Int(c) >= ord("A") and Int(c) <= ord("Z"):
                out.append(c + 32)
            else:
                out.append(c)
            at_boundary = False
        else:
            out.append(c)
            at_boundary = is_boundary
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _replace(s: String, old: String, new: String) -> String:
    return s.replace(old, new)


def _truncate(s: String, length: Int) -> String:
    """Jinja `truncate(length)` with its defaults: leeway=5, end='...',
    killwords=False. Operates on codepoints so multi-byte text is safe."""
    var chars = List[String]()
    for cp in s.codepoint_slices():
        chars.append(String(cp))
    if len(chars) <= length + 5:
        return s.copy()
    var keep = length - 3  # len("...")
    if keep < 0:
        keep = 0
    var prefix = String()
    for k in range(keep):
        prefix += chars[k]
    var last_space = prefix.rfind(" ")
    var cut: String
    if last_space >= 0:
        cut = String(StringSlice(unsafe_from_utf8=prefix.as_bytes()[0:last_space]))
    else:
        cut = prefix^
    return cut + "..."


# ---- expression evaluation ----------------------------------------------

def _lookup(scope: Context, name: String) raises -> TemplateValue:
    if name in scope:
        return scope[name].copy()
    return TemplateValue.undefined()


def _eval(tmpl: Template, idx: Int, scope: Context, depth: Int) raises -> _Eval:
    # Left-associative operator chains (`+`, `and`, `or`) and postfix chains
    # (`.attr`, `[idx]`, `| filter`) are built iteratively by the parser, so
    # their parse depth stays constant no matter how long the chain is — the
    # parser's nesting guard never trips. But evaluating them recurses down
    # `e.a` once per link, consuming native stack per level, so an unbounded
    # chain (e.g. `{{ 1 + 1 + ...(50k) }}` or `{{ x | upper | ...(50k) }}`)
    # would overflow the stack and SIGSEGV the process. Bound eval recursion
    # to the same 256 cap the parser uses so such a template raises cleanly.
    if depth > _MAX_DEPTH:
        raise Error("mojo-template: maximum expression evaluation depth exceeded")
    ref e = tmpl.exprs[idx]
    var k = e.kind
    if k == EX_LIT:
        return _Eval(e.lit.copy(), False)
    if k == EX_VAR:
        var val = _lookup(scope, e.name)
        var s = val.safe
        return _Eval(val^, s)
    if k == EX_ATTR:
        var base = _eval(tmpl, e.a, scope, depth + 1)
        return _Eval(base.value.get_attr(e.name), False)
    if k == EX_ITEM:
        var base = _eval(tmpl, e.a, scope, depth + 1)
        var index = _eval(tmpl, e.b, scope, depth + 1)
        if index.value.kind() == VK_STRING:
            return _Eval(base.value.get_attr(index.value.render_str()), False)
        if index.value.is_numeric():
            return _Eval(
                base.value.get_index(Int(index.value.as_number())), False
            )
        raise Error("mojo-template: invalid subscript type")
    if k == EX_FILTER:
        return _apply_filter(tmpl, e, scope, depth)
    if k == EX_NOT:
        var v = _eval(tmpl, e.a, scope, depth + 1)
        return _Eval(TemplateValue(not v.value.is_truthy()), False)
    if k == EX_NEG:
        var v = _eval(tmpl, e.a, scope, depth + 1)
        if v.value.kind() == VK_FLOAT:
            return _Eval(TemplateValue(-v.value.as_number()), False)
        return _Eval(TemplateValue(-Int(v.value.as_number())), False)
    if k == EX_AND:
        var l = _eval(tmpl, e.a, scope, depth + 1)
        if not l.value.is_truthy():
            return l^
        return _eval(tmpl, e.b, scope, depth + 1)
    if k == EX_OR:
        var l = _eval(tmpl, e.a, scope, depth + 1)
        if l.value.is_truthy():
            return l^
        return _eval(tmpl, e.b, scope, depth + 1)
    if k == EX_CMP:
        var l = _eval(tmpl, e.a, scope, depth + 1)
        var r = _eval(tmpl, e.b, scope, depth + 1)
        var result: Bool
        if e.op == CMP_EQ:
            result = l.value.equals(r.value)
        elif e.op == CMP_NE:
            result = not l.value.equals(r.value)
        elif e.op == CMP_LT:
            result = l.value.compare(r.value) < 0
        elif e.op == CMP_GT:
            result = l.value.compare(r.value) > 0
        elif e.op == CMP_LE:
            result = l.value.compare(r.value) <= 0
        else:  # CMP_GE
            result = l.value.compare(r.value) >= 0
        return _Eval(TemplateValue(result), False)
    if k == EX_ADD or k == EX_SUB:
        var l = _eval(tmpl, e.a, scope, depth + 1)
        var r = _eval(tmpl, e.b, scope, depth + 1)
        if l.value.is_numeric() and r.value.is_numeric():
            var lk = l.value.kind()
            var rk = r.value.kind()
            if lk == VK_FLOAT or rk == VK_FLOAT:
                var x = l.value.as_number()
                var y = r.value.as_number()
                return _Eval(TemplateValue(x + y if k == EX_ADD else x - y), False)
            var xi = Int(l.value.as_number())
            var yi = Int(r.value.as_number())
            return _Eval(
                TemplateValue(xi + yi if k == EX_ADD else xi - yi), False
            )
        if (
            k == EX_ADD
            and l.value.kind() == VK_STRING
            and r.value.kind() == VK_STRING
        ):
            return _Eval(
                TemplateValue(l.value.render_str() + r.value.render_str()),
                False,
            )
        raise Error(
            "mojo-template: unsupported operand types for + / -"
        )
    raise Error("mojo-template: unknown expression node")


def _apply_filter(
    tmpl: Template, e: _Expr, scope: Context, depth: Int
) raises -> _Eval:
    # `e` is the filter node at `depth`; its operand and any arguments are
    # one level deeper, so pass `depth + 1` to keep long `| filter` chains
    # bounded by the same recursion cap as the rest of `_eval`.
    var base = _eval(tmpl, e.a, scope, depth + 1)
    var name = e.name
    var nargs = len(e.args)

    if name == "safe":
        return _Eval(base.value.as_safe(), True)
    if name == "escape" or name == "e":
        # `escape` is idempotent on already-safe values (Jinja: escaping a
        # Markup returns it unchanged), so `x | escape | escape` escapes
        # once rather than double-escaping.
        if base.safe:
            return base^
        return _Eval(
            TemplateValue(escape_html(base.value.render_str())).as_safe(), True
        )
    if name == "default" or name == "d":
        if nargs == 0:
            raise Error("mojo-template: default() requires an argument")
        var fallback_falsy = False
        if nargs >= 2:
            fallback_falsy = _eval(tmpl, e.args[1], scope, depth + 1).value.is_truthy()
        var use_default = base.value.is_undefined() or (
            fallback_falsy and not base.value.is_truthy()
        )
        if use_default:
            return _Eval(_eval(tmpl, e.args[0], scope, depth + 1).value.copy(), False)
        return base^
    # String-transforming filters preserve the safe flag of their input,
    # as Jinja's Markup string methods do (`markup | upper` stays Markup).
    if name == "upper":
        return _Eval(TemplateValue(base.value.render_str().upper()), base.safe)
    if name == "lower":
        return _Eval(TemplateValue(base.value.render_str().lower()), base.safe)
    if name == "title":
        return _Eval(TemplateValue(_title(base.value.render_str())), base.safe)
    if name == "trim":
        return _Eval(
            TemplateValue(String(StringSlice(base.value.render_str()).strip())),
            base.safe,
        )
    if name == "length" or name == "count":
        return _Eval(TemplateValue(base.value.length()), False)
    if name == "join":
        var sep = String()
        if nargs >= 1:
            sep = _eval(tmpl, e.args[0], scope, depth + 1).value.render_str()
        var parts = base.value.iter_values()
        var out = String()
        for j in range(len(parts)):
            if j > 0:
                out += sep
            out += parts[j].render_str()
        return _Eval(TemplateValue(out^), False)
    if name == "replace":
        if nargs < 2:
            raise Error("mojo-template: replace() requires two arguments")
        var old = _eval(tmpl, e.args[0], scope, depth + 1).value.render_str()
        var new = _eval(tmpl, e.args[1], scope, depth + 1).value.render_str()
        return _Eval(
            TemplateValue(_replace(base.value.render_str(), old, new)),
            base.safe,
        )
    if name == "truncate":
        var length = 255
        if nargs >= 1:
            length = Int(_eval(tmpl, e.args[0], scope, depth + 1).value.as_number())
        return _Eval(
            TemplateValue(_truncate(base.value.render_str(), length)),
            base.safe,
        )
    if name == "first":
        return _Eval(base.value.get_index(0), False)
    if name == "last":
        return _Eval(base.value.get_index(-1), False)
    raise Error("mojo-template: unknown filter '" + name + "'")


# ---- loop metadata ------------------------------------------------------

def _make_loop(index0: Int, length: Int) raises -> TemplateValue:
    var keys = [
        String("index"),
        String("index0"),
        String("first"),
        String("last"),
        String("length"),
        String("revindex"),
        String("revindex0"),
    ]
    var values = [
        TemplateValue(index0 + 1),
        TemplateValue(index0),
        TemplateValue(index0 == 0),
        TemplateValue(index0 == length - 1),
        TemplateValue(length),
        TemplateValue(length - index0),
        TemplateValue(length - index0 - 1),
    ]
    return TemplateValue.dict(keys, values)


# ---- statement rendering ------------------------------------------------

def _render_body(
    tmpl: Template,
    body: List[Int],
    mut scope: Context,
    mut out: String,
    depth: Int,
) raises:
    if depth > _MAX_DEPTH:
        raise Error("mojo-template: maximum render depth exceeded")
    for si in body:
        ref s = tmpl.stmts[si]
        var k = s.kind
        if k == ST_TEXT:
            out += s.text
        elif k == ST_OUTPUT:
            var r = _eval(tmpl, s.expr, scope, 0)
            if r.value.is_undefined():
                raise Error(
                    "mojo-template: attempted to render an undefined value"
                )
            if r.safe:
                out += r.value.render_str()
            else:
                out += escape_html(r.value.render_str())
        elif k == ST_SET:
            var v = _eval(tmpl, s.expr, scope, 0)
            # Persist the safe flag onto the stored value so that
            # `{% set y = x | safe %}` keeps `y` unescaped when emitted.
            var stored = v.value.copy()
            stored.safe = v.safe
            scope[s.name] = stored^
        elif k == ST_IF:
            var handled = False
            for bi in range(len(s.conds)):
                if _eval(tmpl, s.conds[bi], scope, 0).value.is_truthy():
                    _render_body(tmpl, s.branches[bi], scope, out, depth + 1)
                    handled = True
                    break
            if not handled and s.has_else:
                _render_body(tmpl, s.else_body, scope, out, depth + 1)
        elif k == ST_FOR:
            var it = _eval(tmpl, s.expr, scope, 0)
            if it.value.is_undefined():
                raise Error("mojo-template: cannot iterate an undefined value")
            var items = it.value.iter_values()
            # Jinja loop scoping: assignments made inside the loop body with
            # `{% set %}` are local to the loop — they neither accumulate
            # across iterations nor leak into the enclosing scope. Snapshot
            # the scope, reset to it before every iteration (so a counter
            # cannot carry over), and restore it after the loop (so nothing
            # set inside escapes). This also restores any name shadowed by
            # the loop variable or the `loop` object.
            var saved_scope = scope.copy()
            for ii in range(len(items)):
                scope = saved_scope.copy()
                scope[s.name] = items[ii].copy()
                scope[String("loop")] = _make_loop(ii, len(items))
                _render_body(tmpl, s.body, scope, out, depth + 1)
            scope = saved_scope^


def render(template_source: String, context: Context) raises -> String:
    """Compile `template_source` and render it against `context`.

    Raises with a line number on syntax errors, and (v0.1 strict policy)
    on rendering an undefined variable / attribute / index. Escaping is on
    by default; use `| safe` to emit raw HTML.
    """
    var tmpl = parse_template(template_source)
    var scope = context.copy()
    var out = String()
    _render_body(tmpl, tmpl.root_body, scope, out, 0)
    return out^
