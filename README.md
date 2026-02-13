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

Wasmono can be used as a [git external cell](https://buck2.build/docs/users/advanced/external_cells/#the-git-origin) in other Buck2 projects. Add the following to your `.buckconfig`:

```ini
[cells]
  root = .
  wasmono = wasmono
  toolchains = wasmono/toolchains
  prelude = prelude

[external_cells]
  prelude = bundled
  wasmono = git

[external_cell_wasmono]
  git_origin = https://github.com/<org>/wasmono.git
  commit_hash = <sha1>
```

> **Note**: The `toolchains = wasmono/toolchains` cell mapping is required because
> the built-in rules reference toolchain targets as `toolchains//:wasm_tools`, etc.
> Replace `git_origin` and `commit_hash` with the actual repository URL and commit SHA.

Then use the rules in your BUCK files:

```python
load("@toolchains//wasm:component.bzl", "wasm_component", "wasm_compose")
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
