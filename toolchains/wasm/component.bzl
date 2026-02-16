"""
Buck2 rules for building WASM components and generating WIT bindings.

This module provides comprehensive WASM component tooling:

## WASM Component Rules (using wasm-tools):
- wasm_component: Create component from single module + optional interface
- wasm_component_link: Link multiple modules/components
- wasm_validate: Validate WASM modules/components
- wasm_print: Convert WASM to text format

## WASM Execution Rules (using wasmtime CLI):
- wasm_run: Run a WASM component and capture output
- wasm_test: Test a WASM component (exit code = pass/fail)

## WIT Binding Generation Rules (using wit-bindgen):
- wit_bindgen_rust: Generate Rust bindings from WIT
- wit_bindgen_c: Generate C bindings from WIT
- wit_bindgen_cxx: Generate C++ bindings from WIT
- wit_to_markdown: Generate documentation from WIT

## Examples:

### Component Creation
    # Create component directly from wasm binary
    rust_binary(
        name = "my_rust_lib",
        srcs = glob(["src/**/*.rs"]),
        default_target_platform = "//platforms:wasm32_wasi",
    )

    wasm_component(
        name = "rust_component",
        module = ":my_rust_lib",
        wit = "interface.wit",
    )

    # Link multiple components
    wasm_component_link(
        name = "polyglot_component",
        modules = [":component1", ":component2"],
    )

### Binding Generation
    wit_bindgen_cxx(
        name = "cxx_bindings",
        wit = ["api.wit"],
        world = "my-world",
    )

    # Use generated bindings in a library
    cxx_library(
        name = "my_lib",
        srcs = glob(["src/**/*.cpp"]) + [":cxx_bindings"],
    )
"""

load("@prelude//:asserts.bzl", "asserts")
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load(
    "@prelude//cxx:preprocessor.bzl",
    "CPreprocessor",
    "CPreprocessorArgs",
    "CPreprocessorInfo",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//linking:link_info.bzl",
    "ObjectsLinkable",
    "LibOutputStyle",
    "LinkInfo",
    "LinkInfos",
    "create_merged_link_info",
)
load("@prelude//linking:link_groups.bzl", "merge_link_group_lib_info")
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraries",
    "SharedLibraryInfo",
    "merge_shared_libraries",
)

load(":bindgen.bzl", "WitBindgenInfo")
load(":binaryen.bzl", "BinaryenInfo")
load(":jco.bzl", "JcoInfo")
load(":tools.bzl", "WasmToolsInfo")
load(":transition.bzl", "wasm_transition")
load(":wac.bzl", "WacInfo")
load(":wasmtime.bzl", "WasmtimeInfo")
load(":wkg.bzl", "WkgInfo")

# ============================================================================
# PROVIDERS AND COMMON UTILITIES
# ============================================================================

WasmInfo = provider(
    # @unsorted-dict-items
    fields = {
        "module": provider_field(typing.Any, default = None),     # single core .wasm artifact (or None)
        "component": provider_field(typing.Any, default = None),  # single component .component.wasm artifact (or None)
        "wit": provider_field(typing.Any, default = []),         # list of WIT artifacts (files or directories)
    },
    doc = "Provider for WASM-related files and metadata",
)

WitBindingInfo = provider(
    # @unsorted-dict-items
    fields = {
        "bindings": provider_field(typing.Any, default = None),
        "language": provider_field(typing.Any, default = None),
        "world": provider_field(typing.Any, default = None),
        "wit": provider_field(typing.Any, default = []),
    },
    doc = "Provider for WIT binding generation metadata",
)

def _world_to_snake_case(world: str) -> str:
    world_part = world.split(":")[-1]
    world_base = world_part.split("/")[-1]

    s = world_base.replace("-", "_")
    r = ""
    for c in s.elems():
        if "A" <= c and c <= "Z":
            if r and r[-1] != "_":
                r += "_"
            r += c.lower()
        else:
            r += c
    return r

def _wasm_modules_from_deps(deps):
    """Extract core .wasm module artifacts from configured deps."""
    results = []
    for dep in deps:
        if WasmInfo in dep:
            wi = dep[WasmInfo]
            if getattr(wi, "module", None):
                # module is a single artifact
                results.append(wi.module)
            continue

        if DefaultInfo in dep:
            for out in dep[DefaultInfo].default_outputs:
                if out.basename.endswith(".wasm") and not out.basename.endswith(".component.wasm"):
                    results.append(out)
                    continue
    return results

def _components_from_deps(deps):
    """Extract .component.wasm artifacts from configured deps."""
    results = []
    for dep in deps:
        if WasmInfo in dep:
            info = dep[WasmInfo]
            if getattr(info, "component", None):
                results.append(info.component)
            continue

        if DefaultInfo in dep:
            for out in dep[DefaultInfo].default_outputs:
                if out.basename.endswith(".component.wasm"):
                    results.append(out)
                    continue
    return results

def _wat_files_from_deps(deps):
    """Extract .wat artifacts from configured deps."""
    results = []
    for dep in deps:
        if DefaultInfo in dep:
            for out in dep[DefaultInfo].default_outputs:
                if out.basename.endswith(".wat"):
                    results.append(out)
                    continue
    return results

