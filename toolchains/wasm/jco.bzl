"""jco toolchain for building WebAssembly components from JavaScript.

jco (JavaScript Component Toolchain) provides tools for building, transpiling,
and running WebAssembly components from JavaScript source files using the
Component Model.

Two toolchain flavors are provided:

- `system_jco_toolchain`: expects `jco` on the system PATH.
- `jco_toolchain`: uses a downloaded Node.js, then runs npm install as a local-only
  action. This pins the npm package version and can optionally use a lockfile to
  pin transitive dependencies, but still needs network access during the Buck
  action.

## Examples

### Downloaded Node + npm install

```bzl
load("//wasm:node.bzl", "download_node", "node_toolchain")
load("//wasm:jco.bzl", "install_jco", "jco_toolchain")

download_node(name = "node_dist", version = "26.3.1")
node_toolchain(name = "node", distribution = ":node_dist", visibility = ["PUBLIC"])
install_jco(name = "jco_dist", version = "1.24.3", node = ":node_dist")
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

load(
    "@prelude//os_lookup:defs.bzl",
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

JcoInfo = provider(
    # @unsorted-dict-items
    fields = {
        "jco": provider_field(RunInfo),
        "componentize": provider_field(RunInfo),
        "run": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for jco",
)

DEFAULT_JCO_VERSION = "1.24.3"

# ---------------------------------------------------------------------------
# System jco toolchain (non-hermetic, requires jco on PATH)
# ---------------------------------------------------------------------------

def _system_jco_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    lang = ctx.attrs._exec_os_type[OsLookup].script

    jco = cmd_script(
        actions = ctx.actions,
        name = "jco",
        cmd = cmd_args("jco"),
        language = lang,
    )

    componentize = cmd_script(
        actions = ctx.actions,
        name = "jco_componentize",
        cmd = cmd_args("jco", "componentize"),
        language = lang,
    )

    run = cmd_script(
        actions = ctx.actions,
        name = "jco_run",
        cmd = cmd_args("jco", "run"),
        language = lang,
    )

    return [
        DefaultInfo(),
        JcoInfo(
            jco = RunInfo(args = cmd_args(jco)),
            componentize = RunInfo(args = cmd_args(componentize)),
            run = RunInfo(args = cmd_args(run)),
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
        local_only = True,  # needs network access
    )

    return [DefaultInfo(default_output = out_dir)]

_install_jco = rule(
    impl = _install_jco_impl,
    attrs = {
        "node": attrs.exec_dep(
            providers = [NodeInfo],
            doc = "Downloaded Node.js distribution providing node/npm",
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
    """Install jco via npm using the downloaded Node.js distribution.

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
    )

# ---------------------------------------------------------------------------
# Hermetic jco toolchain
# ---------------------------------------------------------------------------

def _jco_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    node_info = ctx.attrs._node_toolchain[NodeInfo]
    jco_dist = ctx.attrs.distribution[DefaultInfo].default_outputs[0]
    lang = ctx.attrs._exec_os_type[OsLookup].script

    # Create wrapper scripts: node <jco_workspace>/node_modules/.bin/jco <subcommand> ...
    jco_path = cmd_args(
        jco_dist,
        format = "{}/node_modules/@bytecodealliance/jco/src/jco.js",
    )

    jco = cmd_script(
        actions = ctx.actions,
        name = "jco",
        cmd = cmd_args(node_info.node, jco_path),
        language = lang,
    )

    componentize = cmd_script(
        actions = ctx.actions,
        name = "jco_componentize",
        cmd = cmd_args(node_info.node, jco_path, "componentize"),
        language = lang,
    )

    run = cmd_script(
        actions = ctx.actions,
        name = "jco_run",
        cmd = cmd_args(node_info.node, jco_path, "run"),
        language = lang,
    )

    return [
        DefaultInfo(),
        JcoInfo(
            jco = RunInfo(args = cmd_args(jco)),
            componentize = RunInfo(args = cmd_args(componentize)),
            run = RunInfo(args = cmd_args(run)),
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
        "_exec_os_type": buck.exec_os_type_arg(),
    },
    is_toolchain_rule = True,
    doc = "Hermetic jco toolchain using downloaded Node.js + npm-installed jco",
)
