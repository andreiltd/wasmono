"""Shared host platform detection helpers for toolchain rules.

Provides a single source of truth for detecting the canonical host architecture
and OS, plus an explicit helper for mapping canonical OS names to tool-specific
release names (e.g., "linux" vs "unknown-linux-musl" vs "unknown-linux-gnu").
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
