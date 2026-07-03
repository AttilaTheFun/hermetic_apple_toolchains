"""Repository rule vendoring a set of Apple platform SDKs for one OS release.

The resulting repository contains:

    SDKs/<PlatformName><Version>.sdk    One entry per registered platform.
    sdk_info.json                       Platform -> {name, version} metadata.

SDKs can be sourced from local paths (for example inside an extracted
Xcode.app) or from archives that your organization re-hosts.
"""

load(
    ":utils.bzl",
    "APPLE_SLA_ENV",
    "SDK_PLATFORMS",
    "read_sdk_settings",
    "require_apple_sla",
)

_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(["MARKER"])
"""

def _place_sdk(rctx, platform, sdk_path):
    """Symlinks or names one SDK into SDKs/ under its canonical name."""
    settings = read_sdk_settings(rctx, sdk_path)
    version = settings.get("Version")
    if not version:
        fail("SDK at {} has no Version in SDKSettings.plist".format(sdk_path))
    canonical = "{}{}.sdk".format(SDK_PLATFORMS[platform], version)
    rctx.symlink(sdk_path, "SDKs/" + canonical)
    return {"name": canonical, "version": version}

def _apple_sdk_repository_impl(rctx):
    require_apple_sla(rctx, "the Apple platform SDKs")

    for platform in list(rctx.attr.paths.keys()) + list(rctx.attr.urls.keys()):
        if platform not in SDK_PLATFORMS:
            fail("apple.sdk(name = {}): unknown platform {}; expected one of {}".format(
                repr(rctx.attr.name),
                repr(platform),
                ", ".join(sorted(SDK_PLATFORMS.keys())),
            ))

    info = {}
    for platform, path in rctx.attr.paths.items():
        sdk_path = rctx.path(path)
        if not sdk_path.exists:
            fail("apple.sdk(name = {}): path {} does not exist".format(
                repr(rctx.attr.name),
                path,
            ))
        info[platform] = _place_sdk(rctx, platform, sdk_path)

    for platform, url in rctx.attr.urls.items():
        output = "downloads/" + platform
        rctx.download_and_extract(
            url = url,
            output = output,
            sha256 = rctx.attr.sha256s.get(platform, ""),
            stripPrefix = rctx.attr.strip_prefixes.get(platform, ""),
        )

        # The archive may either be the .sdk directory itself (after
        # strip_prefix) or contain exactly one .sdk directory.
        extracted = rctx.path(output)
        if extracted.get_child("SDKSettings.plist").exists:
            sdk_path = extracted
        else:
            sdks = [
                entry
                for entry in extracted.readdir()
                if entry.basename.endswith(".sdk")
            ]
            if len(sdks) != 1:
                fail("apple.sdk(name = {}): expected one .sdk in archive for {}".format(
                    repr(rctx.attr.name),
                    platform,
                ))
            sdk_path = sdks[0]
        info[platform] = _place_sdk(rctx, platform, sdk_path)

    if not info:
        fail("apple.sdk(name = {}): no SDKs registered; use paths or urls".format(
            repr(rctx.attr.name),
        ))

    rctx.file("sdk_info.json", json.encode_indent(info) + "\n")
    rctx.file("MARKER", "")
    rctx.file("BUILD.bazel", _BUILD)

apple_sdk_repository = repository_rule(
    doc = "Vendors a set of Apple platform SDKs for one OS release.",
    environ = [APPLE_SLA_ENV],
    implementation = _apple_sdk_repository_impl,
    attrs = {
        "paths": attr.string_dict(
            doc = "Platform key (e.g. iphoneos, iphonesimulator) to absolute .sdk path.",
        ),
        "urls": attr.string_dict(
            doc = "Platform key to archive URL containing the .sdk.",
        ),
        "sha256s": attr.string_dict(
            doc = "Platform key to SHA-256 for the corresponding url.",
        ),
        "strip_prefixes": attr.string_dict(
            doc = "Platform key to archive prefix to strip.",
        ),
    },
)
