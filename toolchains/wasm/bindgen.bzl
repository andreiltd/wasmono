"""WIT-Bindgen toolchain for WebAssembly Interface Types binding generation.

WIT-Bindgen is a language binding generator for WIT (WebAssembly Interface Types)
and the Component Model. It can generate bindings for various target languages
from WIT interface definitions.

This toolchain provides a hermetic installation of wit-bindgen and exposes
common subcommands as convenient wrappers.

## Examples

To automatically fetch a distribution suitable for the host-platform:

`toolchains//BUILD`
```bzl
load("//wit:bindgen.bzl", "download_wit_bindgen", "wit_bindgen_toolchain")

download_wit_bindgen(
    name = "wit_bindgen_dist",
    version = "0.30.0",
)

wit_bindgen_toolchain(
    name = "wit-bindgen",
    distribution = ":wit_bindgen_dist",
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
    "wit_bindgen_releases",
)
load(
    ":host.bzl",
    "host_arch",
    "host_os",
)

WitBindgenReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
)

def _get_wit_bindgen_release(version: str, platform: str) -> WitBindgenReleaseInfo:
    if not version in wit_bindgen_releases:
        fail("Unknown wit-bindgen release version '{}'. Available versions: {}".format(
            version,
            ", ".join(wit_bindgen_releases.keys()),
        ))
    release = wit_bindgen_releases[version]
    if not platform in release:
        fail("Unsupported platform '{}'. Supported platforms: {}".format(
            platform,
            ", ".join(release.keys()),
        ))
    plat = release[platform]
    return WitBindgenReleaseInfo(
        version = version,
        url = plat["url"],
        sha256 = plat["shasum"],
    )

WitBindgenDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
)

def _wit_bindgen_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    # Create a copy of the wit-bindgen binary for easy access
    dst = ctx.actions.declare_output("wit-bindgen")
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    src = cmd_args(dist_output, format = "{{}}/{}".format(ctx.attrs.prefix + "/wit-bindgen" + ctx.attrs.suffix))

    ctx.actions.run(
        ["cp", src, dst.as_output()],
        category = "cp_wit_bindgen",
    )

    wit_bindgen = cmd_args(
        [dst],
        hidden = [
            ctx.attrs.dist[DefaultInfo].default_outputs,
            ctx.attrs.dist[DefaultInfo].other_outputs,
        ],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wit_bindgen),
        WitBindgenDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
    ]

wit_bindgen_distribution = rule(
    impl = _wit_bindgen_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "prefix": attrs.string(),
        "suffix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def download_wit_bindgen(
        name: str,
        version: str,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download and setup wit-bindgen distribution.

    Args:
        name: The name for the distribution target
        version: The wit-bindgen version to download
        arch: Target architecture (defaults to host architecture)
        os: Target OS (defaults to host OS)
    """
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()

    archive_name = name + "-archive"
    release = _get_wit_bindgen_release(version, "{}-{}".format(arch, os))

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )

    wit_bindgen_distribution(
        name = name,
        dist = ":" + archive_name,
        prefix = "wit-bindgen-{}-{}-{}".format(version, arch, os),
        suffix = ".exe" if os == "windows" else "",
        version = version,
        arch = arch,
        os = os,
    )

WitBindgenInfo = provider(
    # @unsorted-dict-items
    fields = {
        "wit_bindgen": provider_field(RunInfo),
        "rust": provider_field(RunInfo),
        "cxx": provider_field(RunInfo),
        "c": provider_field(RunInfo),
        "print": provider_field(RunInfo),
        "markdown": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for wit-bindgen"
)

def _wit_bindgen_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WitBindgenDistributionInfo]
    wit_bindgen = ctx.attrs.distribution[RunInfo]

    # Create wrapper scripts for common wit-bindgen subcommands
    def create_subcommand(name, subcommand):
        return cmd_script(
            actions = ctx.actions,
            name = name,
            cmd = cmd_args(wit_bindgen, subcommand),
            language = ScriptLanguage("bat" if dist.os == "windows" else "sh"),
        )

    wit_bindgen_rust = create_subcommand("wit_bindgen_rust", "rust")
    wit_bindgen_cxx = create_subcommand("wit_bindgen_cxx", "cpp")
    wit_bindgen_c = create_subcommand("wit_bindgen_c", "c")
    wit_bindgen_print = create_subcommand("wit_bindgen_print", "print")
    wit_bindgen_markdown = create_subcommand("wit_bindgen_markdown", "markdown")

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],  # Direct access to wit-bindgen binary
        WitBindgenInfo(
            wit_bindgen = wit_bindgen,
            rust = RunInfo(args = cmd_args(wit_bindgen_rust)),
            cxx = RunInfo(args = cmd_args(wit_bindgen_cxx)),
            c = RunInfo(args = cmd_args(wit_bindgen_c)),
            print = RunInfo(args = cmd_args(wit_bindgen_print)),
            markdown = RunInfo(args = cmd_args(wit_bindgen_markdown)),
        ),
    ]

wit_bindgen_toolchain = rule(
    impl = _wit_bindgen_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WitBindgenDistributionInfo]),
    },
    is_toolchain_rule = True,
)
