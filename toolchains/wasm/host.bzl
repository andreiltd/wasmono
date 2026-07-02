"""Shared host platform detection helpers for toolchain rules.

Provides a single source of truth for detecting the host architecture and OS,
with configurable OS name mappings since different tools use different naming
conventions (e.g., "linux" vs "unknown-linux-musl" vs "unknown-linux-gnu").
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

def host_os(os_map: [None, dict] = None) -> str:
    """Detect the host OS, with optional name mapping.

    Args:
        os_map: Optional dict mapping canonical OS names ("linux", "macos", "windows")
                to tool-specific names. If None, returns canonical names.

    Returns:
        The OS string, mapped through os_map if provided.
    """
    os = host_info().os
    if os.is_linux:
        key = "linux"
    elif os.is_macos:
        key = "macos"
    elif os.is_windows:
        key = "windows"
    else:
        fail("Unsupported host OS.")

    if os_map:
        expect(key in os_map, "No OS mapping for '{}'. Available: {}", key, ", ".join(os_map.keys()))
        return os_map[key]
    return key

def host_platform(
        arch: [None, str] = None,
        os: [None, str] = None,
        os_map: [None, dict] = None) -> (str, str):
    if arch == None:
        arch = host_arch()
    if os == None:
        os = host_os(os_map)
    return arch, os
