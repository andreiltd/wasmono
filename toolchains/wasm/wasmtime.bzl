"""Wasmtime CLI toolchain for running and testing WebAssembly components.

Provides a hermetic installation of the `wasmtime` CLI and exposes
the `run` and `wizer` subcommands for use by `wasm_run` / `wasm_test`
and `wasm_wizer` rules.

## Examples

`toolchains//BUILD`
```bzl
load("//wasm:wasmtime.bzl", "download_wasmtime", "wasmtime_toolchain")

download_wasmtime(
    name = "wasmtime_dist",
    version = "48.0.2",
)

wasmtime_toolchain(
    name = "wasmtime",
    distribution = ":wasmtime_dist",
    visibility = ["PUBLIC"],
)
```
"""

load("@prelude//:artifacts.bzl", "single_artifact")
load(
    "@prelude//:prelude.bzl",
    "native",
)
load(
    ":releases.bzl",
    "wasmtime_releases",
)
load(
    ":host.bzl",
    "host_platform",
)
load(
    ":release_utils.bzl",
    "get_release",
)

WasmtimeDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
)

def _wasmtime_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    dst = ctx.actions.declare_output("wasmtime" + ctx.attrs.suffix)
    dist_output = single_artifact(ctx.attrs.dist).default_output
    src = dist_output.project(ctx.attrs.prefix + "/wasmtime" + ctx.attrs.suffix)

    ctx.actions.copy_file(dst.as_output(), src)

    wasmtime = cmd_args(
        [dst],
        hidden = [
            ctx.attrs.dist[DefaultInfo].default_outputs,
            ctx.attrs.dist[DefaultInfo].other_outputs,
        ],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wasmtime),
        WasmtimeDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
    ]

wasmtime_distribution = rule(
    impl = _wasmtime_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "prefix": attrs.string(),
        "suffix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def download_wasmtime(
        name: str,
        version: str,
        releases: [None, dict] = None,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download a prebuilt wasmtime CLI release and create a distribution target.

    Args:
        name: The name for the distribution target.
        version: The wasmtime version to download.
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "..."}}}``.
            This can be used to supply dev/nightly builds or versions not yet
            in the built-in release list.
        arch: Target architecture (defaults to host architecture).
        os: Target OS (defaults to host OS).
    """
    arch, os = host_platform(arch, os)

    archive_name = name + "-archive"
    release = get_release(
        wasmtime_releases,
        version,
        "{}-{}".format(arch, os),
        custom_releases = releases,
        tool_name = "wasmtime",
    )

    native.http_archive(
        name = archive_name,
        urls = [release["url"]],
        sha256 = release["shasum"],
    )

    if version == "dev":
        prefix = "wasmtime-dev-{}-{}".format(arch, os)
    else:
        prefix = "wasmtime-v{}-{}-{}".format(version, arch, os)

    wasmtime_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = prefix,
        suffix = ".exe" if os == "windows" else "",
        version = version,
        arch = arch,
        os = os,
    )

WasmtimeInfo = provider(
    # @unsorted-dict-items
    fields = {
        "wasmtime": provider_field(RunInfo),
        "run": provider_field(RunInfo),
        "wizer": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for wasmtime CLI",
)

def _wasmtime_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    wasmtime = ctx.attrs.distribution[RunInfo]

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],
        WasmtimeInfo(
            wasmtime = wasmtime,
            run = RunInfo(args = cmd_args(wasmtime, "run")),
            wizer = RunInfo(args = cmd_args(wasmtime, "wizer")),
        ),
    ]

wasmtime_toolchain = rule(
    impl = _wasmtime_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WasmtimeDistributionInfo]),
    },
    is_toolchain_rule = True,
)
