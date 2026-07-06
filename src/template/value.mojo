"""The template value model.

A `TemplateValue` is a self-contained, recursive-by-value tree — a
scalar (none / bool / int / float / string) or a container (list / dict)
whose elements are themselves `TemplateValue`s. Because a struct cannot
directly contain itself in Mojo (a genuinely self-referential field is
not implicitly destructible), the tree is stored the way
mojo-markdown's `BlockTree` stores its nodes: as a flat arena
(`nodes`) of non-recursive `_VNode`s that reference their children by
integer index, with `root` naming the top node. Every `TemplateValue`
carries its own arena, so values compose and copy like ordinary values.

`Context = Dict[String, TemplateValue]`; users build values with the
constructors and the `list` / `dict` factories:

    var ctx = Context()
    ctx["name"] = TemplateValue("Ada")
    ctx["nums"] = TemplateValue.list([TemplateValue(1), TemplateValue(2)])
"""

comptime VK_NONE = 0
comptime VK_BOOL = 1
comptime VK_INT = 2
comptime VK_FLOAT = 3
comptime VK_STRING = 4
comptime VK_LIST = 5
comptime VK_DICT = 6
# Internal only: the result of looking up a name/attr/index that does not
# exist. Truthy-false, catchable by the `default` filter, and an error to
# render directly. Users do not construct these.
comptime VK_UNDEFINED = 7


@fieldwise_init
struct _VNode(Copyable, Movable):
    """One node in a `TemplateValue` arena. Never self-referential:
    `children` holds arena indices, not nested values."""

    var kind: Int
    var b: Bool
    var i: Int
    var f: Float64
    var s: String
    var children: List[Int]  # list elements, or dict values (parallel to keys)
    var keys: List[String]  # dict keys (parallel to children); empty otherwise


comptime Context = Dict[String, TemplateValue]


