"""Re-export Node.js toolchain from wasm package.

The canonical location is `//wasm:node.bzl`. This file exists for
backward compatibility with `//node:defs.bzl` imports.
"""

load(
    "//wasm:node.bzl",
    _NodeInfo = "NodeInfo",
    _download_node = "download_node",
    _node_toolchain = "node_toolchain",
)

NodeInfo = _NodeInfo
download_node = _download_node
node_toolchain = _node_toolchain
