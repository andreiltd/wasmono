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
    version = "130",
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
    },
)

def _binaryen_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]

    # On macOS, wasm-opt is dynamically linked against libbinaryen.dylib via
    # @rpath/../lib/. Preserve the bin/lib directory structure so the rpath
    # resolves correctly.
    if ctx.attrs.os == "macos":
        dst = ctx.actions.declare_output("bin/wasm-opt" + ctx.attrs.suffix)
        dylib_src = dist_output.project(ctx.attrs.prefix + "/lib/libbinaryen.dylib")
        dylib_dst = ctx.actions.declare_output("lib/libbinaryen.dylib")
        ctx.actions.copy_file(dylib_dst.as_output(), dylib_src)
        extra_hidden = [dylib_dst]
    else:
        dst = ctx.actions.declare_output("wasm-opt" + ctx.attrs.suffix)
        extra_hidden = []

    src = dist_output.project(ctx.attrs.prefix + "/bin/wasm-opt" + ctx.attrs.suffix)
    ctx.actions.copy_file(dst.as_output(), src)

    wasm_opt = cmd_args(
        [dst],
        hidden = [
            ctx.attrs.dist[DefaultInfo].default_outputs,
            ctx.attrs.dist[DefaultInfo].other_outputs,
        ] + extra_hidden,
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
    wasm_opt = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, binary_name):
        """Create a wrapper that runs a sibling binary next to wasm-opt."""
        sibling = cmd_args(wasm_opt, format = "{{}}/../{}".format(binary_name))
        return cmd_script(
            actions = ctx.actions,
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
