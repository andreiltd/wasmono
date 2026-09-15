"""Analysis-only platforms: never execute these foreign-platform fixtures."""

load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")
load(
    "@wasmono//:defs.bzl",
    "JcoInfo",
    "asc_toolchain",
    "download_node",
    "install_asc",
    "install_jco",
    "jco_toolchain",
    "node_toolchain",
)
load("@wasmono//toolchains/wasm:assemblyscript.bzl", "AscInfo")
load("@wasmono//toolchains/wasm:node.bzl", "NodeInfo")

def _remote_platform_impl(ctx):
    constraints = dict(ctx.attrs.cpu[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os[ConfigurationInfo].constraints)
    configuration = ConfigurationInfo(constraints = constraints, values = {})
    label = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = label,
        configuration = configuration,
        executor_config = CommandExecutorConfig(
            local_enabled = False,
            remote_enabled = True,
            remote_cache_enabled = False,
            remote_execution_properties = {"platform": str(label)},
            remote_execution_use_case = "toolchain-regression-analysis-only",
        ),
    )
    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(label), configuration = configuration),
    ]

remote_platform = rule(
    impl = _remote_platform_impl,
    attrs = {
        "cpu": attrs.dep(providers = [ConfigurationInfo]),
        "os": attrs.dep(providers = [ConfigurationInfo]),
    },
)

def _execution_platforms_impl(ctx):
    return [
        DefaultInfo(),
        ExecutionPlatformRegistrationInfo(
            platforms = [platform[ExecutionPlatformInfo] for platform in ctx.attrs.platforms],
            exec_marker_constraint = get_exec_platform_marker(),
        ),
    ]

execution_platforms = rule(
    impl = _execution_platforms_impl,
    attrs = {
        "platforms": attrs.list(attrs.dep(providers = [ExecutionPlatformInfo])),
    },
)

def _npm_consumer_impl(ctx):
    return [
        DefaultInfo(
            default_output = ctx.attrs.asc[AscInfo].workspace,
            other_outputs = [
                ctx.attrs.jco[JcoInfo].jco,
                ctx.attrs.node[NodeInfo].node,
            ],
        ),
    ]

npm_consumer = rule(
    impl = _npm_consumer_impl,
    attrs = {
        "asc": attrs.toolchain_dep(providers = [AscInfo]),
        "jco": attrs.toolchain_dep(providers = [JcoInfo]),
        "node": attrs.toolchain_dep(providers = [NodeInfo]),
    },
)

def npm_platform_fixture(name, arch, os):
    download_node(
        name = name + "_node_dist",
        version = "26.8.2",
        arch = arch,
        os = os,
    )
    node_toolchain(
        name = name + "_node",
        distribution = ":" + name + "_node_dist",
    )
    install_jco(
        name = name + "_jco_dist",
        node = ":" + name + "_node_dist",
    )
    install_asc(
        name = name + "_asc_dist",
        node = ":" + name + "_node_dist",
    )
    jco_toolchain(
        name = name + "_jco",
        distribution = ":" + name + "_jco_dist",
        _node_toolchain = ":" + name + "_node",
    )
    asc_toolchain(
        name = name + "_asc",
        distribution = ":" + name + "_asc_dist",
    )
    npm_consumer(
        name = name + "_consumer",
        asc = ":" + name + "_asc",
        jco = ":" + name + "_jco",
        node = ":" + name + "_node",
    )
