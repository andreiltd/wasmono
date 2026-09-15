"""Focused runtime checks for toolchain paths, npm entrypoints, and linking."""

load("@prelude//:prelude.bzl", "native")
load("@wasmono//:defs.bzl", "wasm_test")
load("@wasmono//toolchains/wasm:binaryen.bzl", "BinaryenInfo")
load("@wasmono//toolchains/wasm:node.bzl", "NodeInfo")

def _test_result(command):
    return [
        DefaultInfo(),
        RunInfo(args = command),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [command],
            run_from_project_root = True,
            use_project_relative_paths = True,
        ),
    ]

def _binaryen_test_impl(ctx):
    binaryen = ctx.attrs._binaryen[BinaryenInfo]
    return _test_result(cmd_args(getattr(binaryen, ctx.attrs.utility), "--version"))

binaryen_test = rule(
    impl = _binaryen_test_impl,
    attrs = {
        "utility": attrs.enum(["wasm_opt", "wasm_dis", "wasm_as", "wasm2js", "wasm_metadce"]),
        "_binaryen": attrs.toolchain_dep(default = "toolchains//:binaryen", providers = [BinaryenInfo]),
    },
)

def _npm_bin_test_impl(ctx):
    return _test_result(cmd_args(ctx.attrs._node[NodeInfo].node, ctx.attrs.src, ctx.attrs._npm_bin))

npm_bin_test = rule(
    impl = _npm_bin_test_impl,
    attrs = {
        "src": attrs.source(),
        "_node": attrs.toolchain_dep(default = "toolchains//:node", providers = [NodeInfo]),
        "_npm_bin": attrs.source(default = "wasmono//tools:npm_bin"),
    },
)

def link_whole_fixture(driver, main):
    native.cxx_library(
        name = "whole_archive_" + driver,
        srcs = ["registration.c"],
        link_whole = True,
        preferred_linkage = "static",
        _cxx_toolchain = ":cxx_" + driver,
    )
    native.cxx_binary(
        name = "link_whole_" + driver,
        srcs = [main],
        deps = [":whole_archive_" + driver],
        link_style = "static",
        _cxx_toolchain = ":cxx_" + driver,
    )
    wasm_test(
        name = "link_whole_" + driver + "_check",
        component = ":link_whole_" + driver,
    )