def _wit_from_deps(deps):
    """Extract WIT artifacts (files, .wasm WIT packages, or directories) from configured deps."""
    results = []
    for dep in deps:
        if WasmInfo in dep:
            info = dep[WasmInfo]
            if getattr(info, "wit", None):
                for w in info.wit:
                    results.append(w)
                continue

        if DefaultInfo in dep:
            for out in dep[DefaultInfo].default_outputs:
                name = out.basename
                if name.endswith(".wit") or name.endswith(".wasm"):
                    results.append(out)
                    continue
                # conservative heuristic for directories
                if name == "wit":
                    results.append(out)
                    continue

    return results

def _all_wasm_files_from_deps(deps):
    """Collect modules, components, and wat files from deps."""
    modules = _wasm_modules_from_deps(deps)
    components = _components_from_deps(deps)
    wats = _wat_files_from_deps(deps)
    return modules + components + wats

def _resolve_single_from_deps(deps, extractor, kind_desc):
    """Resolve exactly one artifact from deps using extractor; fail with helpful message."""
    artifacts = extractor(deps)
    if len(artifacts) == 0:
        labels = [str(d.label) for d in deps]
        fail("{}: no {} found in deps {}".format(kind_desc, kind_desc, labels))
    if len(artifacts) > 1:
        labels = [str(d.label) for d in deps]
        names = [a.basename for a in artifacts]
        fail("{}: found multiple {} from deps {}: {}. Expected exactly one.".format(kind_desc, kind_desc, labels, names))
    return artifacts[0]

# ============================================================================
# WASM COMPONENT RULE (single-module) using wasm-tools
# ============================================================================

