"""Weval toolchain for WebAssembly partial evaluation.

Weval is a WebAssembly partial evaluator that specializes interpreter
snapshots into optimized, compiled code using the Futamura projection.

This toolchain provides a hermetic installation of the `weval` CLI.

## Examples

`toolchains//BUILD`
```bzl
load("//wasm:weval.bzl", "download_weval", "weval_toolchain")

download_weval(
    name = "weval_dist",
    version = "0.4.1",
)

weval_toolchain(
    name = "weval",
    distribution = ":weval_dist",
    visibility = ["PUBLIC"],
)
```
"""

load(
    "@prelude//:prelude.bzl",
    "native",
)
load(
    ":releases.bzl",
    "weval_releases",
)
load(
    ":host.bzl",
    "host_arch",
    "host_os",
)

WevalReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
)

def _get_weval_release(
        version: str,
        platform: str,
        custom_releases: [None, dict] = None) -> WevalReleaseInfo:
    all_releases = weval_releases
    if custom_releases != None:
        all_releases = dict(weval_releases)
        all_releases.update(custom_releases)

    if not version in all_releases:
        fail("Unknown weval release version '{}'. Available versions: {}".format(
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
    return WevalReleaseInfo(
        version = version,
        url = info["url"],
        sha256 = info["shasum"],
    )

WevalDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
)

def _weval_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    dst = ctx.actions.declare_output("weval")
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    src = cmd_args(dist_output, format = "{{}}/{}".format(ctx.attrs.prefix + "/weval" + ctx.attrs.suffix))

    ctx.actions.run(
        ["cp", src, dst.as_output()],
        category = "cp_weval",
    )

    weval = cmd_args(
        [dst],
        hidden = [
            ctx.attrs.dist[DefaultInfo].default_outputs,
            ctx.attrs.dist[DefaultInfo].other_outputs,
        ],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = weval),
        WevalDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
    ]

weval_distribution = rule(
    impl = _weval_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "prefix": attrs.string(),
        "suffix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def download_weval(
        name: str,
        version: str,
        releases: [None, dict] = None,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download a prebuilt weval CLI release and create a distribution target.

    Args:
        name: The name for the distribution target.
        version: The weval version to download.
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "..."}}}``.
        arch: Target architecture (defaults to host architecture).
        os: Target OS (defaults to host OS).
    """
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()

    archive_name = name + "-archive"
    release = _get_weval_release(version, "{}-{}".format(arch, os), custom_releases = releases)

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )

    prefix = "weval-v{}-{}-{}".format(version, arch, os)

    weval_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = prefix,
        suffix = ".exe" if os == "windows" else "",
        version = version,
        arch = arch,
        os = os,
    )

WevalInfo = provider(
    # @unsorted-dict-items
    fields = {
        "weval": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for weval CLI",
)

def _weval_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    weval = ctx.attrs.distribution[RunInfo]

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],
        WevalInfo(
            weval = weval,
        ),
    ]

weval_toolchain = rule(
    impl = _weval_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WevalDistributionInfo]),
    },
    is_toolchain_rule = True,
)
