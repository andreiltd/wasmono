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

WacReleaseInfo = provider(
    fields = {
        "version": provider_field(typing.Any, default = None),
        "url": provider_field(typing.Any, default = None),
        "sha256": provider_field(typing.Any, default = None),
    },
    doc = """WacReleaseInfo: Metadata for a specific prebuilt `wac` release asset.""",
)

def _get_wac_release(version: str, platform: str) -> WacReleaseInfo:
    if not version in wac_releases:
        fail("Unknown wac release version '{}'. Available versions: {}".format(
            version,
            ", ".join(wac_releases.keys()),
        ))

    ver = wac_releases[version]
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
    fields = {
        "version": provider_field(typing.Any, default = None),
        "arch": provider_field(typing.Any, default = None),
        "os": provider_field(typing.Any, default = None),
    },
    doc = """WacInfo: Toolchain provider exposing the `wac` binary and convenient RunInfo wrappers for common subcommands.""",
)

def _wac_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    # Create a stable symlink named "wac" that points to the downloaded file
    dst = ctx.actions.declare_output("wac")
    src = cmd_args(ctx.attrs.dist[DefaultInfo].default_outputs[0], format = "{}")

    ctx.actions.run(
        ["ln", "-sf", cmd_args(src, relative_to = (dst, 1)), dst.as_output()],
        category = "cp_wac",
    )

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
        "version": attrs.string(),
    },
)

def _host_arch() -> str:
    arch = host_info().arch
    if arch.is_x86_64:
        return "x86_64"
    elif host_info().arch.is_aarch64:
        return "aarch64"
    else:
        fail("Unsupported host architecture.")

def _host_os() -> str:
    os = host_info().os
    if os.is_linux:
        return "unknown-linux-musl"
    elif os.is_macos:
        return "apple-darwin"
    elif os.is_windows:
        return "pc-windows-gnu"
    else:
        fail("Unsupported host os.")

def download_wac(name: str, version: str, arch: [None, str] = None, os: [None, str] = None):
    """
    Download and register a prebuilt `wac` CLI release as a local distribution and
    create a `wac_distribution` target that exposes the binary and metadata.
    """

    if arch == None:
        arch = _host_arch()
    if os == None:
        os = _host_os()

    release = _get_wac_release(version, "{}-{}".format(arch, os))

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
        version = version,
        arch = arch,
        os = os,
    )

WacInfo = provider(
    fields = {
        "wac": provider_field(typing.Any, default = None),
        "plug": provider_field(typing.Any, default = None),
        "compose": provider_field(typing.Any, default = None),
        "parse": provider_field(typing.Any, default = None),
        "resolve": provider_field(typing.Any, default = None),
        "targets": provider_field(typing.Any, default = None),
    },
    doc = "Toolchain info provider for wac"
)

def _wac_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WacDistributionInfo]
    wac = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, subcommand):
        return cmd_script(
            ctx = ctx,
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
