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
    version = "42.0.1",
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
        platform: str,
        custom_releases: [None, dict] = None) -> WasmtimeReleaseInfo:
    all_releases = wasmtime_releases
    if custom_releases != None:
        all_releases = dict(wasmtime_releases)
        all_releases.update(custom_releases)

    if not version in all_releases:
        fail("Unknown wasmtime release version '{}'. Available versions: {}".format(
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
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()

    archive_name = name + "-archive"
    release = _get_wasmtime_release(version, "{}-{}".format(arch, os), custom_releases = releases)

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
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
    dist = ctx.attrs.distribution[WasmtimeDistributionInfo]
    wasmtime = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, subcommand):
        return cmd_script(
            actions = ctx.actions,
            name = name,
            cmd = cmd_args(wasmtime, subcommand),
            language = ScriptLanguage("bat" if dist.os == "windows" else "sh"),
        )

    wasmtime_run = create_subcommand("wasmtime_run", "run")
    wasmtime_wizer = create_subcommand("wasmtime_wizer", "wizer")

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],
        WasmtimeInfo(
            wasmtime = wasmtime,
            run = RunInfo(args = cmd_args(wasmtime_run)),
            wizer = RunInfo(args = cmd_args(wasmtime_wizer)),
        ),
    ]

wasmtime_toolchain = rule(
    impl = _wasmtime_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WasmtimeDistributionInfo]),
    },
    is_toolchain_rule = True,
)
