"""Repository rule vendoring a hermetic, verbatim Xcode.app.

The repository contains a single `Xcode.app` — an *unmodified* copy of a real
Xcode distribution, either symlinked from a local path or extracted from an
archive that your organization re-hosts. Keeping the bundle verbatim is
deliberate: it preserves Apple's notarized seal, so Gatekeeper's first-launch
evaluation takes the fast path, and every tool (including xcodebuild and the
Interface Builder / asset catalog tools, which resolve their platform support
relative to the app bundle containing their own binary) behaves exactly as in
a normal installation.

The repository defines an `xcode_version` target whose `version` is the
absolute path of `Xcode.app/Contents/Developer`. Passing a path instead of a
version number makes Bazel use it directly as `DEVELOPER_DIR` (and resolve
`SDKROOT` against it) when running actions, bypassing discovery of installed
Xcodes entirely.

Because the developer directory is Xcode.app-style, `xcrun` enforces Apple's
license acceptance (recorded system-wide, keyed by the agreement revision in
the app's `Contents/Resources/LicenseInfo.plist`). The generated
`:accept_license` runnable performs the one-time `sudo xcodebuild -license
accept` per machine and agreement revision.
"""

load(
    ":utils.bzl",
    "SDK_PLATFORMS",
    "read_sdk_settings",
)

_BUILD_TEMPLATE = """\
load("@apple_support//xcode:xcode_version.bzl", "xcode_version")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

package(default_visibility = ["//visibility:public"])

xcode_version(
    name = "version",
    version = {version},
    aliases = {aliases},
{sdk_version_attrs})

# Accepts the Xcode license for this Xcode (requires sudo; prompts for your
# password). Needed once per machine and license agreement revision before
# building with this Xcode.
sh_binary(
    name = "accept_license",
    srcs = ["accept_license.sh"],
)

# `--run_under` wrapper that runs a command with DEVELOPER_DIR pointing at
# this Xcode, so that `bazel run` launchers (for example rules_apple's
# simulator runner, which consults `xcode-select -p`) use the hermetic Xcode
# instead of whatever the host has selected.
sh_binary(
    name = "with_developer_dir",
    srcs = ["with_developer_dir.sh"],
)

# Installs this Xcode's system support components (CoreSimulator framework
# and friends) via `xcodebuild -runFirstLaunch` (requires sudo). Needed on
# machines that have never installed an Xcode of this generation — in
# particular, running *beta* simulator runtimes requires the beta's
# CoreSimulator system components.
sh_binary(
    name = "first_launch",
    srcs = ["first_launch.sh"],
)

# Opens this Xcode's GUI.
sh_binary(
    name = "open",
    srcs = ["open_xcode.sh"],
)
"""

_OPEN_TEMPLATE = """\
#!/bin/bash
exec /usr/bin/open "{app}"
"""

_FIRST_LAUNCH_TEMPLATE = """\
#!/bin/bash
#
# Installs the Xcode system support components (CoreSimulator framework and
# friends) for the hermetic Xcode at {app}, system-wide (requires sudo).

set -euo pipefail

APP="{app}"
DEV="$APP/Contents/Developer"
PKG="$APP/Contents/Resources/Packages/XcodeSystemResources.pkg"

# `xcodebuild -runFirstLaunch` reports "nothing to do" as long as *some*
# generation of the system components is installed, so it never upgrades
# them — but booting this Xcode's (beta) simulator runtimes requires *its*
# CoreSimulator, or boots fail with "runtime path not found". Compare the
# installed package version with the one this Xcode ships and install the
# shipped package directly when it is newer.
shipped=$(cd "$(mktemp -d)" && /usr/bin/xar -xf "$PKG" PackageInfo && \\
    grep -o 'version="[0-9][0-9.]*"' PackageInfo | grep -o '[0-9][0-9.]*' | sort -V | tail -1)
installed=$(pkgutil --pkg-info com.apple.pkg.XcodeSystemResources 2>/dev/null | \\
    sed -n 's/^version: //p')
installed="${{installed:-0}}"

if [[ "$(printf '%s\\n%s\\n' "$shipped" "$installed" | sort -V | tail -1)" == "$installed" ]]; then
  echo "Xcode system support components $installed are already installed" \\
      "(this Xcode ships $shipped)."
  exit 0
fi

echo "Installing Xcode system support components $shipped (installed: $installed)."
echo "This records system-wide state and requires sudo."

if [[ ! -t 0 ]]; then
  echo ""
  echo "No terminal is attached, so sudo cannot prompt for your password."
  echo "Run this from a terminal instead:"
  echo ""
  echo "    sudo /usr/sbin/installer -pkg '$PKG' -target /"
  exit 1
fi

sudo /usr/sbin/installer -pkg "$PKG" -target /

# Restart CoreSimulatorService so running simulators pick up the new
# CoreSimulator framework.
sudo pkill -f com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true

exec sudo env DEVELOPER_DIR="$DEV" "$DEV/usr/bin/xcodebuild" -runFirstLaunch
"""

