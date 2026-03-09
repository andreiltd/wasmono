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
    "wkg_releases",
)
load(
    ":host.bzl",
    "host_arch",
    "host_os",
)

_WKG_OS_MAP = {
    "linux": "unknown-linux-gnu",
    "macos": "apple-darwin",
    "windows": "pc-windows-gnu",
}

WkgReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
    doc = """WkgReleaseInfo: Metadata for a specific prebuilt `wkg` release asset.""",
)

def _get_wkg_release(
        version: str,
        platform: str,
        custom_releases: [None, dict] = None) -> WkgReleaseInfo:
    all_releases = wkg_releases
    if custom_releases != None:
        all_releases = dict(wkg_releases)
        all_releases.update(custom_releases)

    if not version in all_releases:
        fail("Unknown wkg release version '{}'. Available versions: {}".format(
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
    return WkgReleaseInfo(
        version = version,
        url = info["url"],
        sha256 = info["shasum"],
    )

WkgDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
    doc = """WkgDistributionInfo: Toolchain provider exposing the `wkg` binary distribution metadata.""",
)

def _wkg_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    # Create a copy of the wkg binary
    dst = ctx.actions.declare_output("wkg")

    ctx.actions.run(
        ["cp", ctx.attrs.dist[DefaultInfo].default_outputs[0], dst.as_output()],
        category = "cp_wkg",
    )

    wkg_args = cmd_args(
        [dst],
        hidden = [ctx.attrs.dist[DefaultInfo].default_outputs],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wkg_args),
        WkgDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
    ]

wkg_distribution = rule(
    impl = _wkg_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "version": attrs.string(),
    },
)

def download_wkg(
        name: str,
        version: str,
        releases: [None, dict] = None,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download and register a prebuilt `wkg` CLI release as a local distribution.

    Args:
        name: The name for the distribution target.
        version: The wkg version to download.
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "..."}}}``.
        arch: Target architecture (defaults to host architecture).
        os: Target OS (defaults to host OS).
    """
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os(_WKG_OS_MAP)

    release = _get_wkg_release(version, "{}-{}".format(arch, os), custom_releases = releases)

    # fetch the raw binary asset
    native.http_file(
        name = name + "_bin",
        urls = [release.url],
        sha256 = release.sha256,
        executable = True,
    )

    wkg_distribution(
        name = name,
        dist = ":" + name + "_bin",
        version = version,
        arch = arch,
        os = os,
    )

WkgInfo = provider(
    # @unsorted-dict-items
    fields = {
        "wkg": provider_field(RunInfo),
        "config": provider_field(RunInfo),
        "get": provider_field(RunInfo),
        "publish": provider_field(RunInfo),
        "oci": provider_field(RunInfo),
        "wit": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for wkg"
)

def _wkg_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WkgDistributionInfo]
    wkg = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, subcommand):
        return cmd_script(
            actions = ctx.actions,
            name = name,
            cmd = cmd_args(wkg, subcommand),
            language = ScriptLanguage("bat" if dist.os == "pc-windows-gnu" else "sh"),
        )

    wkg_config = create_subcommand("wkg_config", "config")
    wkg_get = create_subcommand("wkg_get", "get")
    wkg_publish = create_subcommand("wkg_publish", "publish")
    wkg_oci = create_subcommand("wkg_oci", "oci")
    wkg_wit = create_subcommand("wkg_wit", "wit")

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],
        WkgInfo(
            wkg = wkg,
            config = RunInfo(args = cmd_args(wkg_config)),
            get = RunInfo(args = cmd_args(wkg_get)),
            publish = RunInfo(args = cmd_args(wkg_publish)),
            oci = RunInfo(args = cmd_args(wkg_oci)),
            wit = RunInfo(args = cmd_args(wkg_wit)),
        ),
    ]

wkg_toolchain = rule(
    impl = _wkg_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WkgDistributionInfo]),
    },
    is_toolchain_rule = True,
)
