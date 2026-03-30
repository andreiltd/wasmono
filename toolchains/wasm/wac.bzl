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
    "wac_releases",
)
load(
    ":host.bzl",
    "host_arch",
    "host_os",
)

_WAC_OS_MAP = {
    "linux": "unknown-linux-musl",
    "macos": "apple-darwin",
    "windows": "pc-windows-gnu",
}

WacReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
    doc = """WacReleaseInfo: Metadata for a specific prebuilt `wac` release asset.""",
)

def _get_wac_release(
        version: str,
        platform: str,
        custom_releases: [None, dict] = None) -> WacReleaseInfo:
    all_releases = wac_releases
    if custom_releases != None:
        all_releases = dict(wac_releases)
        all_releases.update(custom_releases)

    if not version in all_releases:
        fail("Unknown wac release version '{}'. Available versions: {}".format(
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
    return WacReleaseInfo(
        version = version,
        url = info["url"],
        sha256 = info["shasum"],
    )

WacDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
    },
    doc = """WacInfo: Toolchain provider exposing the `wac` binary and convenient RunInfo wrappers for common subcommands.""",
)

def _wac_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    # Create a copy of the wac binary
    dst = ctx.actions.declare_output("wac" + ctx.attrs.suffix)

    ctx.actions.copy_file(dst.as_output(), ctx.attrs.dist[DefaultInfo].default_outputs[0])

    wac_args = cmd_args(
        [dst],
        hidden = [ctx.attrs.dist[DefaultInfo].default_outputs],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wac_args),
        WacDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
        ),
    ]

wac_distribution = rule(
    impl = _wac_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "suffix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def download_wac(
        name: str,
        version: str,
        releases: [None, dict] = None,
        arch: [None, str] = None,
        os: [None, str] = None):
    """Download and register a prebuilt `wac` CLI release as a local distribution.

    Args:
        name: The name for the distribution target.
        version: The wac version to download.
        releases: Optional dict of custom releases to overlay on built-in
            releases. Format: ``{"version": {"platform": {"url": "...", "shasum": "..."}}}``.
        arch: Target architecture (defaults to host architecture).
        os: Target OS (defaults to host OS).
    """
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os(_WAC_OS_MAP)

    release = _get_wac_release(version, "{}-{}".format(arch, os), custom_releases = releases)

    # fetch the raw binary asset
    native.http_file(
        name = name + "_bin",
        urls = [release.url],
        sha256 = release.sha256,
        executable = True,
    )

    wac_distribution(
        name = name,
        dist = ":" + name + "_bin",
        suffix = ".exe" if "windows" in os else "",
        version = version,
        arch = arch,
        os = os,
    )

WacInfo = provider(
    # @unsorted-dict-items
    fields = {
        "wac": provider_field(RunInfo),
        "plug": provider_field(RunInfo),
        "compose": provider_field(RunInfo),
        "parse": provider_field(RunInfo),
        "resolve": provider_field(RunInfo),
        "targets": provider_field(RunInfo),
    },
    doc = "Toolchain info provider for wac"
)

def _wac_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WacDistributionInfo]
    wac = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, subcommand):
        return cmd_script(
            actions = ctx.actions,
            name = name,
            cmd = cmd_args(wac, subcommand),
            language = ScriptLanguage("bat" if dist.os == "pc-windows-gnu" else "sh"),
        )

    wac_plug = create_subcommand("wac_plug", "plug")
    wac_compose = create_subcommand("wac_compose", "compose")
    wac_parse = create_subcommand("wac_parse", "parse")
    wac_resolve = create_subcommand("wac_resolve", "resolve")
    wac_targets = create_subcommand("wac_targets", "targets")

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],
        WacInfo(
            wac = wac,
            plug = RunInfo(args = cmd_args(wac_plug)),
            compose = RunInfo(args = cmd_args(wac_compose)),
            parse = RunInfo(args = cmd_args(wac_parse)),
            resolve = RunInfo(args = cmd_args(wac_resolve)),
            targets = RunInfo(args = cmd_args(wac_targets)),
        ),
    ]

wac_toolchain = rule(
    impl = _wac_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WacDistributionInfo]),
    },
    is_toolchain_rule = True,
)
