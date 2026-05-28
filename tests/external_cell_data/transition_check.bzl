load("@wasmono//:defs.bzl", "wasm_transition_p1")

def _wasip1_transition_check_impl(ctx: AnalysisContext) -> list[Provider]:
    return [ctx.attrs.actual[DefaultInfo]]

wasip1_transition_check = rule(
    impl = _wasip1_transition_check_impl,
    attrs = {
        "actual": attrs.transition_dep(cfg = wasm_transition_p1),
    },
)