def _wasm_component_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a WASM component from a single core module and optional WIT interface."""
    module_dep = ctx.attrs.module
    module_file = _resolve_single_from_deps([module_dep], _wasm_modules_from_deps, "core wasm module")

    wit = ctx.attrs.wit if ctx.attrs.wit else None
    wasm_tools_info = ctx.attrs._wasm_tools_toolchain[WasmToolsInfo]

    # Build the component
    output_file = ctx.actions.declare_output("{}.component.wasm".format(ctx.label.name))

    # Select adapter based on component type
    adapter = wasm_tools_info.command_adapter if ctx.attrs.adapter == "command" else wasm_tools_info.reactor_adapter
    adapter_arg = cmd_args(adapter, format = "wasi_snapshot_preview1={}")

    cmd = cmd_args(
        wasm_tools_info.component, "new", module_file,
        "--adapt", adapter_arg,
        "-o", output_file.as_output(),
    )

    if ctx.attrs.skip_validation:
        cmd.add("--skip-validation")

    ctx.actions.run(cmd, category = "wasm_component_new")

    return [
        DefaultInfo(default_output = output_file),
        WasmInfo(
            module = None,
            component = output_file,
            wit = [wit] if wit else [],
        ),
    ]

wasm_component = rule(
    impl = _wasm_component_impl,
    attrs = {
        "module": attrs.transition_dep(
            cfg = wasm_transition,
            doc = "Single configured dependency that produces a core .wasm module",
        ),
        "wit": attrs.option(
            attrs.source(),
            default = None,
            doc = "Optional single WIT file, directory, or .wasm WIT package to embed",
        ),
        "skip_validation": attrs.bool(
            default = False,
            doc = "Skip validation of the component (needed for WASI P3 async exports)",
        ),
        "adapter": attrs.enum(
            ["reactor", "command"],
            default = "reactor",
            doc = "WASI adapter type: 'reactor' for library components, 'command' for CLI components with wasi:cli/run",
        ),
        "_wasm_tools_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wasm_tools",
            providers = [WasmToolsInfo],
        ),
    },
    doc = "Creates a WASM Component from WASM module using 'wasm-tools component new'",
)

# ============================================================================
# WASM COMPONENT LINK (multiple modules/components) using wasm-tools
# ============================================================================

def _wasm_component_link_impl(ctx: AnalysisContext) -> list[Provider]:
    """Link multiple modules/components into a single component."""
    if not ctx.attrs.modules:
        fail("wasm_component_link: 'modules' attribute is required and must be a list of configured deps")

    wasm_files = _all_wasm_files_from_deps(ctx.attrs.modules)

    if len(wasm_files) == 0:
        labels = [str(t.label) for t in ctx.attrs.modules]
        fail("wasm_component_link: no .wasm or .component.wasm files found in targets: {}".format(labels))

    wasm_tools_info = ctx.attrs._wasm_tools_toolchain[WasmToolsInfo]
    output_file = ctx.actions.declare_output("{}.component.wasm".format(ctx.label.name))

    cmd = cmd_args(wasm_tools_info.component)
    cmd.add("link")
    if ctx.attrs.skip_validation:
        cmd.add("--skip-validation")
    if ctx.attrs.stub_missing_functions:
        cmd.add("--stub-missing-functions")
    if ctx.attrs.use_builtin_libdl:
        cmd.add("--use-built-in-libdl")

    for f in wasm_files:
        cmd.add(f)

    cmd.add("-o")
    cmd.add(output_file.as_output())

    ctx.actions.run(cmd, category = "wasm_component_link")

    return [
        DefaultInfo(default_output = output_file),
        WasmInfo(
            module = None,
            component = output_file,
            wit = [],
        ),
    ]

wasm_component_link = rule(
    impl = _wasm_component_link_impl,
    attrs = {
        "modules": attrs.list(
            attrs.transition_dep(cfg = wasm_transition),
            doc = "List of deps that produce .wasm or .component.wasm files",
        ),
        "skip_validation": attrs.bool(default = False, doc = "Skip validation of the linked component"),
        "stub_missing_functions": attrs.bool(default = False, doc = "Stub out any missing function imports"),
        "use_builtin_libdl": attrs.bool(default = False, doc = "Use the built-in libdl implementation"),
        "_wasm_tools_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wasm_tools",
            providers = [WasmToolsInfo],
        ),
    },
    doc = "Links multiple WASM modules/components into a single component via 'wasm-tools component link'",
)

# ============================================================================
# WASM UTILITY RULES (validate, print)
# ============================================================================

def _wasm_validate_impl(ctx: AnalysisContext) -> list[Provider]:
    """Validate a single input (module/component/wat)."""
    input_file = _resolve_single_from_deps([ctx.attrs.input], _all_wasm_files_from_deps, "input artifact to validate")
    wasm_tools_info = ctx.attrs._wasm_tools_toolchain[WasmToolsInfo]
    output_file = ctx.actions.declare_output("{}.validation.txt".format(ctx.label.name))

    cmd = cmd_args(wasm_tools_info.validate)
    cmd.add(input_file)
    cmd.add("-o")
    cmd.add(output_file.as_output())

    ctx.actions.run(cmd, category = "wasm_validate")

    return [ DefaultInfo(default_output = output_file) ]

wasm_validate = rule(
    impl = _wasm_validate_impl,
    attrs = {
        "input": attrs.dep(
            doc = "Configured dep that produces a .wat, .wasm or .component.wasm file to validate",
        ),
        "_wasm_tools_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wasm_tools",
            providers = [WasmToolsInfo],
        ),
    },
    doc = "Validates WASM modules/components using 'wasm-tools validate'",
)

def _wasm_print_impl(ctx: AnalysisContext) -> list[Provider]:
    """Print a single wasm/component to text (.wat)."""
    input_file = _resolve_single_from_deps([ctx.attrs.input], _all_wasm_files_from_deps, "input artifact to print")
    wasm_tools_info = ctx.attrs._wasm_tools_toolchain[WasmToolsInfo]
    output_file = ctx.actions.declare_output("{}.wat".format(ctx.label.name))

    cmd = cmd_args(wasm_tools_info.print)
    cmd.add(input_file)
    cmd.add("-o")
    cmd.add(output_file.as_output())

    ctx.actions.run(cmd, category = "wasm_print")

    return [ DefaultInfo(default_output = output_file) ]

wasm_print = rule(
    impl = _wasm_print_impl,
    attrs = {
        "input": attrs.dep(
            doc = "Configured dep producing wasm or component to convert to text",
        ),
        "_wasm_tools_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wasm_tools",
            providers = [WasmToolsInfo],
        ),
    },
    doc = "Converts WASM module/component to text format using 'wasm-tools print'",
)

# ============================================================================
# WIT BINDING GENERATION - COMMON UTILITIES
# ============================================================================

def _create_cxx_providers(ctx: AnalysisContext, outputs: dict, world: str, language: str):
    """Create common C/C++ providers (preprocessor and link info)."""

    incdir = cmd_args("-I", outputs["srcs"][0].as_output(), parent = 1, hidden = outputs["headers"])
    std = cmd_args("-std=c++20")

    preprocessor_args = [incdir, std if language == "cpp" else []]
    preprocessor_info = cxx_merge_cpreprocessors(
        ctx.actions,
        [CPreprocessor(args = CPreprocessorArgs(args = preprocessor_args))],
        []
    )

    # Add link info for object files
    asserts.true(len(outputs["objs"]) > 0, "Expected a objs in the outputs to create link info" )

    cxx_toolchain = get_cxx_toolchain_info(ctx)
    linker_type = cxx_toolchain.linker_info.type
    pic_behavior = cxx_toolchain.pic_behavior

    linkables = [
        ObjectsLinkable(
            objects = outputs["objs"],
            linker_type = linker_type,
            link_whole = False,
        )
    ]

    link_infos = LinkInfos(
        default = LinkInfo(
            name = ctx.attrs.name or world,
            linkables = linkables,
        ),
    )

    link_info = create_merged_link_info(
        ctx,
        pic_behavior,
        { LibOutputStyle("archive"): link_infos, },
    )

    shared_library_info = merge_shared_libraries(
        ctx.actions,
        SharedLibraries(libraries = []),
        []
    )

    link_group_lib_info = merge_link_group_lib_info(deps = [])

    return [preprocessor_info, link_info, shared_library_info, link_group_lib_info]

def _build_wit_bindgen_cmd(wit_bindgen_info, language, wit_inputs, outdir, **kwargs):
    """Build base wit-bindgen command with common arguments.

    wit_inputs may be a mix of source paths (strings) and artifact objects.
    """
    language_map = {
        "rust": wit_bindgen_info.rust,
        "cpp": wit_bindgen_info.cxx,
        "c": wit_bindgen_info.c,
    }

    cmd = cmd_args(language_map[language], outdir)
    cmd.add([wit for wit in wit_inputs])

    cmd.add("--world")
    cmd.add(kwargs["world"])

    if kwargs.get("all_features", False):
        cmd.add("--all-features")

    if kwargs.get("features"):
        cmd.add("--features")
        cmd.add(",".join(kwargs["features"]))

    if kwargs.get("async_config"):
        for async_opt in kwargs["async_config"]:
            cmd.add("--async")
            cmd.add(async_opt)

    return cmd

def _wit_bindgen_base_impl(ctx: AnalysisContext, language: str, outputs: dict, extra_args = []):
    """Generic wit-bindgen implementation that returns common providers."""
    # Gather WIT inputs and build the bindgen command
    wit_bindgen_info = ctx.attrs._wit_bindgen_toolchain[WitBindgenInfo]
    produced = _wit_from_deps(ctx.attrs.deps) if ctx.attrs.deps else []
    explicit = list(ctx.attrs.wit) if ctx.attrs.wit else []
    all_wits = produced + explicit

    srcs, objs, headers = outputs["srcs"], outputs["objs"], outputs["headers"]
    outdir = cmd_args("--out-dir", srcs[0].as_output(), parent = 1)

    cmd = _build_wit_bindgen_cmd(
        wit_bindgen_info,
        language,
        all_wits,
        outdir,
        world        = ctx.attrs.world,
        async_config = ctx.attrs.async_config,
        all_features = ctx.attrs.all_features,
        features     = ctx.attrs.features,
    )

    # implicit output dependencies to ensure they are created
    hidden = cmd_args(hidden = [gen.as_output() for gen in srcs + objs + headers])
    cmd.add(hidden)
    cmd.add([arg for arg in extra_args])

    ctx.actions.run(cmd, category = f"wit_bindgen_{language}")

    return [
        DefaultInfo(
            default_outputs = srcs,
            sub_targets = {
                "objs":    [DefaultInfo(default_outputs = objs)],
                "headers": [DefaultInfo(default_outputs = headers)],
            },
        ),
        WitBindingInfo(
            bindings = srcs + objs + headers,
            language = language,
            world = ctx.attrs.world,
            wit = all_wits,
        ),
    ]

# Common attributes for all wit-bindgen rules
_wit_bindgen_common_attrs = {
    "wit": attrs.list(
        attrs.source(),
        doc = "WIT files, directories, or .wasm files to generate bindings from",
    ),
    "deps": attrs.list(
        attrs.dep(),
        default = [],
        doc = "Optional targets that produce WIT artifacts (e.g. wasm_component, export_file, filegroup)",
    ),
    "world": attrs.option(
        attrs.string(),
        doc = "World name (required to predictably generate output filenames at analysis time)",
    ),
    "async_config": attrs.list(
        attrs.string(),
        default = [],
        doc = "List of async configuration options (e.g., ['all', 'foo:bar/baz#method'])",
    ),
    "all_features": attrs.bool(
        default = False,
        doc = "Enable all WIT features (@unstable annotations)",
    ),
    "features": attrs.list(
        attrs.string(),
        default = [],
        doc = "Comma-separated list of specific features to enable",
    ),
    "_wit_bindgen_toolchain": attrs.toolchain_dep(
        default = "toolchains//:wit_bindgen",
        providers = [WitBindgenInfo],
    ),
    "_cxx_toolchain": attrs.toolchain_dep(
        default = "toolchains//:cxx_wasi",
        providers = [CxxToolchainInfo],
    ),
}

# ============================================================================
# WIT BINDING GENERATION RULES (using wit-bindgen)
# ============================================================================

def _wit_bindgen_rust_impl(ctx: AnalysisContext) -> list[Provider]:
    snake = _world_to_snake_case(ctx.attrs.world)
    outputs = {
        "srcs": [ctx.actions.declare_output(f"{snake}.rs")],
        "objs": [],
        "headers": [],
    }

    return _wit_bindgen_base_impl(ctx, "rust", outputs, extra_args = ["--generate-all"])

wit_bindgen_rust = rule(
    impl = _wit_bindgen_rust_impl,
    attrs = _wit_bindgen_common_attrs,
    doc = "Generates Rust bindings from WIT interface definitions using wit-bindgen"
)

def _wit_bindgen_c_impl(ctx: AnalysisContext) -> list[Provider]:
    snake = _world_to_snake_case(ctx.attrs.world)

    outputs = {
        "srcs": [ctx.actions.declare_output(f"{snake}.c")],
        "objs": [ctx.actions.declare_output(f"{snake}_component_type.o")],
        "headers": [
            ctx.actions.declare_output(f"{snake}.h"),
            ctx.actions.declare_output("wit.h")
        ],
    }

    providers = _wit_bindgen_base_impl(ctx, "c", outputs)
    providers.extend(_create_cxx_providers(ctx, outputs, snake, "c"))

    return providers

wit_bindgen_c = rule(
    impl = _wit_bindgen_c_impl,
    attrs = _wit_bindgen_common_attrs | {
        "no_helpers": attrs.bool(default = False, doc = "Skip emitting component allocation helper functions"),
        "string_encoding": attrs.option(attrs.enum(["utf8", "utf16", "latin1"]), default = None, doc = "Set component string encoding"),
    },
    doc = "Generates C bindings from WIT interface definitions using wit-bindgen"
)

def _wit_bindgen_cxx_impl(ctx: AnalysisContext) -> list[Provider]:
    snake = _world_to_snake_case(ctx.attrs.world)

    outputs = {
        "srcs": [ctx.actions.declare_output(f"{snake}.cpp")],
        "objs": [ctx.actions.declare_output(f"{snake}_component_type.o")],
        "headers": [
            ctx.actions.declare_output(f"{snake}_cpp.h"),
            ctx.actions.declare_output("wit.h")
        ],
    }

    providers = _wit_bindgen_base_impl(ctx, "cpp", outputs)
    providers.extend(_create_cxx_providers(ctx, outputs, snake, "cpp"))

    return providers

wit_bindgen_cxx = rule(
    impl = _wit_bindgen_cxx_impl,
    attrs = _wit_bindgen_common_attrs,
    doc = "Generates C++ bindings from WIT interface definitions using wit-bindgen"
)

# ============================================================================
# WIT DOCUMENTATION GENERATION
# ============================================================================

def _wit_to_markdown_impl(ctx: AnalysisContext) -> list[Provider]:
    wit_bindgen_info = ctx.attrs._wit_bindgen_toolchain[WitBindgenInfo]
    output_file = ctx.actions.declare_output("{}.md".format(ctx.label.name))

    explicit = list(ctx.attrs.wit) if ctx.attrs.wit else []
    produced = _wit_from_deps(ctx.attrs.deps) if ctx.attrs.deps else []
    all_wits = explicit + produced

    cmd = cmd_args(wit_bindgen_info.markdown)
    for w in all_wits:
        cmd.add(w)

    if ctx.attrs.world:
        cmd.add("--world")
        cmd.add(ctx.attrs.world)

    cmd.add("-o")
    cmd.add(output_file.as_output())

    ctx.actions.run(cmd, category = "wit_to_markdown")
    return [ DefaultInfo(default_output = output_file) ]

wit_to_markdown = rule(
    impl = _wit_to_markdown_impl,
    attrs = {
        "wit": attrs.list(attrs.source(), doc = "WIT files or directories to generate documentation from"),
        "deps": attrs.list(attrs.dep(), default = [], doc = "Optional targets that produce WIT artifacts"),
        "world": attrs.option(attrs.string(), default = None, doc = "Optional world name to document"),
        "_wit_bindgen_toolchain": attrs.toolchain_dep(default = "toolchains//:wit_bindgen", providers = [WitBindgenInfo]),
    },
    doc = "Generates Markdown documentation from WIT interface definitions"
)

# ============================================================================
# WASM PLUG RULE (plug components into socket) using wac
# ============================================================================

def _wasm_plug_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Create a component by plugging one or more 'plug' components into a 'socket'
    component using the `wac plug` subcommand.

    Behavior:
     - Requires at least one plug (configured dep) and a single socket (configured dep).
     - Resolves .component.wasm artifacts from the configured deps.
     - Emits a single `.component.wasm` output artifact.
    """

    socket_dep = ctx.attrs.socket
    socket_registry = ctx.attrs.socket_registry

    if socket_dep and socket_registry:
        fail("wasm_plug: specify exactly one of 'socket' or 'socket_registry' (registry name)")

    if not socket_dep and not socket_registry:
        fail("wasm_plug: one of 'socket' or 'socket_registry' (registry name) is required")

    plugs_deps = list(ctx.attrs.plugs) if ctx.attrs.plugs else []
    plugs_registry = list(ctx.attrs.plugs_registry) if ctx.attrs.plugs_registry else []

    socket_arg = None
    if socket_dep:
        socket_arg = _resolve_single_from_deps([socket_dep], _components_from_deps, "socket component")
    else:
        socket_arg = socket_registry

    # Resolve plug artifacts from deps; allow either component or core modules as a fallback
    plug_artifacts = []
    for p in plugs_deps:
        comps = _components_from_deps([p])
        if len(comps) > 0:
            plug_artifacts.extend(comps)
            continue
        mods = _wasm_modules_from_deps([p])
        if len(mods) > 0:
            plug_artifacts.extend(mods)
            continue

    output_name = ctx.attrs.output if ctx.attrs.output else "{}.component.wasm".format(ctx.label.name)
    output_file = ctx.actions.declare_output(output_name)

    wac_info = ctx.attrs._wac_toolchain[WacInfo]
    cmd = cmd_args(wac_info.plug)

    for plug in plug_artifacts + plugs_registry:
        cmd.add("--plug")
        cmd.add(plug)

    cmd.add(socket_arg)
    cmd.add("-o")
    cmd.add(output_file.as_output())

    ctx.actions.run(cmd, category = "wasm_plug")

    return [
        DefaultInfo(default_output = output_file),
        WasmInfo(
            module = None,
            component = output_file,
            wit = [],
        ),
    ]

