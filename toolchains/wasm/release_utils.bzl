load("@prelude//utils:expect.bzl", "expect")

def _overlay_releases(releases: dict, custom_releases: [None, dict]) -> dict:
    if custom_releases == None:
        return releases

    all_releases = dict(releases)
    all_releases.update(custom_releases)
    return all_releases

def get_release_version(
        releases: dict,
        version: str,
        *,
        custom_releases: [None, dict] = None,
        tool_name: str) -> dict:
    all_releases = _overlay_releases(releases, custom_releases)

    expect(
        version in all_releases,
        "Unknown {} release version '{}'. Available versions: {}",
        tool_name,
        version,
        ", ".join(all_releases.keys()),
    )

    return all_releases[version]

def get_release(
        releases: dict,
        version: str,
        platform: str,
        *,
        custom_releases: [None, dict] = None,
        tool_name: str) -> dict:
    version_releases = get_release_version(
        releases,
        version,
        custom_releases = custom_releases,
        tool_name = tool_name,
    )
    expect(
        platform in version_releases,
        "Unsupported platform '{}'. Supported platforms: {}",
        platform,
        ", ".join(version_releases.keys()),
    )

    return version_releases[platform]
