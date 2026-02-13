"""Self-contained C/C++ toolchain based on wasi-sdk.

WASI (WebAssembly System Interface) is a modular system interface for
WebAssembly. This toolchain provides a hermetic C/C++ compiler environment
for building WebAssembly applications using the wasi-sdk.

The toolchain automatically downloads the appropriate wasi-sdk distribution
for your platform and provides a complete cross-compilation environment
for WebAssembly targets.

## Examples

To automatically fetch a distribution suitable for the host-platform configure
the toolchain like so:

`toolchains//BUILD`
```bzl
load("//cxx/wasi:defs.bzl", "download_wasi_sdk", "cxx_wasi_toolchain")

download_wasi_sdk(
    name = "wasi-sdk",
    version = "27.0",
)

cxx_wasi_toolchain(
    name = "cxx",
    distribution = ":wasi-sdk",
    visibility = ["PUBLIC"],
)
```
"""

load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "LinkerInfo",
    "LinkerType",
    "ShlibInterfacesMode",
    "StripFlagsInfo",
    "cxx_toolchain_infos",
)
load(
    "@prelude//cxx:headers.bzl",
    "HeaderMode",
)
load(
    "@prelude//cxx:linker.bzl",
    "is_pdb_generated",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)
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
    "releases",
)

def _host_arch() -> str:
    arch = host_info().arch
    if arch.is_x86_64:
        return "x86_64"
    elif arch.is_aarch64:
        return "aarch64"
    else:
        fail("Unsupported host architecture.")

def _host_os(os_map: [None, dict] = None) -> str:
    os = host_info().os
    if os.is_linux:
        key = "linux"
    elif os.is_macos:
        key = "macos"
    elif os.is_windows:
        key = "windows"
    else:
        fail("Unsupported host OS.")
    if os_map:
        if key not in os_map:
            fail("No OS mapping for '{}'. Available: {}".format(key, ", ".join(os_map.keys())))
        return os_map[key]
    return key

_WASI_SDK_ARCH_MAP = {
    "x86_64": "x86_64",
    "aarch64": "arm64",
}

WasiSdkReleaseInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "url": provider_field(str),
        "sha256": provider_field(str),
    },
)

def _get_wasi_sdk_release(
        version: str,
        platform: str) -> WasiSdkReleaseInfo:
    if not version in releases:
        fail("Unknown wasi-sdk release version '{}'. Available versions: {}".format(
            version,
            ", ".join(releases.keys()),
        ))
    wasi_version = releases[version]
    if not platform in wasi_version:
        fail("Unsupported platform '{}'. Supported platforms: {}".format(
            platform,
            ", ".join(wasi_version.keys()),
        ))
    wasi_platform = wasi_version[platform]
    return WasiSdkReleaseInfo(
        version = version,
        url = wasi_platform["tarball"],
        sha256 = wasi_platform["shasum"],
    )

WasiSdkDistributionInfo = provider(
    # @unsorted-dict-items
    fields = {
        "version": provider_field(str),
        "arch": provider_field(str),
        "os": provider_field(str),
        "bin_path": provider_field(str),
        "sysroot_path": provider_field(str),
    },
)

def _wasi_sdk_distribution_impl(ctx: AnalysisContext) -> list[Provider]:
    version = ctx.attrs.version
    arch = ctx.attrs.arch
    os = ctx.attrs.os
    prefix = "wasi-sdk-{}-{}-{}/".format(version, arch, os)

    return [
        ctx.attrs.dist[DefaultInfo],
        WasiSdkDistributionInfo(
            version = version,
            arch = arch,
            os = os,
            bin_path = "{}bin".format(prefix),
            sysroot_path = "{}share/wasi-sysroot".format(prefix),
        ),
    ]

wasi_sdk_distribution = rule(
    impl = _wasi_sdk_distribution_impl,
    attrs = {
        "arch": attrs.string(),
        "dist": attrs.dep(providers = [DefaultInfo]),
        "os": attrs.string(),
        "version": attrs.string(),
    },
)

