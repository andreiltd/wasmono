"""Shared host platform detection helpers for toolchain rules.

Provides a single source of truth for detecting the canonical host architecture
and OS, plus an explicit helper for mapping canonical OS names to tool-specific
release names (e.g., "linux" vs "unknown-linux-musl" vs "unknown-linux-gnu").
Native npm installations use matching target and execution constraints so their
runtime-native dependencies stay on the platform that will consume them.
"""

load("@prelude//utils:expect.bzl", "expect")

def host_arch() -> str:
    """Detect the host CPU architecture.

    Returns:
        "x86_64" or "aarch64"
    """
    arch = host_info().arch
    if arch.is_x86_64:
        return "x86_64"
    elif arch.is_aarch64:
        return "aarch64"
    else:
        fail("Unsupported host architecture.")

def host_os() -> str:
    """Detect the canonical host OS.

    Returns:
        "linux", "macos", or "windows"
    """
    os = host_info().os
    if os.is_linux:
        return "linux"
    elif os.is_macos:
        return "macos"
    elif os.is_windows:
        return "windows"
    else:
        fail("Unsupported host OS.")

def host_platform(
        arch: [None, str] = None,
        os: [None, str] = None) -> (str, str):
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os()
    return arch, os

def map_os(os: str, os_map: dict) -> str:
    expect(os in os_map, "No OS mapping for '{}'. Available: {}", os, ", ".join(os_map.keys()))
    return os_map[os]

def platform_constraints(arch: str, os: str) -> list[str]:
    cpus = {"aarch64": "arm64", "x86_64": "x86_64"}
    expect(arch in cpus, "Unsupported execution architecture '{}'", arch)
    expect(os in ["linux", "macos", "windows"], "Unsupported execution OS '{}'", os)
    return ["prelude//cpu:" + cpus[arch], "prelude//os:" + os]

def native_execution_compatible_with():
    """Execute native installations on the same OS/CPU as their target."""
    return select({
        "prelude//cpu:arm64": ["prelude//cpu:arm64"],
        "prelude//cpu:x86_64": ["prelude//cpu:x86_64"],
        "DEFAULT": ["prelude//:none"],
    }) + select({
        "prelude//os:linux": ["prelude//os:linux"],
        "prelude//os:macos": ["prelude//os:macos"],
        "prelude//os:windows": ["prelude//os:windows"],
        "DEFAULT": ["prelude//:none"],
    })
