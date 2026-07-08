"""Throughput benchmark for `render` over the Jinja2 parity corpus.

Times the full parse+render path (autoescape on, strict-undefined) across
every template in `test/data/fixtures/manifest.txt` — the same corpus the
byte-match parity test replays, against the same context. The fixtures are
tiny (~2.3 KB of template source total), so each measurement pass renders
the whole corpus and we run many passes for stable numbers. Run compiled
for meaningful numbers:
`mojo build -I src bench/bench_render.mojo -o .bench_render &&
./.bench_render` (or `pixi run bench`).
"""
from std.time import perf_counter_ns

from template import render, TemplateValue, Context


def bench_context() raises -> Context:
    """Mirror of `CONTEXT` in test/data/gen_fixtures.py (same as the tests)."""
    var ctx = Context()
    ctx["name"] = TemplateValue("Conor & Kate")
    ctx["greeting"] = TemplateValue("hello world")
    ctx["count"] = TemplateValue(3)
    ctx["price"] = TemplateValue(2.5)
    ctx["active"] = TemplateValue(True)
    ctx["html"] = TemplateValue("<b>Hi</b>")
    ctx["items"] = TemplateValue.list(
        [
            TemplateValue("apple"),
            TemplateValue("banana"),
            TemplateValue("cherry"),
        ]
    )
    ctx["nums"] = TemplateValue.list(
        [TemplateValue(1), TemplateValue(2), TemplateValue(3)]
    )
    ctx["user"] = TemplateValue.dict(
        ["name", "role"], [TemplateValue("Conor"), TemplateValue("lead")]
    )
    ctx["people"] = TemplateValue.list(
        [
            TemplateValue.dict(
                ["name", "admin"], [TemplateValue("Ann"), TemplateValue(True)]
            ),
            TemplateValue.dict(
                ["name", "admin"], [TemplateValue("Bob"), TemplateValue(False)]
            ),
        ]
    )
    ctx["empty"] = TemplateValue.list([])
    ctx["word"] = TemplateValue("the QUICK brown fox")
    ctx["long"] = TemplateValue("the quick brown fox jumps over the lazy dog")
    return ctx^


def _split(s: String, delim: UInt8) -> List[String]:
    var b = s.as_bytes()
    var out = List[String]()
    var start = 0
    for i in range(len(b)):
        if b[i] == delim:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
    out.append(String(StringSlice(unsafe_from_utf8=b[start : len(b)])))
    return out^


def main() raises:
    var manifest = open("test/data/fixtures/manifest.txt", "r").read()
    var records = _split(manifest, 0x1D)
    var templates = List[String]()
    var source_bytes = 0
    for rec in records:
        var fields = _split(rec, 0x1E)
        if len(fields) != 3:
            continue
        templates.append(fields[1])
        source_bytes += fields[1].byte_length()
    var ctx = bench_context()

    # Warmup + correctness anchor: total output bytes must stay stable.
    var expected_out = 0
    for tmpl in templates:
        expected_out += render(tmpl, ctx).byte_length()

    comptime PASSES = 2000
    var start = perf_counter_ns()
    for _ in range(PASSES):
        var out_bytes = 0
        for tmpl in templates:
            out_bytes += render(tmpl, ctx).byte_length()
        if out_bytes != expected_out:
            raise Error("inconsistent render")
    var elapsed_ns = perf_counter_ns() - start
    var per_pass_ms = Float64(elapsed_ns) / Float64(PASSES) / 1e6
    var per_render_us = (
        Float64(elapsed_ns) / Float64(PASSES * len(templates)) / 1e3
    )
    var mb_per_s = (Float64(source_bytes) / (1024.0 * 1024.0)) / (
        per_pass_ms / 1000.0
    )
    print(t"{len(templates)} templates, {source_bytes} bytes of source")
    print(t"  {per_pass_ms} ms/corpus pass ({PASSES} passes)")
    print(t"  {per_render_us} us/render, {mb_per_s} MB/s of template source")
