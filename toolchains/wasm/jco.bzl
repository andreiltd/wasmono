"""jco toolchain for building WebAssembly components from JavaScript.

jco (JavaScript Component Toolchain) provides tools for building, transpiling,
and running WebAssembly components from JavaScript source files using the
Component Model.

This toolchain expects `jco` to be available on the system PATH (installed
via `npm install -g @bytecodealliance/jco`).
"""

load(
    "@prelude//os_lookup:defs.bzl",
    "ScriptLanguage",
)
load(
    "@prelude//utils:cmd_script.bzl",
    "cmd_script",
)

JcoInfo = provider(
    # @unsorted-dict-items
    fields = {
        "componentize": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for jco",
)

def _system_jco_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    jco = cmd_script(
        ctx = ctx,
        name = "jco",
        cmd = cmd_args("jco"),
        language = ScriptLanguage("sh"),
    )

    componentize = cmd_script(
        ctx = ctx,
        name = "jco_componentize",
        cmd = cmd_args("jco", "componentize"),
        language = ScriptLanguage("sh"),
    )

    return [
        DefaultInfo(),
        JcoInfo(
            componentize = RunInfo(args = cmd_args(componentize)),
        ),
    ]

system_jco_toolchain = rule(
    impl = _system_jco_toolchain_impl,
    attrs = {},
    is_toolchain_rule = True,
    doc = "System jco toolchain (requires jco on PATH via npm install -g @bytecodealliance/jco)",
)