wasm_plug = rule(
    impl = _wasm_plug_impl,
    attrs = {
        "socket": attrs.option(
            attrs.transition_dep(cfg = wasm_transition),
            doc = "Configured dep that produces the socket component (.component.wasm)",
        ),
        "socket_registry": attrs.option(
            attrs.string(),
            default = None,
            doc = "Registry package name for the socket (e.g. 'my-namespace:package-name'). Mutually exclusive with socket.",
        ),
        "plugs": attrs.list(
            attrs.transition_dep(cfg = wasm_transition),
            doc = "List of configured deps that produce plug components (or modules) to be plugged into the socket",
        ),
        "plugs_registry": attrs.list(
            attrs.string(),
            default = [],
            doc = "List of registry package names to use as plugs (e.g. ['ns:pkgA', 'ns:pkgB']). These are passed verbatim to `wac plug --plug`.",
        ),
        "output": attrs.option(
            attrs.string(),
            default = None,
            doc = "Optional output filename (relative to the rule package). If omitted a sensible default is used.",
        ),
        "_wac_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wac",
            providers = [WacInfo],
        ),
    },
    doc = "Plugs exports of plug components into the imports of a socket component using 'wac plug'",
)

def _wasm_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Download a package from a Wasm registry.

    Behavior:
     - Downloads a package specified as 'namespace:name[@version]'
     - Supports both wasm and wit output formats
     - Produces either a .wasm component or a wit directory depending on format
    """

    if not ctx.attrs.package:
        fail("wasm_package: 'package' attribute is required (e.g., 'wasi:cli' or 'wasi:http@0.2.0')")

    wkg_info = ctx.attrs._wkg_toolchain[WkgInfo]

    # Determine output format and filename
    output_format = ctx.attrs.format
    package_name = ctx.attrs.package.replace(":", "_").replace("@", "_")

    if output_format == "wit":
        # WIT format produces a directory
        output_file = ctx.actions.declare_output(package_name, dir = True)
    else:
        # WASM format (default or auto) produces a .wasm file
        if ctx.attrs.output:
            output_name = ctx.attrs.output
        else:
            output_name = "{}.wasm".format(package_name)
        output_file = ctx.actions.declare_output(output_name)

    cmd = cmd_args(wkg_info.get)
    cmd.add(ctx.attrs.package)

    # Add output path
    cmd.add("-o")
    cmd.add(output_file.as_output())

    # Add format if specified and not "auto"
    if output_format and output_format != "auto":
        cmd.add("--format")
        cmd.add(output_format)

    # Add optional flags
    if ctx.attrs.registry:
        cmd.add("--registry")
        cmd.add(ctx.attrs.registry)

    if ctx.attrs.config:
        cmd.add("--config")
        cmd.add(ctx.attrs.config)

    if ctx.attrs.cache:
        cmd.add("--cache")
        cmd.add(ctx.attrs.cache)

    ctx.actions.run(cmd, category = "wasm_package")

    # Determine what kind of WasmInfo to provide
    if output_format == "wit":
        wasm_info = WasmInfo(
            module = None,
            component = None,
            wit = [output_file],
        )
    else:
        # Assume it's a component unless we know it's a core module
        wasm_info = WasmInfo(
            module = None,
            component = output_file,
            wit = [],
        )

    return [
        DefaultInfo(default_output = output_file),
        wasm_info,
    ]

wasm_package = rule(
    impl = _wasm_package_impl,
    attrs = {
        "package": attrs.string(
            doc = "Package specification as 'namespace:name' or 'namespace:name@version' (e.g., 'wasi:cli' or 'wasi:http@0.2.0')",
        ),
        "output": attrs.option(
            attrs.string(),
            default = None,
            doc = "Optional output filename. If omitted, a default based on package name is used.",
        ),
        "format": attrs.enum(
            ["auto", "wasm", "wit"],
            default = "auto",
            doc = "Output format: 'auto' (default, detects from filename), 'wasm', or 'wit'",
        ),
        "registry": attrs.option(
            attrs.string(),
            default = None,
            doc = "Registry domain to use (overrides configuration file)",
        ),
        "config": attrs.option(
            attrs.source(),
            default = None,
            doc = "Path to configuration file",
        ),
        "cache": attrs.option(
            attrs.string(),
            default = None,
            doc = "Path to cache directory (overrides system default)",
        ),
        "_wkg_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wkg",
            providers = [WkgInfo],
        ),
    },
    doc = "Downloads a Wasm package from a registry",
)

# ============================================================================
# WIT LIBRARY (using wkg wit fetch)
# ============================================================================

def _wit_library_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Define a WIT library with automatic dependency resolution.

    Uses `wkg wit fetch` to resolve dependencies declared in the
    WIT files and produce a self-contained output directory with
    the original WIT files plus resolved deps.
    """

    wkg_info = ctx.attrs._wkg_toolchain[WkgInfo]

    # Declare output directory to hold the WIT + resolved deps
    output_dir = ctx.actions.declare_output(ctx.label.name, dir = True)

    # Build a shell script that:
    # 1. Copies source WIT files into the output directory
    # 2. Runs wkg wit fetch to resolve dependencies
    copy_parts = []
    for src in ctx.attrs.wit:
        copy_parts.append(cmd_args("cp", src, output_dir.as_output(), delimiter = " "))

    fetch_cmd = cmd_args(wkg_info.wit, "fetch", "-d", output_dir.as_output(), delimiter = " ")
    if ctx.attrs.config:
        fetch_cmd.add("--config", ctx.attrs.config)
    if ctx.attrs.cache:
        fetch_cmd.add("--cache", ctx.attrs.cache)

    script = cmd_args("/bin/sh", "-c")
    all_parts = cmd_args(delimiter = " && ")
    all_parts.add(cmd_args("mkdir", "-p", output_dir.as_output(), delimiter = " "))
    for cp in copy_parts:
        all_parts.add(cp)
    all_parts.add(fetch_cmd)
    script.add(all_parts)

    ctx.actions.run(script, category = "wit_library")

    return [
        DefaultInfo(default_output = output_dir),
        WasmInfo(
            module = None,
            component = None,
            wit = [output_dir],
        ),
    ]

