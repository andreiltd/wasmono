"""Hermetic Node.js toolchain for Buck2.

Downloads a prebuilt Node.js distribution and exposes `node` and `npm`
binaries for use by rules that need a JavaScript runtime (e.g. jco, asc).

## Examples

`toolchains//BUCK`
```bzl
load("//wasm:node.bzl", "download_node", "node_toolchain")

download_node(
    name = "node_dist",
    version = "26.3.1",
)

node_toolchain(
    name = "node",
    distribution = ":node_dist",
    visibility = ["PUBLIC"],
)
```
"""

load(
    "@prelude//:prelude.bzl",
    "native",
)
load(
    ":node_releases.bzl",
    "node_releases",
)
load(
    ":host.bzl",
    "host_platform",
)
load(
    ":release_utils.bzl",
    "get_release",
)

# ---------------------------------------------------------------------------
# Node.js distribution rule
# ---------------------------------------------------------------------------

NodeDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
)

NodeInfo = provider(
    # @unsorted-dict-items
    fields = {
        "node": provider_field(RunInfo),
        "npm": provider_field(RunInfo),
    },
    doc = "Provider exposing hermetic node and npm binaries",
)

def _node_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    prefix = ctx.attrs.prefix

    is_windows = ctx.attrs.os == "windows"

    # Copy the node binary out of the archive (single file, like wasmtime pattern)
    suffix = ".exe" if is_windows else ""
    node_dst = ctx.actions.declare_output("node" + suffix)

    if is_windows:
        # Windows: node.exe lives at <prefix>/node.exe
        node_src = dist_output.project(prefix + "/node.exe")
    else:
        # Unix: node lives at <prefix>/bin/node
        node_src = dist_output.project(prefix + "/bin/node")

    ctx.actions.copy_file(node_dst.as_output(), node_src)

    # npm is a Node.js script that needs its entire module tree, so reference
    # npm-cli.js in-place within the archive rather than copying it out.
    if is_windows:
        # Windows: npm at <prefix>/node_modules/npm/bin/npm-cli.js
        npm_cli_js = cmd_args(
            dist_output,
            format = "{{}}/{}".format(prefix + "/node_modules/npm/bin/npm-cli.js"),
        )
    else:
        # Unix: npm at <prefix>/lib/node_modules/npm/bin/npm-cli.js
        npm_cli_js = cmd_args(
            dist_output,
            format = "{{}}/{}".format(prefix + "/lib/node_modules/npm/bin/npm-cli.js"),
        )

    dist_deps = [
        ctx.attrs.dist[DefaultInfo].default_outputs,
        ctx.attrs.dist[DefaultInfo].other_outputs,
    ]

    node_cmd = cmd_args(node_dst, hidden = dist_deps)

    # npm RunInfo is "node npm-cli.js", so appending args gives "node npm-cli.js <args>"
    npm_cmd = cmd_args(node_dst, npm_cli_js, hidden = dist_deps)

    return [
        DefaultInfo(default_output = node_dst),
        NodeDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
        NodeInfo(
            node = RunInfo(args = node_cmd),
            npm = RunInfo(args = npm_cmd),
        ),
    ]

node_distribution = rule(
    impl = _node_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "prefix": attrs.string(),
        "version": attrs.string(),
    },
)

# ---------------------------------------------------------------------------
# download_node macro
# ---------------------------------------------------------------------------

def download_node(
        name: str,
        version: str,
        releases: [None, dict] = None,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download a prebuilt Node.js distribution and create a distribution target.

    Args:
        name: Target name for the node distribution.
        version: Node.js version to download (e.g. "26.3.1").
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "...", "prefix": "..."}}}``.
        arch: Override host architecture detection.
        os: Override host OS detection.
    """
    arch, os = host_platform(arch, os)

    archive_name = name + "-archive"
    release = get_release(
        node_releases,
        version,
        "{}-{}".format(arch, os),
        custom_releases = releases,
        tool_name = "Node.js",
    )

    native.http_archive(
        name = archive_name,
        urls = [release["url"]],
        sha256 = release["shasum"],
    )

    node_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = release["prefix"],
        version = version,
        arch = arch,
        os = os,
    )

# ---------------------------------------------------------------------------
# node_toolchain rule
# ---------------------------------------------------------------------------

def _node_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    node_info = ctx.attrs.distribution[NodeInfo]

    return [
        DefaultInfo(),
        NodeInfo(
            node = node_info.node,
            npm = node_info.npm,
        ),
    ]

node_toolchain = rule(
    impl = _node_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [NodeInfo]),
    },
    is_toolchain_rule = True,
    doc = "Node.js toolchain providing hermetic node and npm binaries",
)
