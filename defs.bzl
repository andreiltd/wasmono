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
load("//toolchains/wasm:host.bzl", _host_arch = "host_arch", _host_os = "host_os")
load(
    "//toolchains/wasm:node.bzl",
    _download_node = "download_node",
    _node_toolchain = "node_toolchain",
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
load(
    "//toolchains/wasm:jco.bzl",
    _JcoInfo = "JcoInfo",
    _install_jco = "install_jco",
    _jco_toolchain = "jco_toolchain",
    _system_jco_toolchain = "system_jco_toolchain",
)
load("//toolchains/wasm:demo.bzl", _wasm_demo_toolchains = "wasm_demo_toolchains")
load(
    "//toolchains/wasm:tools.bzl",
    _download_wasm_tools = "download_wasm_tools",
    _wasm_tools_toolchain = "wasm_tools_toolchain",
)
load(
    "//toolchains/wasm:transition.bzl",
    _wasm_transition = "wasm_transition",
    _wasm_transition_for_wasi = "wasm_transition_for_wasi",
    _wasm_transition_p1 = "wasm_transition_p1",
)

WasmInfo = _WasmInfo
WitBindingInfo = _WitBindingInfo
JcoInfo = _JcoInfo
assemblyscript_binary = _assemblyscript_binary
asc_toolchain = _asc_toolchain
cxx_wasi_toolchain = _cxx_wasi_toolchain
download_node = _download_node
download_wasm_tools = _download_wasm_tools
download_wasi_sdk = _download_wasi_sdk
host_arch = _host_arch
host_os = _host_os
install_asc = _install_asc
install_jco = _install_jco
jco_toolchain = _jco_toolchain
node_toolchain = _node_toolchain
system_jco_toolchain = _system_jco_toolchain
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
wasm_tools_toolchain = _wasm_tools_toolchain
wasm_transition = _wasm_transition
wasm_transition_for_wasi = _wasm_transition_for_wasi
wasm_transition_p1 = _wasm_transition_p1
wasm_validate = _wasm_validate
wasm_weval = _wasm_weval
wasm_wizer = _wasm_wizer
wit_bindgen_c = _wit_bindgen_c
wit_bindgen_cxx = _wit_bindgen_cxx
wit_bindgen_rust = _wit_bindgen_rust
wit_library = _wit_library
wit_to_markdown = _wit_to_markdown