wit_library = rule(
    impl = _wit_library_impl,
    attrs = {
        "wit": attrs.list(
            attrs.source(),
            doc = "WIT source files whose dependencies should be resolved",
        ),
        "config": attrs.option(
            attrs.source(),
            default = None,
            doc = "Path to wkg configuration file",
        ),
        "cache": attrs.option(
            attrs.string(),
            default = None,
            doc = "Path to cache directory (overrides system default)",
        ),
        "_wkg_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wkg",
            providers = [WkgInfo],
        ),
    },
    doc = "Defines a WIT library with automatic dependency resolution via wkg wit fetch",
)

# ============================================================================
# WASM OPT (optimize WASM modules/components using Binaryen)
# ============================================================================

def _wasm_opt_impl(ctx: AnalysisContext) -> list[Provider]:
    """Optimize a WASM module or component using wasm-opt."""
    binaryen_info = ctx.attrs._binaryen_toolchain[BinaryenInfo]

    input_file = ctx.attrs.input[DefaultInfo].default_outputs[0]
    output_file = ctx.actions.declare_output("{}.opt.wasm".format(ctx.label.name))

    cmd = cmd_args(binaryen_info.wasm_opt)
    cmd.add(input_file)

    cmd.add("-o")
    cmd.add(output_file.as_output())

    _OPT_LEVELS = {
        "o": "-O",
        "o1": "-O1",
        "o2": "-O2",
        "o3": "-O3",
        "o4": "-O4",
        "os": "-Os",
        "oz": "-Oz",
    }

    cmd.add(_OPT_LEVELS[ctx.attrs.optimization])

    for flag in ctx.attrs.extra_flags:
        cmd.add(flag)

    ctx.actions.run(cmd, category = "wasm_opt")

    # Pass through WasmInfo from the input if present
    providers = [DefaultInfo(default_output = output_file)]
    if WasmInfo in ctx.attrs.input:
        wasm_info = ctx.attrs.input[WasmInfo]
        providers.append(WasmInfo(
            module = output_file if wasm_info.module else None,
            component = output_file if wasm_info.component else None,
            wit = wasm_info.wit,
        ))

    return providers

