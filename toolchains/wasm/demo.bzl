"""Default WASM toolchains for quick setup.

Usage in `toolchains/BUCK` (standalone):

```bzl
load("//wasm:demo.bzl", "wasm_demo_toolchains")
load("//cxx/wasi:defs.bzl", "download_wasi_sdk", "cxx_wasi_toolchain")

wasm_demo_toolchains()

download_wasi_sdk(name = "wasi_sdk", version = "27.0")
cxx_wasi_toolchain(name = "cxx_wasi", distribution = ":wasi_sdk", visibility = ["PUBLIC"])
```

Usage in `toolchains/BUCK` (external cell):

```bzl
load("@wasmono//toolchains/wasm:demo.bzl", "wasm_demo_toolchains")
load("@wasmono//toolchains/cxx/wasi:defs.bzl", "download_wasi_sdk", "cxx_wasi_toolchain")

wasm_demo_toolchains()

download_wasi_sdk(name = "wasi_sdk", version = "27.0")
cxx_wasi_toolchain(name = "cxx_wasi", distribution = ":wasi_sdk", visibility = ["PUBLIC"])
```

This creates all the WASM-related toolchain targets that wasmono rules expect:
`node`, `wasm_tools`, `wit_bindgen`, `wac`, `wkg`, `jco`, `binaryen`, and
`wasmtime`. The `cxx_wasi` toolchain must be added separately (shown above)
because it requires its own `download_wasi_sdk` call.
"""

load(":assemblyscript.bzl", "asc_toolchain", "install_asc")
load(":binaryen.bzl", "binaryen_toolchain", "download_binaryen")
load(":bindgen.bzl", "download_wit_bindgen", "wit_bindgen_toolchain")
load(":jco.bzl", "install_jco", "jco_toolchain", "system_jco_toolchain")
load(":tools.bzl", "download_wasm_tools", "wasm_tools_toolchain")
load(":wac.bzl", "download_wac", "wac_toolchain")
load(":wasmtime.bzl", "download_wasmtime", "wasmtime_toolchain")
load(":wkg.bzl", "download_wkg", "wkg_toolchain")
load(":node.bzl", "download_node", "node_toolchain")

def wasm_demo_toolchains(
        wasm_tools_version = "1.245.1",
        wit_bindgen_version = "0.53.0",
        wac_version = "0.9.0",
        wkg_version = "0.13.0",
        binaryen_version = "125",
        wasmtime_version = "42.0.1",
        node_version = "20.18.0",
        jco_version = "1.17.0",
        asc_version = None):
    """Create WASM toolchain targets with sensible defaults.

    Note: `cxx_wasi` must be added separately — see module docstring.

    Args:
        wasm_tools_version: Version of wasm-tools to download.
        wit_bindgen_version: Version of wit-bindgen to download.
        wac_version: Version of WAC to download.
        wkg_version: Version of wkg to download.
        binaryen_version: Version of Binaryen to download.
        wasmtime_version: Version of Wasmtime CLI to download.
        node_version: Version of Node.js to download for hermetic jco/asc.
            Set to None to use system jco instead (non-hermetic).
        jco_version: Version of jco to install via npm. Only used when
            node_version is set.
        asc_version: Version of AssemblyScript compiler to install via npm.
            Only used when node_version is set. If None, asc is not installed.
    """
    download_wasm_tools(name = "wasm_tools_dist", version = wasm_tools_version)
    wasm_tools_toolchain(name = "wasm_tools", distribution = ":wasm_tools_dist", visibility = ["PUBLIC"])

    download_wit_bindgen(name = "wit_bindgen_dist", version = wit_bindgen_version)
    wit_bindgen_toolchain(name = "wit_bindgen", distribution = ":wit_bindgen_dist", visibility = ["PUBLIC"])

    download_wac(name = "wac_dist", version = wac_version)
    wac_toolchain(name = "wac", distribution = ":wac_dist", visibility = ["PUBLIC"])

    download_wkg(name = "wkg_dist", version = wkg_version)
    wkg_toolchain(name = "wkg", distribution = ":wkg_dist", visibility = ["PUBLIC"])

    # jco — hermetic if node_version is set, otherwise system
    if node_version != None:
        download_node(name = "node_dist", version = node_version)
        node_toolchain(name = "node", distribution = ":node_dist", visibility = ["PUBLIC"])

        install_jco(name = "jco_dist", version = jco_version, node = ":node_dist")
        jco_toolchain(name = "jco", distribution = ":jco_dist", visibility = ["PUBLIC"])

        # asc — optional, only when asc_version is explicitly set
        if asc_version != None:
            install_asc(name = "asc_dist", version = asc_version, node = ":node_dist")
            asc_toolchain(name = "asc", distribution = ":asc_dist", visibility = ["PUBLIC"])
    else:
        system_jco_toolchain(name = "jco", visibility = ["PUBLIC"])

    download_binaryen(name = "binaryen_dist", version = binaryen_version)
    binaryen_toolchain(name = "binaryen", distribution = ":binaryen_dist", visibility = ["PUBLIC"])

    download_wasmtime(name = "wasmtime_dist", version = wasmtime_version)
    wasmtime_toolchain(name = "wasmtime", distribution = ":wasmtime_dist", visibility = ["PUBLIC"])