_WITH_DEVELOPER_DIR_TEMPLATE = """\
#!/bin/bash
export DEVELOPER_DIR="{developer_dir}"
exec "$@"
"""

_ACCEPT_LICENSE_TEMPLATE = """\
#!/bin/bash
#
# Accepts the Xcode software license agreement for the hermetic Xcode at
# {app}, recording it system-wide (requires sudo).
#
# macOS records acceptance in /Library/Preferences/com.apple.dt.Xcode.plist,
# keyed by the license type (GM or Beta) and agreement revision (licenseID)
# declared in the app's Contents/Resources/LicenseInfo.plist. Acceptance
# covers every Xcode copy under the same agreement revision.

set -euo pipefail

APP="{app}"
LICENSE_INFO="$APP/Contents/Resources/LicenseInfo"

license_type=$(defaults read "$LICENSE_INFO" licenseType 2>/dev/null || echo "GM")
license_id=$(defaults read "$LICENSE_INFO" licenseID 2>/dev/null || echo "unknown")
agreed=$(defaults read /Library/Preferences/com.apple.dt.Xcode \\
    "IDELast${{license_type}}LicenseAgreedTo" 2>/dev/null || true)

if [[ "$license_id" == "$agreed" ]]; then
  echo "Xcode license $license_id ($license_type) is already accepted on this machine."
  exit 0
fi

echo "Accepting Xcode license $license_id ($license_type) for $APP."
echo "This records acceptance system-wide and requires sudo."

if [[ ! -t 0 ]]; then
  echo ""
  echo "No terminal is attached, so sudo cannot prompt for your password."
  echo "Run this from a terminal instead:"
  echo ""
  echo "    sudo env DEVELOPER_DIR='$APP/Contents/Developer' \\\\"
  echo "        '$APP/Contents/Developer/usr/bin/xcodebuild' -license accept"
  exit 1
fi

exec sudo env DEVELOPER_DIR="$APP/Contents/Developer" \\
    "$APP/Contents/Developer/usr/bin/xcodebuild" -license accept
"""

# Maps SDK platform keys to the xcode_version attribute recording the default
# SDK version for that platform's OS.
_PLATFORM_TO_SDK_VERSION_ATTR = {
    "appletvos": "default_tvos_sdk_version",
    "iphoneos": "default_ios_sdk_version",
    "macosx": "default_macos_sdk_version",
    "watchos": "default_watchos_sdk_version",
    "xros": "default_visionos_sdk_version",
}

def _default_sdk_versions(rctx, developer):
    """Reads the default SDK version per platform from the Xcode's SDKs."""
    attrs = {}
    for platform, attr_name in _PLATFORM_TO_SDK_VERSION_ATTR.items():
        dir_name = SDK_PLATFORMS[platform]
        sdk = developer.get_child(
            "Platforms",
            dir_name + ".platform",
            "Developer",
            "SDKs",
            dir_name + ".sdk",
        )
        if not sdk.exists:
            continue
        settings = read_sdk_settings(rctx, sdk)
        if settings.get("Version"):
            attrs[attr_name] = settings["Version"]
    return attrs