wasm_opt = rule(
    impl = _wasm_opt_impl,
    attrs = {
        "input": attrs.dep(
            providers = [DefaultInfo],
            doc = "WASM module or component to optimize",
        ),
        "optimization": attrs.enum(
            ["o", "o1", "o2", "o3", "o4", "os", "oz"],
            default = "o",
            doc = "Optimization level (o, o1, o2, o3, o4, os, oz)",
        ),
        "extra_flags": attrs.list(
            attrs.string(),
            default = [],
            doc = "Additional flags to pass to wasm-opt",
        ),
        "_binaryen_toolchain": attrs.toolchain_dep(
            default = "toolchains//:binaryen",
            providers = [BinaryenInfo],
        ),
    },
    doc = "Optimizes a WASM module or component using Binaryen's wasm-opt",
)

# ============================================================================
# WASM COMPOSE (compose components using WAC language files)
# ============================================================================

def _wasm_compose_impl(ctx: AnalysisContext) -> list[Provider]:
    """Compose WASM components using a WAC composition file."""
    wac_info = ctx.attrs._wac_toolchain[WacInfo]

    output_name = ctx.attrs.output if ctx.attrs.output else "{}.composed.wasm".format(ctx.label.name)
    output_file = ctx.actions.declare_output(output_name)

    cmd = cmd_args(wac_info.compose)
    cmd.add(ctx.attrs.wac_file)

    # Add --dep name=artifact mappings
    for name, dep in ctx.attrs.deps.items():
        comp = _resolve_single_from_deps([dep], _components_from_deps, "compose dep '{}'".format(name))
        cmd.add("--dep")
        cmd.add(cmd_args(name, "=", comp, delimiter = ""))

    cmd.add("--output")
    cmd.add(output_file.as_output())

    ctx.actions.run(cmd, category = "wasm_compose")

    return [
        DefaultInfo(default_output = output_file),
        WasmInfo(
            module = None,
            component = output_file,
            wit = [],
        ),
    ]