struct TemplateValue(Copyable, Movable, Writable):
    var nodes: List[_VNode]
    var root: Int
    # HTML-safe flag (Jinja `Markup`). When set, the renderer emits the
    # value without autoescaping and `escape` treats it as already-escaped
    # (idempotent). Carried on the value itself so safety survives storage
    # in the context via `{% set %}` and propagation through string
    # filters, matching Jinja's Markup semantics.
    var safe: Bool

    # ---- construction ---------------------------------------------------

    def __init__(out self, var nodes: List[_VNode], root: Int):
        self.nodes = nodes^
        self.root = root
        self.safe = False

    def as_safe(self) -> Self:
        """A copy of this value flagged HTML-safe (see `safe`)."""
        var c = self.copy()
        c.safe = True
        return c^

    @staticmethod
    def _leaf(var node: _VNode) -> Self:
        var nodes = List[_VNode]()
        nodes.append(node^)
        return Self(nodes^, 0)

    @implicit
    def __init__(out self, value: String):
        self = Self._leaf(
            _VNode(VK_STRING, False, 0, 0.0, value.copy(), [], [])
        )

    @implicit
    def __init__(out self, value: StringLiteral):
        self = Self._leaf(
            _VNode(VK_STRING, False, 0, 0.0, String(value), [], [])
        )

    @implicit
    def __init__(out self, value: Int):
        self = Self._leaf(_VNode(VK_INT, False, value, 0.0, String(), [], []))

    @implicit
    def __init__(out self, value: Bool):
        self = Self._leaf(_VNode(VK_BOOL, value, 0, 0.0, String(), [], []))

    @implicit
    def __init__(out self, value: Float64):
        self = Self._leaf(_VNode(VK_FLOAT, False, 0, value, String(), [], []))

    @staticmethod
    def none() -> Self:
        return Self._leaf(_VNode(VK_NONE, False, 0, 0.0, String(), [], []))

    @staticmethod
    def undefined() -> Self:
        return Self._leaf(_VNode(VK_UNDEFINED, False, 0, 0.0, String(), [], []))

    @staticmethod
    def _append_arena(mut dest: List[_VNode], src: TemplateValue) -> Int:
        """Append every node of `src`'s arena onto `dest`, shifting each
        node's child indices by the insertion offset, and return the new
        index of `src`'s root. No recursion: one flat pass, indices stay
        internally consistent because they all shift by the same base."""
        var base = len(dest)
        for k in range(len(src.nodes)):
            ref n = src.nodes[k]
            var shifted = List[Int]()
            for c in n.children:
                shifted.append(c + base)
            dest.append(
                _VNode(
                    n.kind, n.b, n.i, n.f, n.s.copy(), shifted^, n.keys.copy()
                )
            )
        return base + src.root

    @staticmethod
    def list(items: List[TemplateValue]) -> Self:
        var nodes = List[_VNode]()
        var child_idx = List[Int]()
        for it in items:
            child_idx.append(Self._append_arena(nodes, it))
        nodes.append(_VNode(VK_LIST, False, 0, 0.0, String(), child_idx^, []))
        return Self(nodes^, len(nodes) - 1)

    @staticmethod
    def dict(keys: List[String], values: List[TemplateValue]) raises -> Self:
        if len(keys) != len(values):
            raise Error("mojo-template: dict keys/values length mismatch")
        var nodes = List[_VNode]()
        var child_idx = List[Int]()
        for v in values:
            child_idx.append(Self._append_arena(nodes, v))
        nodes.append(
            _VNode(VK_DICT, False, 0, 0.0, String(), child_idx^, keys.copy())
        )
        return Self(nodes^, len(nodes) - 1)

    # ---- inspection -----------------------------------------------------

    def kind(self) -> Int:
        return self.nodes[self.root].kind

    def is_undefined(self) -> Bool:
        return self.nodes[self.root].kind == VK_UNDEFINED

    def is_none(self) -> Bool:
        return self.nodes[self.root].kind == VK_NONE

    def is_numeric(self) -> Bool:
        var k = self.nodes[self.root].kind
        return k == VK_INT or k == VK_FLOAT or k == VK_BOOL

    def as_number(self) -> Float64:
        ref n = self.nodes[self.root]
        if n.kind == VK_FLOAT:
            return n.f
        if n.kind == VK_BOOL:
            return 1.0 if n.b else 0.0
        return Float64(n.i)

    def is_truthy(self) -> Bool:
        ref n = self.nodes[self.root]
        var k = n.kind
        if k == VK_NONE or k == VK_UNDEFINED:
            return False
        if k == VK_BOOL:
            return n.b
        if k == VK_INT:
            return n.i != 0
        if k == VK_FLOAT:
            return n.f != 0.0
        if k == VK_STRING:
            return n.s.byte_length() > 0
        # list / dict
        return len(n.children) > 0

    def length(self) raises -> Int:
        ref n = self.nodes[self.root]
        if n.kind == VK_STRING:
            return n.s.count_codepoints()
        if n.kind == VK_LIST or n.kind == VK_DICT:
            return len(n.children)
        raise Error("mojo-template: object of this type has no length")

    def render_str(self) -> String:
        """The string Jinja's `str()` would produce for this value.

        Scalars only need be exact; container repr is best-effort (Python
        list/dict repr, documented as not byte-guaranteed) since templates
        iterate containers rather than printing them.
        """
        ref n = self.nodes[self.root]
        var k = n.kind
        if k == VK_NONE:
            return String("None")
        if k == VK_BOOL:
            return String("True") if n.b else String("False")
        if k == VK_INT:
            return String(n.i)
        if k == VK_FLOAT:
            return String(n.f)
        if k == VK_STRING:
            return n.s.copy()
        if k == VK_LIST:
            var out = String("[")
            for j in range(len(n.children)):
                if j > 0:
                    out += ", "
                out += self._child(n.children[j])._repr_str()
            return out + "]"
        if k == VK_DICT:
            var out = String("{")
            for j in range(len(n.children)):
                if j > 0:
                    out += ", "
                out += "'" + n.keys[j] + "': "
                out += self._child(n.children[j])._repr_str()
            return out + "}"
        return String()  # undefined -> caller handles

    def _repr_str(self) -> String:
        ref n = self.nodes[self.root]
        if n.kind == VK_STRING:
            return String("'") + n.s + "'"
        return self.render_str()

    def _child(self, idx: Int) -> Self:
        # Copy the whole arena and repoint the root; every index stays
        # valid. Unreferenced nodes are harmless (templates are small).
        return Self(self.nodes.copy(), idx)

    # ---- access (attribute / item / iteration) --------------------------

    def get_attr(self, key: String) -> Self:
        """`value.key` / `value["key"]` on a dict; undefined if absent."""
        ref n = self.nodes[self.root]
        if n.kind == VK_DICT:
            for j in range(len(n.keys)):
                if n.keys[j] == key:
                    return self._child(n.children[j])
        return Self.undefined()

    def get_index(self, i: Int) raises -> Self:
        """`value[i]` on a list (negative indexes from the end)."""
        ref n = self.nodes[self.root]
        if n.kind != VK_LIST:
            raise Error("mojo-template: value is not indexable by number")
        var idx = i
        if idx < 0:
            idx += len(n.children)
        if idx < 0 or idx >= len(n.children):
            raise Error("mojo-template: list index out of range")
        return self._child(n.children[idx])

    def iter_values(self) raises -> List[Self]:
        """Elements to iterate in `{% for x in value %}`. Lists yield
        elements; dicts yield their keys (as Jinja does)."""
        ref n = self.nodes[self.root]
        var out = List[Self]()
        if n.kind == VK_LIST:
            for c in n.children:
                out.append(self._child(c))
        elif n.kind == VK_DICT:
            for k in n.keys:
                out.append(Self(k.copy()))
        else:
            raise Error("mojo-template: value is not iterable")
        return out^

    # ---- comparison -----------------------------------------------------

    def equals(self, other: Self) -> Bool:
        if self.is_numeric() and other.is_numeric():
            return self.as_number() == other.as_number()
        ref a = self.nodes[self.root]
        ref b = other.nodes[other.root]
        if a.kind == VK_STRING and b.kind == VK_STRING:
            return a.s == b.s
        if a.kind == VK_NONE or a.kind == VK_UNDEFINED:
            return b.kind == VK_NONE or b.kind == VK_UNDEFINED
        return False

    def compare(self, other: Self) raises -> Int:
        """-1 / 0 / 1 for `self <=> other`; raises on unorderable types."""
        if self.is_numeric() and other.is_numeric():
            var x = self.as_number()
            var y = other.as_number()
            if x < y:
                return -1
            return 1 if x > y else 0
        ref a = self.nodes[self.root]
        ref b = other.nodes[other.root]
        if a.kind == VK_STRING and b.kind == VK_STRING:
            if a.s < b.s:
                return -1
            return 1 if a.s > b.s else 0
        raise Error("mojo-template: values are not comparable with < > <= >=")

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.render_str())
