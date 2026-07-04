"""Shared helpers for hermetic Apple toolchain repository rules."""

APPLE_SLA_ENV = "ACCEPTED_APPLE_SLA"

# Maps lowercase SDK platform keys to the capitalized platform directory
# names Apple uses on disk (for example `iPhoneOS.platform`).
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

def require_apple_sla(rctx, what):
    """Fails unless the user has declared acceptance of Apple's license terms.

    Apple's software license agreements do not permit redistributing Xcode or
    the platform SDKs to parties who have not accepted them. Users of this
    module must have accepted the relevant agreements and may only point
    these repositories at copies they are licensed to use, such as mirrors
    they host for their own organization.

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
