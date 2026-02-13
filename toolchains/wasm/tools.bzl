"""WASM-Tools toolchain for WebAssembly manipulation and analysis.

WASM-Tools is a collection of utilities for working with WebAssembly modules,
including parsing, validation, optimization, and component model operations.

This toolchain provides a hermetic installation of wasm-tools and exposes
common subcommands as convenient wrappers.

## Examples

To automatically fetch a distribution suitable for the host-platform:

`toolchains//BUILD`
```bzl
load("//wasm:tools.bzl", "download_wasm_tools", "wasm_tools_toolchain")

download_wasm_tools(
    name = "wasm_tools_dist",
    version = "1.239.0",
)

wasm_tools_toolchain(
    name = "wasm_tools",
    distribution = ":wasm_tools_dist",
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
    "wasm_tools_releases",
    "wasi_adapters",
)
load(
    ":host.bzl",
    "host_arch",
    "host_os",
)

WasmToolsReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
)

def _get_wasm_tools_release(
        version: str,
        platform: str) -> WasmToolsReleaseInfo:
    if not version in wasm_tools_releases:
        fail("Unknown wasm-tools release version '{}'. Available versions: {}".format(
            version,
            ", ".join(wasm_tools_releases.keys()),
        ))
    wasm_tools_version = wasm_tools_releases[version]
    if not platform in wasm_tools_version:
        fail("Unsupported platform '{}'. Supported platforms: {}".format(
            platform,
            ", ".join(wasm_tools_version.keys()),
        ))
    wasm_tools_platform = wasm_tools_version[platform]
    return WasmToolsReleaseInfo(
        version = version,
        url = wasm_tools_platform["url"],
        sha256 = wasm_tools_platform["shasum"],
    )

WasmToolsDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
        "reactor_adapter": provider_field(Artifact),
        "command_adapter": provider_field(Artifact),
    },
)

def _wasm_tools_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    # Create a copy of the wasm-tools binary for easy access
    dst = ctx.actions.declare_output("wasm-tools")
    dist_output = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    src = cmd_args(dist_output, format = "{{}}/{}".format(ctx.attrs.prefix + "/wasm-tools" + ctx.attrs.suffix))

    ctx.actions.run(
        ["cp", src, dst.as_output()],
        category = "cp_wasm_tools",
    )

    wasm_tools = cmd_args(
        [dst],
        hidden = [
            ctx.attrs.dist[DefaultInfo].default_outputs,
            ctx.attrs.dist[DefaultInfo].other_outputs,
        ],
    )

    return [
        ctx.attrs.dist[DefaultInfo],
        RunInfo(args = wasm_tools),
        WasmToolsDistributionInfo(
            version = ctx.attrs.version,
            arch = ctx.attrs.arch,
            os = ctx.attrs.os,
            reactor_adapter = ctx.attrs.reactor_adapter[DefaultInfo].default_outputs[0],
            command_adapter = ctx.attrs.command_adapter[DefaultInfo].default_outputs[0],
        ),
    ]

wasm_tools_distribution = rule(
    impl = _wasm_tools_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "prefix": attrs.string(),
        "suffix": attrs.string(default = ""),
        "version": attrs.string(),
        "reactor_adapter": attrs.dep(providers = [DefaultInfo]),
        "command_adapter": attrs.dep(providers = [DefaultInfo]),
    },
)

def download_wasm_tools(
        name: str,
        version: str,
        adapter_version: str = "latest",
        arch: [None, str] = None,
        os: [None, str] = None):
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()

    archive_name = name + "-archive"
    release = _get_wasm_tools_release(version, "{}-{}".format(arch, os))

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )


    if adapter_version not in wasi_adapters:
        fail("Unknown WASI adapter version '{}'. Available versions: {}".format(
            adapter_version,
            ", ".join(wasi_adapters.keys()),
        ))
    adapter_info = wasi_adapters[adapter_version]

    native.http_file(
        name = name + "_reactor_adapter",
        urls = [adapter_info["reactor"]["url"]],
        sha256 = adapter_info["reactor"]["shasum"],
    )

    native.http_file(
        name = name + "_command_adapter",
        urls = [adapter_info["command"]["url"]],
        sha256 = adapter_info["command"]["shasum"],
    )

    wasm_tools_distribution(
        name = name,
        dist = ":" + archive_name,
        reactor_adapter = ":" + name + "_reactor_adapter",
        command_adapter = ":" + name + "_command_adapter",
        prefix = "wasm-tools-{}-{}-{}".format(version, arch, os),
        suffix = ".exe" if os == "windows" else "",
        version = version,
        arch = arch,
        os = os,
    )

WasmToolsInfo = provider(
    # @unsorted-dict-items
    fields = {
        "wasm_tools": provider_field(RunInfo),
        "component": provider_field(RunInfo),
        "compose": provider_field(RunInfo),
        "validate": provider_field(RunInfo),
        "print": provider_field(RunInfo),
        "parse": provider_field(RunInfo),
        "strip": provider_field(RunInfo),
        "metadata": provider_field(RunInfo),
        "reactor_adapter": provider_field(Artifact),
        "command_adapter": provider_field(Artifact),
    },
    doc = "Toolchain info provider for wasm-tools"
)

def _wasm_tools_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WasmToolsDistributionInfo]
    wasm_tools = ctx.attrs.distribution[RunInfo]

    # Create wrapper scripts for common wasm-tools subcommands
    def create_subcommand(name, subcommand):
        return cmd_script(
            ctx = ctx,
            name = name,
            cmd = cmd_args(wasm_tools, subcommand),
            language = ScriptLanguage("bat" if dist.os == "windows" else "sh"),
        )

    wasm_tools_component = create_subcommand("wasm_tools_component", "component")
    wasm_tools_compose = create_subcommand("wasm_tools_compose", "compose")
    wasm_tools_validate = create_subcommand("wasm_tools_validate", "validate")
    wasm_tools_print = create_subcommand("wasm_tools_print", "print")
    wasm_tools_parse = create_subcommand("wasm_tools_parse", "parse")
    wasm_tools_strip = create_subcommand("wasm_tools_strip", "strip")
    wasm_tools_metadata = create_subcommand("wasm_tools_metadata", "metadata")

    return [
        ctx.attrs.distribution[DefaultInfo],
        ctx.attrs.distribution[RunInfo],  # Direct access to wasm-tools binary
        WasmToolsInfo(
            wasm_tools = wasm_tools,
            component = RunInfo(args = cmd_args(wasm_tools_component)),
            compose = RunInfo(args = cmd_args(wasm_tools_compose)),
            validate = RunInfo(args = cmd_args(wasm_tools_validate)),
            print = RunInfo(args = cmd_args(wasm_tools_print)),
            parse = RunInfo(args = cmd_args(wasm_tools_parse)),
            strip = RunInfo(args = cmd_args(wasm_tools_strip)),
            metadata = RunInfo(args = cmd_args(wasm_tools_metadata)),
            reactor_adapter = dist.reactor_adapter,
            command_adapter = dist.command_adapter,
        ),
    ]

wasm_tools_toolchain = rule(
    impl = _wasm_tools_toolchain_impl,
    attrs = {
        "distribution": attrs.exec_dep(providers = [RunInfo, WasmToolsDistributionInfo]),
    },
    is_toolchain_rule = True,
)
