"""Example: render a small HTML email body from a context.

    mojo run -I src examples/render_email.mojo
"""

from template import render, TemplateValue, Context


def main() raises:
    var ctx = Context()
    ctx["subject"] = TemplateValue("Weekly digest for <you> & the team")
    ctx["user"] = TemplateValue.dict(["name"], [TemplateValue("Conor")])
    ctx["episodes"] = TemplateValue.list(
        [
            TemplateValue.dict(
                ["title", "guest"],
                [
                    TemplateValue("Scaling inference"),
                    TemplateValue("A. Rivera"),
                ],
            ),
            TemplateValue.dict(
                ["title", "guest"],
                [TemplateValue("Compilers & GPUs"), TemplateValue("J. Okafor")],
            ),
        ]
    )

    var source = String(
        "<h1>{{ subject }}</h1>\n"
        "<p>Hi {{ user.name | default('there') }},</p>\n"
        "<p>{{ episodes | length }} new episode"
        "{% if episodes | length != 1 %}s{% endif %} this week:</p>\n"
        "<ol>\n"
        "{% for ep in episodes -%}\n"
        "  <li>{{ loop.index }}. <b>{{ ep.title }}</b> — {{ ep.guest }}</li>\n"
        "{% endfor -%}\n"
        "</ol>\n"
    )

    print(render(source, ctx))
