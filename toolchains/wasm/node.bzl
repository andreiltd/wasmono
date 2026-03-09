"""Hermetic Node.js toolchain for Buck2.

Downloads a prebuilt Node.js distribution and exposes `node` and `npm`
binaries for use by rules that need a JavaScript runtime (e.g. jco, asc).

## Examples

`toolchains//BUCK`
```bzl
load("//wasm:node.bzl", "download_node", "node_toolchain")

download_node(
    name = "node_dist",
    version = "20.18.0",
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
    "host_arch",
    "host_os",
)

NodeReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
        "prefix": provider_field(str),
    },
)

def _get_node_release(
        version: str,
        platform: str,
        custom_releases: [None, dict] = None) -> NodeReleaseInfo:
    all_releases = node_releases
    if custom_releases != None:
        all_releases = dict(node_releases)
        all_releases.update(custom_releases)

    if not version in all_releases:
        fail("Unknown Node.js release version '{}'. Available versions: {}".format(
            version,
            ", ".join(all_releases.keys()),
        ))
    ver = all_releases[version]
    if not platform in ver:
        fail("Unsupported platform '{}'. Supported platforms: {}".format(
            platform,
            ", ".join(ver.keys()),
        ))
    info = ver[platform]
    return NodeReleaseInfo(
        version = version,
        url = info["url"],
        sha256 = info["shasum"],
        prefix = info["prefix"],
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

    # Copy the node binary out of the archive (single file, like wasmtime pattern)
    node_dst = ctx.actions.declare_output("node")
    node_src = cmd_args(dist_output, format = "{{}}/{}".format(prefix + "/bin/node"))
    ctx.actions.run(
        ["cp", node_src, node_dst.as_output()],
        category = "cp_node",
    )

    # npm is a Node.js script that needs its entire module tree, so reference
    # npm-cli.js in-place within the archive rather than copying it out.
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
        version: Node.js version to download (e.g. "20.18.0").
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "...", "prefix": "..."}}}``.
        arch: Override host architecture detection.
        os: Override host OS detection.
    """
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()

    archive_name = name + "-archive"
    release = _get_node_release(version, "{}-{}".format(arch, os), custom_releases = releases)

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )

    node_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = release.prefix,
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
