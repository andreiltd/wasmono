load(
    "//toolchains/cxx/wasi:defs.bzl",
    _cxx_wasi_toolchain = "cxx_wasi_toolchain",
    _download_wasi_sdk = "download_wasi_sdk",
)
load(
    "//toolchains/wasm:assemblyscript.bzl",
    _asc_toolchain = "asc_toolchain",
    _assemblyscript_binary = "assemblyscript_binary",
    _install_asc = "install_asc",
)
load(
    "//toolchains/wasm:component.bzl",
    _WasmInfo = "WasmInfo",
    _WitBindingInfo = "WitBindingInfo",
    _wasm_component = "wasm_component",
    _wasm_component_link = "wasm_component_link",
    _wasm_componentize_js = "wasm_componentize_js",
    _wasm_compose = "wasm_compose",
    _wasm_jco_run = "wasm_jco_run",
    _wasm_opt = "wasm_opt",
    _wasm_package = "wasm_package",
    _wasm_plug = "wasm_plug",
    _wasm_print = "wasm_print",
    _wasm_run = "wasm_run",
    _wasm_test = "wasm_test",
    _wasm_validate = "wasm_validate",
    _wasm_weval = "wasm_weval",
    _wasm_wizer = "wasm_wizer",
    _wit_bindgen_c = "wit_bindgen_c",
    _wit_bindgen_cxx = "wit_bindgen_cxx",
    _wit_bindgen_rust = "wit_bindgen_rust",
    _wit_library = "wit_library",
    _wit_to_markdown = "wit_to_markdown",
)
load("//toolchains/wasm:demo.bzl", _wasm_demo_toolchains = "wasm_demo_toolchains")

WasmInfo = _WasmInfo
WitBindingInfo = _WitBindingInfo
assemblyscript_binary = _assemblyscript_binary
asc_toolchain = _asc_toolchain
cxx_wasi_toolchain = _cxx_wasi_toolchain
download_wasi_sdk = _download_wasi_sdk
install_asc = _install_asc
wasm_component = _wasm_component
wasm_component_link = _wasm_component_link
wasm_componentize_js = _wasm_componentize_js
wasm_compose = _wasm_compose
wasm_demo_toolchains = _wasm_demo_toolchains
wasm_jco_run = _wasm_jco_run
wasm_opt = _wasm_opt
wasm_package = _wasm_package
wasm_plug = _wasm_plug
wasm_print = _wasm_print
wasm_run = _wasm_run
wasm_test = _wasm_test
wasm_validate = _wasm_validate
wasm_weval = _wasm_weval
wasm_wizer = _wasm_wizer
wit_bindgen_c = _wit_bindgen_c
wit_bindgen_cxx = _wit_bindgen_cxx
wit_bindgen_rust = _wit_bindgen_rust
wit_library = _wit_library
wit_to_markdown = _wit_to_markdown
