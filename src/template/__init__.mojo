"""mojo-template: a standalone Jinja-flavored template engine for Mojo.

    from template import render, TemplateValue, Context

    var ctx = Context()
    ctx["name"] = TemplateValue("world")
    print(render("Hello {{ name }}!", ctx))   # Hello world!
"""

from template.value import TemplateValue, Context
from template.render import render, escape_html
