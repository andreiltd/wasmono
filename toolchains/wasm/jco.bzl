"""jco toolchain for building WebAssembly components from JavaScript.

jco (JavaScript Component Toolchain) provides tools for building, transpiling,
and running WebAssembly components from JavaScript source files using the
Component Model.

Two toolchain flavors are provided:

- `system_jco_toolchain`: expects `jco` on the system PATH.
- `jco_toolchain`: uses downloaded Node.js and installs npm packages on the
  selected execution platform. That platform needs npm registry access.
  Installation and execution OS/CPU constraints match the Node distribution,
  so runtime-native dependencies are not installed on the Buck client for a
  different platform. The default pins the npm package version; an optional
  lockfile enables `npm ci` to pin transitive dependencies as well.

The downloaded CLI is resolved from the installed package's `bin` metadata,
supporting both older `src/` and newer `dist/` layouts without version checks.

## Examples

### Downloaded Node + npm install

```bzl
load("//wasm:node.bzl", "download_node", "node_toolchain")
load("//wasm:jco.bzl", "install_jco", "jco_toolchain")

download_node(name = "node_dist", version = "26.8.2")
node_toolchain(name = "node", distribution = ":node_dist", visibility = ["PUBLIC"])
install_jco(name = "jco_dist", version = "1.33.0", node = ":node_dist")
jco_toolchain(name = "jco", distribution = ":jco_dist", visibility = ["PUBLIC"])
```

### Downloaded Node + npm ci

```bzl
install_jco(
    name = "jco_dist",
    node = ":node_dist",
    package_json = "jco/package.json",
    package_lock = "jco/package-lock.json",
)
```

### System

```bzl
load("//wasm:jco.bzl", "system_jco_toolchain")
system_jco_toolchain(name = "jco", visibility = ["PUBLIC"])
```
"""

load("@prelude//:artifacts.bzl", "single_artifact")
load(
    "@prelude//os_lookup:defs.bzl",
    "Os",
    "OsLookup",
)
load(
    "@prelude//utils:cmd_script.bzl",
    "cmd_script",
)
load(
    "@prelude//decls:common.bzl",
    buck = "buck",
)
load(
    ":node.bzl",
    "NodeInfo",
)
load(":host.bzl", "native_execution_compatible_with")

