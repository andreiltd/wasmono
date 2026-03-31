"""AssemblyScript toolchain for compiling TypeScript to WebAssembly.

Provides hermetic installation of the AssemblyScript compiler (`asc`) and
a rule to compile `.ts` files to `.wasm` modules.

## Examples

### Toolchain setup (in `toolchains/BUCK`)

```bzl
load("//wasm:node.bzl", "download_node", "node_toolchain")
load("//wasm:assemblyscript.bzl", "install_asc", "asc_toolchain")

download_node(name = "node_dist", version = "20.18.0")
node_toolchain(name = "node", distribution = ":node_dist", visibility = ["PUBLIC"])
install_asc(name = "asc_dist", node = ":node_dist")
asc_toolchain(name = "asc", distribution = ":asc_dist", visibility = ["PUBLIC"])
```

### Building an AssemblyScript module

```bzl
load("//wasm:assemblyscript.bzl", "assemblyscript_binary")

assemblyscript_binary(
    name = "my_module",
    src = "src/main.ts",
    wasi = True,
)
```
"""

load(
    ":node.bzl",
    "NodeInfo",
)
load("@prelude//decls:common.bzl", buck = "buck")
load("@prelude//os_lookup:defs.bzl", "Os", "OsLookup")

AscInfo = provider(
    # @unsorted-dict-items
    fields = {
        "workspace": provider_field(Artifact),
    },
    doc = "Provider for the AssemblyScript compiler installation",
)

# ---------------------------------------------------------------------------
# install_asc — rule that npm-installs assemblyscript using hermetic Node.js
# ---------------------------------------------------------------------------

def _install_asc_impl(ctx: AnalysisContext) -> list[Provider]:
    node_info = ctx.attrs.node[NodeInfo]
    out_dir = ctx.actions.declare_output("asc_workspace", dir = True)

    cmd = cmd_args(
        node_info.npm,
        "install",
        "--prefix", out_dir.as_output(),
        "--no-package-lock",
        "assemblyscript@{}".format(ctx.attrs.version),
        "@assemblyscript/wasi-shim@{}".format(ctx.attrs.wasi_shim_version),
    )

    ctx.actions.run(
        cmd,
        category = "npm_install_asc",
        local_only = True,  # needs network access
    )

    return [
        DefaultInfo(default_output = out_dir),
        AscInfo(workspace = out_dir),
    ]

_install_asc = rule(
    impl = _install_asc_impl,
    attrs = {
        "node": attrs.exec_dep(
            providers = [NodeInfo],
            doc = "Node.js distribution providing hermetic node/npm",
        ),
        "version": attrs.string(
            default = "0.27.31",
            doc = "AssemblyScript version to install from npm",
        ),
        "wasi_shim_version": attrs.string(
            default = "0.1.0",
            doc = "@assemblyscript/wasi-shim version to install",
        ),
    },
    doc = "Install AssemblyScript compiler via npm using hermetic Node.js",
)

def install_asc(
        name: str,
        version: str = "0.27.31",
        wasi_shim_version: str = "0.1.0",
        node: str = "toolchains//:node_dist"):
    """Install AssemblyScript compiler via npm.

    Args:
        name: Target name.
        version: AssemblyScript version (default "0.27.31").
        wasi_shim_version: WASI shim version (default "0.1.0").
        node: Label of the node distribution.
    """
    _install_asc(
        name = name,
        version = version,
        wasi_shim_version = wasi_shim_version,
        node = node,
    )

# ---------------------------------------------------------------------------
# asc_toolchain
# ---------------------------------------------------------------------------

def _asc_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    asc_info = ctx.attrs.distribution[AscInfo]

    return [
        DefaultInfo(),
        AscInfo(workspace = asc_info.workspace),
    ]

asc_toolchain = rule(
    impl = _asc_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [AscInfo]),
    },
    is_toolchain_rule = True,
    doc = "AssemblyScript toolchain providing the asc compiler",
)

# ---------------------------------------------------------------------------
# assemblyscript_binary — compile .ts to .wasm
# ---------------------------------------------------------------------------

def _assemblyscript_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    node_info = ctx.attrs._node_toolchain[NodeInfo]
    asc_info = ctx.attrs._asc_toolchain[AscInfo]
    is_windows = ctx.attrs._exec_os_type[OsLookup].os == Os("windows")

    out = ctx.actions.declare_output(ctx.attrs.name + ".wasm")

    asc_js = cmd_args(
        asc_info.workspace,
        format = "{}/node_modules/assemblyscript/bin/asc",
    )
    node_modules = cmd_args(
        asc_info.workspace,
        format = "{}/node_modules",
    )

    # Use a Python build script to handle path separators correctly
    # on all platforms (shell scripts mangle backslashes on Windows).
    cmd = cmd_args(
        "python3", ctx.attrs._build_script,
        "--node", node_info.node,
        "--asc", asc_js,
        "--src", ctx.attrs.src,
        "--out", out.as_output(),
        "--node-modules", node_modules,
    )
    if ctx.attrs.wasi:
        cmd.add("--wasi")
    if is_windows:
        cmd.add("--copy-modules")
    for flag in ctx.attrs.asc_flags:
        cmd.add(flag)

    ctx.actions.run(cmd, category = "asc_compile")

    return [DefaultInfo(default_output = out)]

assemblyscript_binary = rule(
    impl = _assemblyscript_binary_impl,
    attrs = {
        "src": attrs.source(doc = "AssemblyScript source file (.ts)"),
        "asc_flags": attrs.list(
            attrs.string(),
            default = [],
            doc = "Additional flags passed to the asc compiler",
        ),
        "wasi": attrs.bool(
            default = True,
            doc = "Enable WASI support via @assemblyscript/wasi-shim",
        ),
        "_node_toolchain": attrs.toolchain_dep(
            default = "toolchains//:node",
            providers = [NodeInfo],
        ),
        "_asc_toolchain": attrs.toolchain_dep(
            default = "toolchains//:asc",
            providers = [AscInfo],
        ),
        "_build_script": attrs.source(
            default = "//tools:asc_build",
        ),
        "_exec_os_type": buck.exec_os_type_arg(),
    },
    doc = "Compile an AssemblyScript source file to a WebAssembly module",
)