def download_wasi_sdk(
        name: str,
        version: str,
        arch: [None, str] = None,
        os: [None, str] = None):
    if arch == None:
        arch = _WASI_SDK_ARCH_MAP[_host_arch()]
    if os == None:
        os = _host_os()

    archive_name = name + "-archive"
    release = _get_wasi_sdk_release(version, "{}-{}".format(arch, os))

    native.http_archive(
        name = archive_name,
        urls = [release.url],
        sha256 = release.sha256,
    )

    wasi_sdk_distribution(
        name = name,
        dist = ":" + archive_name,
        version = version,
        arch = arch,
        os = os,
    )

def _tool_path(dist_artifact, dist_info, tool_name):
    return cmd_args(dist_artifact, format = "{}/{}/{}".format("{}", dist_info.bin_path, tool_name))

def _create_tool_script(ctx, dist_artifact, dist_info, name, tool_name):
    return cmd_script(
        ctx = ctx,
        name = name,
        cmd = cmd_args([_tool_path(dist_artifact, dist_info, tool_name)]),
        language = ScriptLanguage("bat" if dist_info.os == "windows" else "sh"),
    )

def _cxx_wasi_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.distribution[WasiSdkDistributionInfo]
    dist_artifact = ctx.attrs.distribution[DefaultInfo].default_outputs[0]

    linker_tool = ctx.attrs.linker_tool if ctx.attrs.linker_tool else "clang++"
    target_flags = ["-target", ctx.attrs.target] if ctx.attrs.target else ["-target", "wasm32-wasip2"]
    sysroot_flags = [cmd_args(dist_artifact, format = "--sysroot={}/{}".format("{}", dist.sysroot_path))]
    common_compiler_flags = target_flags + sysroot_flags

    wasi_cc = _create_tool_script(ctx, dist_artifact, dist, "wasi_cc", "clang")
    wasi_cxx = _create_tool_script(ctx, dist_artifact, dist, "wasi_cxx", "clang++")
    wasi_ld = _create_tool_script(ctx, dist_artifact, dist, "wasi_ld", linker_tool)
    wasi_ar = _create_tool_script(ctx, dist_artifact, dist, "wasi_ar", "llvm-ar")
    wasi_ranlib = _create_tool_script(ctx, dist_artifact, dist, "wasi_ranlib", "llvm-ranlib")
    wasi_strip = _create_tool_script(ctx, dist_artifact, dist, "wasi_strip", "llvm-strip")
    wasi_nm = _create_tool_script(ctx, dist_artifact, dist, "wasi_nm", "llvm-nm")
    wasi_objcopy = _create_tool_script(ctx, dist_artifact, dist, "wasi_objcopy", "llvm-objcopy")

    return [ctx.attrs.distribution[DefaultInfo]] + cxx_toolchain_infos(
        internal_tools = ctx.attrs._cxx_internal_tools[CxxInternalTools],
        platform_name = "wasm32-wasi",
        c_compiler_info = CCompilerInfo(
            compiler = RunInfo(args = cmd_args(wasi_cc)),
            compiler_type = "clang",
            compiler_flags = cmd_args(common_compiler_flags, ctx.attrs.c_compiler_flags),
            preprocessor_flags = cmd_args(ctx.attrs.c_preprocessor_flags),
        ),
        cxx_compiler_info = CxxCompilerInfo(
            compiler = RunInfo(args = cmd_args(wasi_cxx)),
            compiler_type = "clang",
            compiler_flags = cmd_args(common_compiler_flags, ctx.attrs.cxx_compiler_flags),
            preprocessor_flags = cmd_args(ctx.attrs.cxx_preprocessor_flags),
        ),
        linker_info = LinkerInfo(
            archiver = RunInfo(args = cmd_args(wasi_ar)),
            archiver_type = "gnu",
            archiver_supports_argfiles = True,
            archive_objects_locally = False,
            binary_extension = ".wasm",
            generate_linker_maps = False,
            link_binaries_locally = False,
            link_libraries_locally = False,
            link_style = LinkStyle(ctx.attrs.link_style),
            link_weight = 1,
            linker = RunInfo(args = cmd_args(wasi_ld)),
            linker_flags = cmd_args(ctx.attrs.linker_flags),
            object_file_extension = "o",
            shlib_interfaces = ShlibInterfacesMode("disabled"),
            shared_dep_runtime_ld_flags = ctx.attrs.shared_dep_runtime_ld_flags,
            shared_library_name_default_prefix = "",
            shared_library_name_format = "{}.wasm",
            shared_library_versioned_name_format = "{}.{}.wasm",
            static_dep_runtime_ld_flags = ctx.attrs.static_dep_runtime_ld_flags,
            static_library_extension = "a",
            static_pic_dep_runtime_ld_flags = ctx.attrs.static_pic_dep_runtime_ld_flags,
            independent_shlib_interface_linker_flags = ctx.attrs.shared_library_interface_flags,
            type = LinkerType("wasm"),
            use_archiver_flags = True,
            is_pdb_generated = is_pdb_generated(LinkerType("gnu"), ctx.attrs.linker_flags),
        ),
        binary_utilities_info = BinaryUtilitiesInfo(
            bolt_msdk = None,
            dwp = None,
            nm = RunInfo(args = cmd_args(wasi_nm)),
            objcopy = RunInfo(args = cmd_args(wasi_objcopy)),
            ranlib = RunInfo(args = cmd_args(wasi_ranlib)),
            strip = RunInfo(args = cmd_args(wasi_strip)),
        ),
        header_mode = HeaderMode("symlink_tree_only"),
        strip_flags_info = StripFlagsInfo(
            strip_debug_flags = ctx.attrs.strip_debug_flags,
            strip_non_global_flags = ctx.attrs.strip_non_global_flags,
            strip_all_flags = ctx.attrs.strip_all_flags,
        ),
    )