JcoInfo = provider(
    # @unsorted-dict-items
    fields = {
        "jco": provider_field(RunInfo),
        "componentize": provider_field(RunInfo),
        "run": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for jco",
)

DEFAULT_JCO_VERSION = "1.33.0"

# ---------------------------------------------------------------------------
# System jco toolchain (non-hermetic, requires jco on PATH)
# ---------------------------------------------------------------------------

def _system_jco_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    exec_os = ctx.attrs._exec_os_type[OsLookup]
    jco_cmd = cmd_args("jco")
    if exec_os.os == Os("windows"):
        # npm's system jco entrypoint is a .cmd file and needs shell dispatch.
        jco_cmd = cmd_script(
            actions = ctx.actions,
            name = "jco",
            cmd = jco_cmd,
            language = exec_os.script,
        )
    jco = RunInfo(args = jco_cmd)

    return [
        DefaultInfo(),
        JcoInfo(
            jco = jco,
            componentize = RunInfo(args = cmd_args(jco, "componentize")),
            run = RunInfo(args = cmd_args(jco, "run")),
        ),
    ]

system_jco_toolchain = rule(
    impl = _system_jco_toolchain_impl,
    attrs = {
        "_exec_os_type": buck.exec_os_type_arg(),
    },
    is_toolchain_rule = True,
    doc = "System jco toolchain (requires jco on PATH via npm install -g @bytecodealliance/jco)",
)

# ---------------------------------------------------------------------------
# install_jco — rule that npm-installs jco using downloaded Node.js
# ---------------------------------------------------------------------------

def _install_jco_impl(ctx: AnalysisContext) -> list[Provider]:
    node_info = ctx.attrs.node[NodeInfo]
    out_dir = ctx.actions.declare_output("jco_workspace", dir = True)

    if (ctx.attrs.package_json == None) != (ctx.attrs.package_lock == None):
        fail("install_jco: package_json and package_lock must be provided together")

    if ctx.attrs.package_json and ctx.attrs.package_lock:
        if ctx.attrs._npm_ci_workspace == None:
            fail("install_jco: _npm_ci_workspace is required when package_json and package_lock are provided")
        cmd = cmd_args(
            node_info.node,
            ctx.attrs._npm_ci_workspace,
            out_dir.as_output(),
            ctx.attrs.package_json,
            ctx.attrs.package_lock,
            node_info.npm,
        )
        category = "npm_ci_jco"
    else:
        cmd = cmd_args(
            node_info.npm,
            "install",
            "--prefix", out_dir.as_output(),
            "--no-package-lock",
            "@bytecodealliance/jco@{}".format(ctx.attrs.version),
        )
        category = "npm_install_jco"

    ctx.actions.run(
        cmd,
        category = category,
    )

    return [DefaultInfo(default_output = out_dir)]

_install_jco = rule(
    impl = _install_jco_impl,
    attrs = {
        "node": attrs.dep(
            providers = [NodeInfo],
            doc = "Downloaded Node.js matching the installation platform",
        ),
        "version": attrs.string(
            default = DEFAULT_JCO_VERSION,
            doc = "jco version to install from npm",
        ),
        "package_json": attrs.option(
            attrs.source(),
            default = None,
            doc = "Optional package.json to use with npm ci",
        ),
        "package_lock": attrs.option(
            attrs.source(),
            default = None,
            doc = "Optional package-lock.json to use with npm ci",
        ),
        "_npm_ci_workspace": attrs.option(attrs.source(), default = None),
    },
    doc = "Install jco via npm using downloaded Node.js",
)

def install_jco(
        name: str,
        version: str = DEFAULT_JCO_VERSION,
        node: str = "toolchains//:node_dist",
        package_json: [None, str] = None,
        package_lock: [None, str] = None,
        npm_ci_workspace: [None, str] = None):
    """Install jco via npm on its consuming execution platform.

    Registry access is required there. Node's distribution constraints determine
    compatible platforms, including for jco's runtime-native npm dependencies.

    Args:
        name: Target name for the jco installation.
        version: jco version to install.
        node: Label of the node distribution (output of download_node).
        package_json: Optional package.json to use with npm ci.
        package_lock: Optional package-lock.json to use with npm ci.
        npm_ci_workspace: Optional npm-ci helper; defaults to wasmono's helper
            when package_json and package_lock are provided.
    """
    if package_json != None and package_lock != None and npm_ci_workspace == None:
        npm_ci_workspace = "wasmono//tools:npm_ci_workspace"

    _install_jco(
        name = name,
        version = version,
        node = node,
        package_json = package_json,
        package_lock = package_lock,
        _npm_ci_workspace = npm_ci_workspace,
        exec_compatible_with = native_execution_compatible_with(),
    )

# ---------------------------------------------------------------------------
# Hermetic jco toolchain
# ---------------------------------------------------------------------------

def _jco_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    node_info = ctx.attrs._node_toolchain[NodeInfo]
    dist_info = ctx.attrs.distribution[DefaultInfo]
    jco_dist = single_artifact(ctx.attrs.distribution).default_output

    jco_package = cmd_args(
        jco_dist,
        format = "{}/node_modules/@bytecodealliance/jco",
    )

    jco = RunInfo(args = cmd_args(
        node_info.node,
        ctx.attrs._npm_bin,
        jco_package,
        "jco",
        hidden = dist_info.other_outputs,
    ))

    return [
        DefaultInfo(),
        JcoInfo(
            jco = jco,
            componentize = RunInfo(args = cmd_args(jco, "componentize")),
            run = RunInfo(args = cmd_args(jco, "run")),
        ),
    ]

jco_toolchain = rule(
    impl = _jco_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(
            doc = "jco installation (output of install_jco)",
        ),
        "_node_toolchain": attrs.toolchain_dep(
            default = "toolchains//:node",
            providers = [NodeInfo],
        ),
        "_npm_bin": attrs.source(default = "wasmono//tools:npm_bin"),
    },
    is_toolchain_rule = True,
    doc = "Hermetic jco toolchain using downloaded Node.js + npm-installed jco",
)
