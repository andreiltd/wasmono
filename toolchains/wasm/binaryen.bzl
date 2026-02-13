"""Binaryen toolchain for WebAssembly optimization.

Binaryen provides wasm-opt and other tools for optimizing, transforming,
and analyzing WebAssembly modules.

This toolchain provides a hermetic installation of Binaryen and exposes
wasm-opt and other common tools as convenient wrappers.

## Examples

To automatically fetch a distribution suitable for the host-platform:

`toolchains//BUILD`
```bzl
load("//wasm:binaryen.bzl", "download_binaryen", "binaryen_toolchain")

download_binaryen(
    name = "binaryen_dist",
    version = "125",
)

binaryen_toolchain(
    name = "binaryen",
    distribution = ":binaryen_dist",
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
    "binaryen_releases",
)
load(
    ":host.bzl",
    "host_arch",
    "host_os",
)

BinaryenReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
)

def _get_binaryen_release(version: str, platform: str) -> BinaryenReleaseInfo:
    if not version in binaryen_releases:
        fail("Unknown Binaryen release version '{}'. Available versions: {}".format(
            version,
            ", ".join(binaryen_releases.keys()),
        ))
    release = binaryen_releases[version]
    if not platform in release:
        fail("Unsupported platform '{}'. Supported platforms: {}".format(
            platform,
            ", ".join(release.keys()),
        ))
    plat = release[platform]
    return BinaryenReleaseInfo(
        version = version,
        url = plat["url"],
        sha256 = plat["shasum"],
    )

BinaryenDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
)

def _binaryen_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    dst = ctx.actions.declare_output("wasm-opt")
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    src = cmd_args(dist_output, format = "{{}}/{}".format(ctx.attrs.prefix + "/bin/wasm-opt" + ctx.attrs.suffix))

    ctx.actions.run(
        ["cp", src, dst.as_output()],
        category = "cp_wasm_opt",
    )

    wasm_opt = cmd_args(
        [dst],
        hidden = [
            ctx.attrs.dist[DefaultInfo].default_outputs,
            ctx.attrs.dist[DefaultInfo].other_outputs,
        ],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wasm_opt),
        BinaryenDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
    ]

binaryen_distribution = rule(
    impl = _binaryen_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "prefix": attrs.string(),
        "suffix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def download_binaryen(
        name: str,
        version: str,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download and setup Binaryen distribution.

    Args:
        name: The name for the distribution target
        version: The Binaryen version to download (e.g., "125")
        arch: Target architecture (defaults to host architecture)
        os: Target OS (defaults to host OS)
    """
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os(os_map = {
            "linux": "linux",
            "macos": "macos",
            "windows": "windows",
        })

    # Binaryen uses "arm64" instead of "aarch64" on macOS
    release_arch = "arm64" if arch == "aarch64" and os == "macos" else arch

    archive_name = name + "-archive"
    release = _get_binaryen_release(version, "{}-{}".format(release_arch, os))

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )

    binaryen_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = "binaryen-version_{}".format(version),
        suffix = ".exe" if os == "windows" else "",
        version = version,
        arch = arch,
        os = os,
    )

BinaryenInfo = provider(
    # @unsorted-dict-items
    fields = {
        "wasm_opt": provider_field(RunInfo),
        "wasm_dis": provider_field(RunInfo),
        "wasm_as": provider_field(RunInfo),
        "wasm2js": provider_field(RunInfo),
        "wasm_metadce": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for Binaryen",
)

def _binaryen_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[BinaryenDistributionInfo]
    wasm_opt = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, binary_name):
        """Create a wrapper that runs a sibling binary next to wasm-opt."""
        sibling = cmd_args(wasm_opt, format = "{{}}/../{}".format(binary_name))
        return cmd_script(
            ctx = ctx,
            name = name,
            cmd = sibling,
            language = ScriptLanguage("bat" if dist.os == "windows" else "sh"),
        )

    wasm_dis = create_subcommand("wasm_dis", "wasm-dis")
    wasm_as = create_subcommand("wasm_as", "wasm-as")
    wasm2js = create_subcommand("wasm2js", "wasm2js")
    wasm_metadce = create_subcommand("wasm_metadce", "wasm-metadce")

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],  # Direct access to wasm-opt binary
        BinaryenInfo(
            wasm_opt = wasm_opt,
            wasm_dis = RunInfo(args = cmd_args(wasm_dis)),
            wasm_as = RunInfo(args = cmd_args(wasm_as)),
            wasm2js = RunInfo(args = cmd_args(wasm2js)),
            wasm_metadce = RunInfo(args = cmd_args(wasm_metadce)),
        ),
    ]

binaryen_toolchain = rule(
    impl = _binaryen_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, BinaryenDistributionInfo]),
    },
    is_toolchain_rule = True,
)
