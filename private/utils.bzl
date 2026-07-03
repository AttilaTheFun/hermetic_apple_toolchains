"""Shared helpers for hermetic Apple toolchain repository rules."""

APPLE_SLA_ENV = "ACCEPTED_APPLE_SLA"

# Maps the lowercase SDK platform keys accepted by the `apple.sdk` tag class to
# the capitalized platform directory names Apple uses on disk (for example
# `iPhoneOS.platform` and `iPhoneOS26.5.sdk`).
SDK_PLATFORMS = {
    "appletvos": "AppleTVOS",
    "appletvsimulator": "AppleTVSimulator",
    "driverkit": "DriverKit",
    "iphoneos": "iPhoneOS",
    "iphonesimulator": "iPhoneSimulator",
    "macosx": "MacOSX",
    "watchos": "WatchOS",
    "watchsimulator": "WatchSimulator",
    "xros": "XROS",
    "xrsimulator": "XRSimulator",
}

# Maps SDK platform keys to the xcode_version attribute that records the
# default SDK version for that platform's OS.
_PLATFORM_TO_SDK_VERSION_ATTR = {
    "appletvos": "default_tvos_sdk_version",
    "iphoneos": "default_ios_sdk_version",
    "macosx": "default_macos_sdk_version",
    "watchos": "default_watchos_sdk_version",
    "xros": "default_visionos_sdk_version",
}

def require_apple_sla(rctx, what):
    """Fails unless the user has declared acceptance of Apple's license terms.

    Apple's software license agreements do not permit redistributing Xcode, the
    Command Line Tools, or the platform SDKs to parties who have not accepted
    them. Users of this module must have accepted the relevant agreements (for
    example by installing Xcode once) and may only point these repositories at
    copies they are licensed to use, such as mirrors they host for their own
    organization.

    Args:
        rctx: The repository context.
        what: Human readable name of the artifact being fetched.
    """
    if rctx.os.environ.get(APPLE_SLA_ENV) != "1":
        fail("""
Downloading or vendoring {what} requires accepting Apple's software license
agreement (https://www.apple.com/legal/sla/). If you have accepted the
agreement, add this to your .bazelrc:

    common --repo_env={env}=1

Note that Apple's license terms do not allow redistributing these artifacts
publicly; only re-host copies for use within your own organization.
""".format(what = what, env = APPLE_SLA_ENV))

def read_sdk_settings(rctx, sdk_path):
    """Reads SDKSettings.plist from an SDK and returns its decoded JSON dict.

    Args:
        rctx: The repository context.
        sdk_path: A `path` object for a `.sdk` directory.

    Returns:
        The decoded SDKSettings dictionary.
    """
    plist = sdk_path.get_child("SDKSettings.plist")
    if not plist.exists:
        fail("{} does not look like an SDK: missing SDKSettings.plist".format(sdk_path))
    result = rctx.execute([
        "/usr/bin/plutil",
        "-convert",
        "json",
        "-o",
        "-",
        str(plist),
    ])
    if result.return_code != 0:
        fail("Failed to read {}: {}".format(plist, result.stderr))
    return json.decode(result.stdout)

def sdk_version_attrs_from_info(sdk_info):
    """Converts an sdk_info dict into xcode_version default SDK version attrs.

    Args:
        sdk_info: A dict of platform key -> {"version": ...} as written to
            sdk_info.json by the artifact repository rules.

    Returns:
        A dict of xcode_version attribute name -> version string.
    """
    attrs = {}
    for platform, info in sdk_info.items():
        attr_name = _PLATFORM_TO_SDK_VERSION_ATTR.get(platform)
        if attr_name and info.get("version"):
            attrs[attr_name] = info["version"]
    return attrs

def repo_root_from_marker(rctx, marker_label):
    """Returns the absolute path of the repository containing marker_label."""
    return rctx.path(marker_label).dirname
