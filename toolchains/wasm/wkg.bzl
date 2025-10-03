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

WkgReleaseInfo = provider(
    fields = {
        "version": provider_field(typing.Any, default = None),
        "url": provider_field(typing.Any, default = None),
        "sha256": provider_field(typing.Any, default = None),
    },
    doc = """WkgReleaseInfo: Metadata for a specific prebuilt `wkg` release asset.""",
)

def _get_wkg_release(version: str, platform: str) -> WkgReleaseInfo:
    if not version in wkg_releases:
        fail("Unknown wkg release version '{}'. Available versions: {}".format(
            version,
            ", ".join(wkg_releases.keys()),
        ))

    ver = wkg_releases[version]
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
    fields = {
        "version": provider_field(typing.Any, default = None),
        "arch": provider_field(typing.Any, default = None),
        "os": provider_field(typing.Any, default = None),
    },
    doc = """WkgDistributionInfo: Toolchain provider exposing the `wkg` binary distribution metadata.""",
)

def _wkg_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    # Create a stable symlink named "wkg" that points to the downloaded file
    dst = ctx.actions.declare_output("wkg")
    src = cmd_args(ctx.attrs.dist[DefaultInfo].default_outputs[0], format = "{}")

    ctx.actions.run(
        ["ln", "-sf", cmd_args(src, relative_to = (dst, 1)), dst.as_output()],
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
        return "unknown-linux-gnu"
    elif os.is_macos:
        return "apple-darwin"
    elif os.is_windows:
        return "pc-windows-gnu"
    else:
        fail("Unsupported host os.")

def download_wkg(name: str, version: str, arch: [None, str] = None, os: [None, str] = None):
    """
    Download and register a prebuilt `wkg` CLI release as a local distribution and
    create a `wkg_distribution` target that exposes the binary and metadata.
    """

    if arch == None:
        arch = _host_arch()
    if os == None:
        os = _host_os()

    release = _get_wkg_release(version, "{}-{}".format(arch, os))

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
    fields = {
        "wkg": provider_field(typing.Any, default = None),
        "config": provider_field(typing.Any, default = None),
        "get": provider_field(typing.Any, default = None),
        "publish": provider_field(typing.Any, default = None),
        "oci": provider_field(typing.Any, default = None),
        "wit": provider_field(typing.Any, default = None),
    },
    doc = "Toolchain info provider for wkg"
)

def _wkg_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WkgDistributionInfo]
    wkg = ctx.attrs.distribution[RunInfo]

    def create_subcommand(name, subcommand):
        return cmd_script(
            ctx = ctx,
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