wasm_compose = rule(
    impl = _wasm_compose_impl,
    attrs = {
        "wac_file": attrs.source(
            doc = "WAC composition file (.wac) describing the component graph",
        ),
        "deps": attrs.dict(
            key = attrs.string(),
            value = attrs.transition_dep(cfg = wasm_transition),
            default = {},
            doc = "Map of WAC dependency names to Buck2 targets (e.g. {'my:service': '//svc:component'})",
        ),
        "output": attrs.option(
            attrs.string(),
            default = None,
            doc = "Optional output filename. Defaults to '<name>.composed.wasm'.",
        ),
        "_wac_toolchain": attrs.toolchain_dep(
            default = "toolchains//:wac",
            providers = [WacInfo],
        ),
    },
    doc = "Composes WASM components using a WAC composition file and 'wac compose'",
)

# ============================================================================
# WASM COMPONENTIZE JS (build component from JavaScript using jco)
# ============================================================================

def _wasm_componentize_js_impl(ctx: AnalysisContext) -> list[Provider]:
    """Build a WASM component from JavaScript source using jco componentize."""
    jco_info = ctx.attrs._jco_toolchain[JcoInfo]

    output_file = ctx.actions.declare_output("{}.component.wasm".format(ctx.label.name))

    cmd = cmd_args(jco_info.componentize)
    cmd.add(ctx.attrs.src)
    cmd.add("--wit")
    cmd.add(ctx.attrs.wit)

    if ctx.attrs.world:
        cmd.add("--world-name")
        cmd.add(ctx.attrs.world)

    for feature in ctx.attrs.disable:
        cmd.add("--disable")
        cmd.add(feature)

    cmd.add("-o")
    cmd.add(output_file.as_output())

    # jco componentize uses TMPDIR for its internal StarlingMonkey working
    # directory. Buck2 may not propagate a valid TMPDIR to local actions,
    # causing jco to fail when resolving its generated index.js wrapper.
    ctx.actions.run(cmd, category = "wasm_componentize_js", env = {"TMPDIR": "/tmp"})

    return [
        DefaultInfo(default_output = output_file),
        WasmInfo(
            module = None,
            component = output_file,
            wit = [ctx.attrs.wit],
        ),
    ]

