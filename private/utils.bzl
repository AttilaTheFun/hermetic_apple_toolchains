"""Shared helpers for hermetic Apple toolchain repository rules."""

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