def _apple_xcode_repository_impl(rctx):
    if rctx.attr.path:
        if rctx.attr.url:
            fail("apple.xcode(name = {}): path and url are mutually exclusive".format(
                repr(rctx.attr.name),
            ))
        source = rctx.path(rctx.attr.path)
        if not source.exists:
            fail("apple.xcode(name = {}): path {} does not exist".format(
                repr(rctx.attr.name),
                rctx.attr.path,
            ))

        # Copy rather than symlink: xcrun and xcodebuild canonicalize paths,
        # so a symlinked Xcode.app would leak the source location into
        # SDKROOT and header paths, escaping both the repository and the
        # include directories the C++ toolchain declares. The copy is an
        # APFS clone when the source is on the same volume: instant and
        # effectively free, and — being an unmodified copy — it keeps
        # Apple's notarized seal, so first launch stays fast.
        rctx.report_progress("Copying {} (APFS clone when possible)".format(rctx.attr.path))
        result = rctx.execute(["/bin/cp", "-Rc", str(source), "Xcode.app"], timeout = 3600)
        if result.return_code != 0:
            rctx.delete("Xcode.app")
            result = rctx.execute(["/usr/bin/ditto", str(source), "Xcode.app"], timeout = 7200)
            if result.return_code != 0:
                fail("Failed to copy {}: {}".format(rctx.attr.path, result.stderr))
    elif rctx.attr.url:
        rctx.download_and_extract(
            url = rctx.attr.url,
            sha256 = rctx.attr.sha256,
            stripPrefix = rctx.attr.strip_prefix,
        )
        if not rctx.path("Xcode.app").exists:
            # Accept archives whose root is the .app under a different name.
            for entry in rctx.path(".").readdir():
                if entry.basename.endswith(".app"):
                    rctx.symlink(entry, "Xcode.app")
                    break
    else:
        fail("apple.xcode(name = {}): either path or url is required".format(
            repr(rctx.attr.name),
        ))

    developer = rctx.path("Xcode.app").get_child("Contents", "Developer")
    if not developer.get_child("usr", "bin", "xcodebuild").exists:
        fail(("apple.xcode(name = {}): {} does not look like a full Xcode.app " +
              "(missing Contents/Developer/usr/bin/xcodebuild)").format(
            repr(rctx.attr.name),
            rctx.attr.path or rctx.attr.url,
        ))

    sdk_version_attrs = _default_sdk_versions(rctx, developer)

    aliases = {alias: True for alias in rctx.attr.aliases}
    aliases[rctx.attr.xcode_name] = True

    # Also accept the Xcode's version number and build number (for example
    # "26.5" and "17F42") as aliases. Tools that discover the active Xcode
    # via xcodebuild — rules_xcodeproj's generator, notably — select it by
    # passing --xcode_version=<build number>.
    result = rctx.execute([
        "/usr/bin/plutil",
        "-convert",
        "json",
        "-o",
        "-",
        str(rctx.path("Xcode.app").get_child("Contents", "version.plist")),
    ])
    if result.return_code == 0:
        version_info = json.decode(result.stdout)
        for key in ["CFBundleShortVersionString", "ProductBuildVersion"]:
            if version_info.get(key):
                aliases[version_info[key]] = True

    rctx.file(
        "accept_license.sh",
        _ACCEPT_LICENSE_TEMPLATE.format(app = str(rctx.path("Xcode.app"))),
        executable = True,
    )
    rctx.file(
        "with_developer_dir.sh",
        _WITH_DEVELOPER_DIR_TEMPLATE.format(developer_dir = str(developer)),
        executable = True,
    )
    rctx.file(
        "first_launch.sh",
        _FIRST_LAUNCH_TEMPLATE.format(app = str(rctx.path("Xcode.app"))),
        executable = True,
    )
    rctx.file(
        "open_xcode.sh",
        _OPEN_TEMPLATE.format(app = str(rctx.path("Xcode.app"))),
        executable = True,
    )
    rctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        version = repr(str(developer)),
        aliases = repr(sorted(aliases.keys())),
        sdk_version_attrs = "".join([
            "    {} = {},\n".format(attr_name, repr(version))
            for attr_name, version in sorted(sdk_version_attrs.items())
        ]),
    ))

apple_xcode_repository = repository_rule(
    doc = "Vendors a verbatim Xcode.app as a hermetic, selectable Xcode version.",
    implementation = _apple_xcode_repository_impl,
    attrs = {
        "path": attr.string(
            doc = "Absolute path to an Xcode.app (for example an extracted xip).",
        ),
        "url": attr.string(
            doc = "URL of a re-hosted archive containing the Xcode.app.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "strip_prefix": attr.string(
            doc = "Prefix to strip when extracting the archive.",
        ),
        "aliases": attr.string_list(
            doc = "Extra --xcode_version aliases accepted for this Xcode.",
        ),
        "xcode_name": attr.string(
            doc = "User facing name of this Xcode.",
            mandatory = True,
        ),
    },
)
