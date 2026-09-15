"""Binaryen toolchain for WebAssembly optimization.

Binaryen provides wasm-opt and other tools for optimizing, transforming,
and analyzing WebAssembly modules.

This toolchain provides a hermetic installation of Binaryen and exposes
wasm-opt and other common tools as direct executable commands. Executables
remain in the archive's bin/lib layout so runtime libraries stay available.

## Examples

To automatically fetch a distribution suitable for the host-platform:

`toolchains//BUILD`
```bzl
load("//wasm:binaryen.bzl", "download_binaryen", "binaryen_toolchain")

download_binaryen(
    name = "binaryen_dist",
    version = "132",
)

binaryen_toolchain(
    name = "binaryen",
    distribution = ":binaryen_dist",
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
    "binaryen_releases",
)
load(
    ":host.bzl",
    "host_platform",
)
load(
    ":release_utils.bzl",
    "get_release",
)

BinaryenDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
        "bin_dir": provider_field(Artifact),
        "suffix": provider_field(str),
    },
)

def _binaryen_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    dist_info = ctx.attrs.dist[DefaultInfo]
    bin_dir = single_artifact(ctx.attrs.dist).default_output.project(ctx.attrs.prefix + "/bin")

    wasm_opt = cmd_args(
        bin_dir.project("wasm-opt" + ctx.attrs.suffix),
        hidden = [dist_info.default_outputs, dist_info.other_outputs],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wasm_opt),
        BinaryenDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
            bin_dir = bin_dir,
            suffix = ctx.attrs.suffix,
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
        releases: [None, dict] = None,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download and setup Binaryen distribution.

    Args:
        name: The name for the distribution target.
        version: The Binaryen version to download (e.g., "130").
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "..."}}}``.
        arch: Target architecture (defaults to host architecture).
        os: Target OS (defaults to host OS).
    """
    arch, os = host_platform(arch, os)

    # Binaryen uses "arm64" instead of "aarch64" on macOS
    release_arch = "arm64" if arch == "aarch64" and os == "macos" else arch

    archive_name = name + "-archive"
    release = get_release(
        binaryen_releases,
        version,
        "{}-{}".format(release_arch, os),
        custom_releases = releases,
        tool_name = "Binaryen",
    )

    native.http_archive(
        name = archive_name,
        urls = [release["url"]],
        sha256 = release["shasum"],
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
    dist_info = ctx.attrs.distribution[DefaultInfo]
    wasm_opt = ctx.attrs.distribution[RunInfo]

    def binary(binary_name):
        return RunInfo(args = cmd_args(
            dist.bin_dir.project(binary_name + dist.suffix),
            hidden = [dist_info.default_outputs, dist_info.other_outputs],
        ))

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],  # Direct access to wasm-opt binary
        BinaryenInfo(
            wasm_opt = wasm_opt,
            wasm_dis = binary("wasm-dis"),
            wasm_as = binary("wasm-as"),
            wasm2js = binary("wasm2js"),
            wasm_metadce = binary("wasm-metadce"),
        ),
    ]

binaryen_toolchain = rule(
    impl = _binaryen_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, BinaryenDistributionInfo]),
    },
    is_toolchain_rule = True,
)
