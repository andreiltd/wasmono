load("@wasmono//:defs.bzl", "WasmInfo", "WitBindingInfo")

def _component_file_impl(ctx):
    output = ctx.actions.declare_output(ctx.label.name)
    ctx.actions.run(
        cmd_args(ctx.attrs._wasm_tools[RunInfo], "parse", ctx.attrs.src, "-o", output.as_output()),
        category = "regression_component",
    )
    return [DefaultInfo(default_output = output)]

component_file = rule(
    impl = _component_file_impl,
    attrs = {
        "src": attrs.source(),
        "_wasm_tools": attrs.toolchain_dep(default = "toolchains//:wasm_tools", providers = [RunInfo]),
    },
)

def _metadata_impl(ctx):
    outputs = [ctx.attrs.payload] if ctx.attrs.payload != None else []
    providers = [DefaultInfo(default_outputs = outputs)]
    if "wasm" in ctx.attrs.kinds:
        providers.append(WasmInfo(component = ctx.attrs.component, wit = ctx.attrs.wit))
    if "bindings" in ctx.attrs.kinds:
        providers.append(WitBindingInfo(bindings = outputs, language = "rust", world = "api", wit = ctx.attrs.wit))
    return providers

metadata = rule(
    impl = _metadata_impl,
    attrs = {
        "component": attrs.option(attrs.source(), default = None),
        "kinds": attrs.list(attrs.enum(["wasm", "bindings"]), default = ["wasm"]),
        "payload": attrs.option(attrs.source(), default = None),
        "wit": attrs.list(attrs.source(), default = []),
    },
)

def _assert_wit_impl(ctx):
    actual = ctx.attrs.actual
    wits = actual[WitBindingInfo].wit if WitBindingInfo in actual else actual[WasmInfo].wit
    if wits != ctx.attrs.expected:
        fail("unexpected WIT metadata: expected {}, got {}".format(ctx.attrs.expected, wits))
    return [actual[DefaultInfo]]

assert_wit = rule(
    impl = _assert_wit_impl,
    attrs = {
        "actual": attrs.dep(),
        "expected": attrs.list(attrs.source()),
    },
)

def _bundle_impl(ctx):
    return [DefaultInfo(default_outputs = ctx.attrs.files)]

bundle = rule(
    impl = _bundle_impl,
    attrs = {"files": attrs.list(attrs.source())},
)
