"""Wasmtime CLI toolchain for running and testing WebAssembly components.

Provides a hermetic installation of the `wasmtime` CLI and exposes
the `run` subcommand for use by `wasm_run` / `wasm_test` rules.

## Examples

`toolchains//BUILD`
```bzl
load("//wasm:wasmtime.bzl", "download_wasmtime", "wasmtime_toolchain")

download_wasmtime(
    name = "wasmtime_dist",
    version = "41.0.3",
)

wasmtime_toolchain(
    name = "wasmtime",
    distribution = ":wasmtime_dist",
    visibility = ["PUBLIC"],
)
```
"""

load(
    "@prelude//os_lookup:defs.bzl",
    "ScriptLanguage",
)
load(
    "@prelude//utils:cmd_script.bzl",
    "cmd_script",
)
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
    "host_arch",
    "host_os",
)

WasmtimeReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
)

def _get_wasmtime_release(
        version: str,
        platform: str) -> WasmtimeReleaseInfo:
    if not version in wasmtime_releases:
        fail("Unknown wasmtime release version '{}'. Available versions: {}".format(
            version,
            ", ".join(wasmtime_releases.keys()),
        ))
    ver = wasmtime_releases[version]
    if not platform in ver:
        fail("Unsupported platform '{}'. Supported platforms: {}".format(
            platform,
            ", ".join(ver.keys()),
        ))
    info = ver[platform]
    return WasmtimeReleaseInfo(
        version = version,
        url = info["url"],
        sha256 = info["shasum"],
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
    dst = ctx.actions.declare_output("wasmtime")
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    src = cmd_args(dist_output, format = "{{}}/{}".format(ctx.attrs.prefix + "/wasmtime" + ctx.attrs.suffix))

    ctx.actions.run(
        ["cp", src, dst.as_output()],
        category = "cp_wasmtime",
    )

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
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download a prebuilt wasmtime CLI release and create a distribution target."""
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()

    archive_name = name + "-archive"
    release = _get_wasmtime_release(version, "{}-{}".format(arch, os))

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )

    wasmtime_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = "wasmtime-v{}-{}-{}".format(version, arch, os),
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
    },
    doc = "Toolchain info provider for wasmtime CLI",
)

def _wasmtime_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WasmtimeDistributionInfo]
    wasmtime = ctx.attrs.distribution[RunInfo]

    wasmtime_run = cmd_script(
        actions = ctx.actions,
        name = "wasmtime_run",
        cmd = cmd_args(wasmtime, "run"),
        language = ScriptLanguage("bat" if dist.os == "windows" else "sh"),
    )

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],
        WasmtimeInfo(
            wasmtime = wasmtime,
            run = RunInfo(args = cmd_args(wasmtime_run)),
        ),
    ]

wasmtime_toolchain = rule(
    impl = _wasmtime_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WasmtimeDistributionInfo]),
    },
    is_toolchain_rule = True,
)
