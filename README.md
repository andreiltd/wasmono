# Wasmono

Buck2 rules for building WebAssembly components.

> ⚠️ **Experimental**: The structure and APIs are going to change to better support usage as a Buck2 
[external cell](https://buck2.build/docs/users/advanced/external_cells/). Currently, this is a collection 
of experiments and patterns for WASM component development with Buck2.

See also similar rules for bazel: https://github.com/pulseengine/rules_wasm_component

## Quick Start

```bash
cargo +nightly-2025-06-20 install --git https://github.com/facebook/buck2.git buck2

# Run the example validator
buck2 run //examples/validator/runner:validator -- "Hello World"
buck2 run //examples/validator/runner:validator -- "Hello#World"
```

## Features

- **Component Building**: Create WASM components from Rust, C, and C++
- **WIT Bindings**: Generate language bindings from WIT definitions
- **Composition**: Link, plug, and compose components together (via WAC)
- **Package Management**: Fetch components from WASM registries
- **Optimization**: Run wasm-opt (Binaryen) on modules
- **JavaScript Components**: Build components from JavaScript (via jco)

## Using as an External Cell

Wasmono can be used as a [git external cell](https://buck2.build/docs/users/advanced/external_cells/#the-git-origin) in other Buck2 projects.

### 1. Configure `.buckconfig`

```ini
[cells]
  root = .
  wasmono = wasmono
  toolchains = toolchains
  prelude = prelude
  none = none

[cell_aliases]
  config = prelude
  ovr_config = prelude
  fbcode = none
  fbsource = none
  fbcode_macros = none
  buck = none

[external_cells]
  prelude = bundled
  wasmono = git

[external_cell_wasmono]
  git_origin = https://github.com/andreiltd/wasmono.git
  commit_hash = <sha1>

[build]
  execution_platforms = prelude//platforms:default

[parser]
  target_platform_detector_spec = target:root//...->prelude//platforms:default
```

Create an empty `none/BUCK` file (required by cell aliases).

### 2. Set up `toolchains/BUCK`

The wasmono rules reference `toolchains//:wasm_tools`, `toolchains//:wit_bindgen`, etc.
You must define these targets in your own `toolchains/BUCK`. The `wasm_demo_toolchains()`
macro creates all WASM toolchain targets with sensible defaults:

```python
load("@prelude//toolchains:cxx.bzl", "system_cxx_toolchain")
load("@prelude//toolchains:genrule.bzl", "system_genrule_toolchain")
load("@prelude//toolchains:python.bzl", "system_python_bootstrap_toolchain")
load("@prelude//toolchains:rust.bzl", "system_rust_toolchain")
load("@wasmono//toolchains/wasm:demo.bzl", "wasm_demo_toolchains")
load("@wasmono//toolchains/cxx/wasi:defs.bzl", "download_wasi_sdk", "cxx_wasi_toolchain")

_DEFAULT_TRIPLE = select({
    "config//os:wasi": select({
        "config//cpu:wasm32": "wasm32-wasip2",
    }),
    "config//os:linux": select({
        "config//cpu:arm64": "aarch64-unknown-linux-gnu",
        "config//cpu:x86_64": "x86_64-unknown-linux-gnu",
    }),
    "config//os:macos": select({
        "config//cpu:arm64": "aarch64-apple-darwin",
        "config//cpu:x86_64": "x86_64-apple-darwin",
    }),
})

system_genrule_toolchain(name = "genrule", visibility = ["PUBLIC"])
system_cxx_toolchain(name = "cxx", visibility = ["PUBLIC"])
system_python_bootstrap_toolchain(name = "python_bootstrap", visibility = ["PUBLIC"])

system_rust_toolchain(
    name = "rust",
    default_edition = "2024",
    rustc_target_triple = _DEFAULT_TRIPLE,
    visibility = ["PUBLIC"],
)

# WASM toolchains
wasm_demo_toolchains()

download_wasi_sdk(name = "wasi_sdk", version = "27.0")
cxx_wasi_toolchain(name = "cxx_wasi", distribution = ":wasi_sdk", visibility = ["PUBLIC"])
```

### 3. Add `platforms/BUCK`

```python
platform(
    name = "wasm32_wasi",
    constraint_values = [
        "config//cpu/constraints:wasm32",
        "config//os/constraints:wasi",
    ],
)
```

### 4. Use the rules

```python
load("@wasmono//toolchains/wasm:component.bzl", "wasm_component", "wasm_compose")
```

## Build a Component

```python
load("@toolchains//wasm:component.bzl", "wasm_component")

# Build the Rust binary with WASM target
rust_binary(
    name = "regex",
    crate = "regex",
    crate_root = "src/lib.rs",
    edition = "2024",
    srcs = glob(["src/**/*.rs"]) + glob(["wit/**/*.wit"]),
    deps = [
        "//third-party:regex",
        "//third-party:wit-bindgen",
    ],
)

# Promote output of regex to wasm component
wasm_component(
    name = "regex_component",
    module = ":regex",
    wit = "wit/regex.wit",
    visibility = ['PUBLIC'],
)
```

## Available Rules

### Component Rules

- `wasm_component` - Create component from WASM module + WIT
- `wasm_component_link` - Link multiple components
- `wasm_plug` - Compose components using plug pattern
- `wasm_compose` - Compose components using WAC composition files
- `wasm_validate` - Validate WASM binaries
- `wasm_print` - Convert WASM to text format
- `wasm_opt` - Optimize WASM modules with Binaryen

### Binding Generation

- `wit_bindgen_rust` - Generate Rust bindings
- `wit_bindgen_c` - Generate C bindings
- `wit_bindgen_cxx` - Generate C++ bindings
- `wit_to_markdown` - Generate documentation

### JavaScript

- `wasm_componentize_js` - Build component from JavaScript (via jco)

### Package Management

- `wasm_package` - Download packages from registries

## Example: Multi-Component App

```python
# Regex component (Rust)
rust_binary(
    name = "regex_lib",
    srcs = glob(["src/**/*.rs"]),
)

wasm_component(
    name = "regex_component",
    module = ":regex_lib",
    wit = "wit/regex.wit",
)

# Validator component (C++)
wit_bindgen_cxx(
    name = "validator_bindings",
    world = "validator",
    wit = ["wit/validator.wit"],
)

cxx_binary(
    name = "validator",
    srcs = ["src/validator.cpp"],
    deps = [":validator_bindings"],
)

wasm_component(
    name = "validator_component",
    module = ":validator",
    wit = "wit/validator.wit",
)

# Compose: plug regex into validator
wasm_plug(
    name = "app",
    socket = ":validator_component",
    plugs = [":regex_component"],
)
```

## Toolchains

All toolchains are **hermetic** - they download specific versions of tools rather than relying on system installations. This ensures reproducible builds across different environments.

Each toolchain is composed of two parts:

1. **Distribution**: Downloads and extracts the tool binary
2. **Toolchain**: Provides convenient wrappers and subcommands

This separation makes it easy to control tool sources and versions:

```python
# Download the distribution
download_wasm_tools(
    name = "wasm_tools_dist",
    version = "1.239.0",
)

# Create toolchain from distribution
wasm_tools_toolchain(
    name = "wasm_tools",
    distribution = ":wasm_tools_dist",
    visibility = ["PUBLIC"],
)
```

Available toolchains:

- **wasm-tools** - Component manipulation (https://github.com/bytecodealliance/wasm-tools)
- **wit-bindgen** - Binding generation (https://github.com/bytecodealliance/wit-bindgen)
- **wac** - Component composition (https://github.com/bytecodealliance/wac)
- **wkg** - Package management (https://github.com/bytecodealliance/wasm-pkg-tools)
- **wasi-sdk** - C/C++ wasi toolchain (https://github.com/WebAssembly/wasi-sdk)
- **binaryen** - WASM optimizer / wasm-opt (https://github.com/WebAssembly/binaryen)
- **jco** - JavaScript component toolchain (system install, https://github.com/bytecodealliance/jco)
