"""Fuzz target: render argv[1] as a template with a small canned context.

Raising (a syntax or evaluation error) is a valid outcome; crashing or
hanging is not. Feed it arbitrary bytes:

    mojo run -I src test/fuzz_runner.mojo "{% for x in items %}{{ x }}{% endfor %}"
"""

from std.sys import argv

from template import render, TemplateValue, Context


def _context() raises -> Context:
    var ctx = Context()
    ctx["name"] = TemplateValue("world")
    ctx["count"] = TemplateValue(3)
    ctx["active"] = TemplateValue(True)
    ctx["items"] = TemplateValue.list(
        [TemplateValue("a"), TemplateValue("b"), TemplateValue("c")]
    )
    ctx["user"] = TemplateValue.dict(
        ["name", "role"], [TemplateValue("Ada"), TemplateValue("lead")]
    )
    return ctx^


def main():
    if len(argv()) < 2:
        print("usage: fuzz_runner <template-source>")
        return
    try:
        var out = render(String(argv()[1]), _context())
        print("ok:", len(out.as_bytes()), "bytes")
    except e:
        print("raised:", e)