wasm_componentize_js = rule(
    impl = _wasm_componentize_js_impl,
    attrs = {
        "src": attrs.source(
            doc = "JavaScript source file to componentize",
        ),
        "wit": attrs.source(
            doc = "WIT file or directory defining the component interface",
        ),
        "world": attrs.option(
            attrs.string(),
            default = None,
            doc = "WIT world name to build (defaults to the single world in the WIT)",
        ),
        "disable": attrs.list(
            attrs.enum(["clocks", "http", "random", "stdio", "fetch-event", "all"]),
            default = [],
            doc = "WASI features to disable",
        ),
        "_jco_toolchain": attrs.toolchain_dep(
            default = "toolchains//:jco",
            providers = [JcoInfo],
        ),
    },
    doc = "Creates a WASM Component from JavaScript source using 'jco componentize'",
)

# ============================================================================
# WASM RUN / TEST RULES (using wasmtime CLI)
# ============================================================================

def _resolve_component_from_deps(deps):
    """Extract a single component or module .wasm from deps for execution."""
    components = _components_from_deps(deps)
    if len(components) == 1:
        return components[0]
    modules = _wasm_modules_from_deps(deps)
    all_wasm = components + modules
    if len(all_wasm) == 0:
        labels = [str(d.label) for d in deps]
        fail("wasm_run: no .wasm or .component.wasm found in deps {}".format(labels))
    if len(all_wasm) > 1:
        names = [a.basename for a in all_wasm]
        fail("wasm_run: found multiple wasm files: {}. Expected exactly one.".format(names))
    return all_wasm[0]

def _build_wasmtime_cmd(wasmtime_info, component_file, attrs):
    """Build a wasmtime run command from common attributes."""
    cmd = cmd_args(wasmtime_info.run)

    if attrs.wasi_inherit_env:
        cmd.add("--inherit-env")
    if attrs.wasi_inherit_network:
        cmd.add("--wasi", "inherit-network")
    for dir in attrs.wasi_dirs:
        cmd.add("--dir", dir)

    cmd.add(component_file)

    for arg in attrs.args:
        cmd.add(arg)

    return cmd

_WASMTIME_COMMON_ATTRS = {
    "args": attrs.list(
        attrs.string(),
        default = [],
        doc = "Arguments to pass to the WASM component",
    ),
    "wasi_inherit_env": attrs.bool(
        default = False,
        doc = "Inherit host environment variables in the WASI context",
    ),
    "wasi_inherit_network": attrs.bool(
        default = False,
        doc = "Allow WASI network access",
    ),
    "wasi_dirs": attrs.list(
        attrs.string(),
        default = [],
        doc = "Directories to make available to the WASI filesystem (e.g. '.::/data')",
    ),
    "_wasmtime_toolchain": attrs.toolchain_dep(
        default = "toolchains//:wasmtime",
        providers = [WasmtimeInfo],
    ),
}

def _wasm_run_impl(ctx: AnalysisContext) -> list[Provider]:
    """Run a WASM component using wasmtime CLI and capture output."""
    component_file = _resolve_component_from_deps([ctx.attrs.component])
    wasmtime_info = ctx.attrs._wasmtime_toolchain[WasmtimeInfo]

    cmd = _build_wasmtime_cmd(wasmtime_info, component_file, ctx.attrs)

    return [
        DefaultInfo(default_output = component_file),
        RunInfo(args = cmd),
    ]

wasm_run = rule(
    impl = _wasm_run_impl,
    attrs = dict({
        "component": attrs.dep(
            doc = "Component or module to run (dep producing .wasm or .component.wasm)",
        ),
    }, **_WASMTIME_COMMON_ATTRS),
    doc = "Runs a WASM component using 'wasmtime run'. Use with 'buck2 run'.",
)

def _wasm_test_impl(ctx: AnalysisContext) -> list[Provider]:
    """Test a WASM component by running it via wasmtime and checking exit code."""
    component_file = _resolve_component_from_deps([ctx.attrs.component])
    wasmtime_info = ctx.attrs._wasmtime_toolchain[WasmtimeInfo]

    cmd = _build_wasmtime_cmd(wasmtime_info, component_file, ctx.attrs)

    return [
        DefaultInfo(default_output = component_file),
        RunInfo(args = cmd),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [cmd],
        ),
    ]

wasm_test = rule(
    impl = _wasm_test_impl,
    attrs = dict({
        "component": attrs.dep(
            doc = "Component or module to test (dep producing .wasm or .component.wasm)",
        ),
    }, **_WASMTIME_COMMON_ATTRS),
    doc = "Tests a WASM component by running it with 'wasmtime run' and checking exit code. Use with 'buck2 test'.",
)