cxx_wasi_toolchain = rule(
    impl = _cxx_wasi_toolchain_impl,
    attrs = {
        "c_compiler_flags": attrs.list(attrs.arg(), default = []),
        "c_preprocessor_flags": attrs.list(attrs.arg(), default = []),
        "cxx_compiler_flags": attrs.list(attrs.arg(), default = []),
        "cxx_preprocessor_flags": attrs.list(attrs.arg(), default = []),
        "distribution": attrs.exec_dep(providers = [WasiSdkDistributionInfo]),
        "linker_tool": attrs.option(
            attrs.enum(["wasm-ld", "clang++", "clang"]),
            default = None,
            doc = "Which linker tool to use"
        ),
        "link_style": attrs.enum(
            LinkStyle.values(),
            default = "static",
            doc = """
            The default value of the `link_style` attribute for rules that use this toolchain.
            """,
        ),
        "linker_flags": attrs.list(attrs.arg(), default = []),
        "shared_dep_runtime_ld_flags": attrs.list(attrs.arg(), default = []),
        "shared_library_interface_flags": attrs.list(attrs.string(), default = []),
        "static_dep_runtime_ld_flags": attrs.list(attrs.arg(), default = []),
        "static_pic_dep_runtime_ld_flags": attrs.list(attrs.arg(), default = []),
        "strip_all_flags": attrs.option(attrs.list(attrs.arg()), default = None),
        "strip_debug_flags": attrs.option(attrs.list(attrs.arg()), default = None),
        "strip_non_global_flags": attrs.option(attrs.list(attrs.arg()), default = None),
        "target": attrs.option(attrs.string(), default = None),
        "_cxx_internal_tools": attrs.default_only(attrs.dep(providers = [CxxInternalTools], default = "prelude//cxx/tools:internal_tools")),
    },
    is_toolchain_rule = True,
)
