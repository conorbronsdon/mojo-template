# Security Policy

mojo-template is a pure-Mojo template engine with no network access, no
file I/O in the render path, and no code-execution surface — it turns a
template string plus a data context into an output string. Output is
HTML-escaped by default (Jinja `autoescape=True` semantics), and there is
a recursion/nesting depth cap (256) to bound pathological templates. The
main risk surface is a malformed or adversarial template causing a crash
or hang, which the fuzz target (`test/fuzz_runner.mojo`) exercises.

If you find a template that crashes, hangs, produces unescaped output
where escaping is expected, or otherwise misbehaves in a security-relevant
way (out-of-bounds access, unbounded memory growth, escaping bypass),
please report it via a
[GitHub issue](https://github.com/conorbronsdon/mojo-template/issues),
including a minimal reproduction (template source + context).

This is a personal open-source project maintained on a best-effort basis —
there's no formal SLA, but reports are welcome and taken seriously.
