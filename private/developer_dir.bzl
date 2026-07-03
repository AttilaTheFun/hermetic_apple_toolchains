"""Repository rule assembling a hermetic Apple developer directory.

A developer directory pairs one toolchain with one SDK set. The repository
contains a `CommandLineTools` directory that mimics the layout of
`/Library/Developer/CommandLineTools`:

    CommandLineTools/usr        -> toolchain repository's usr
    CommandLineTools/Library    -> toolchain repository's Library
    CommandLineTools/SDKs/*.sdk -> SDK repository's SDKs (plus the macOS SDKs
                                   bundled with the toolchain)

The directory name `CommandLineTools` matters: `xcode-select`'s library (used
by `/usr/bin/xcrun`) recognizes a developer directory as a Command Line Tools
installation by that name and will resolve tools from `usr/bin` and SDKs from
`SDKs/` inside it, without requiring a full Xcode installation.

The repository also defines an `xcode_version` target whose `version` is the
absolute path of the assembled developer directory. Passing a path instead of
a version number makes Bazel use it directly as `DEVELOPER_DIR` (and resolve
`SDKROOT` against it) when running actions, bypassing discovery of installed
Xcodes entirely.
"""

load(
    ":utils.bzl",
    "SDK_PLATFORMS",
    "repo_root_from_marker",
    "sdk_version_attrs_from_info",
)

_BUILD_TEMPLATE = """\
load("@apple_support//xcode:xcode_version.bzl", "xcode_version")

package(default_visibility = ["//visibility:public"])

xcode_version(
    name = "version",
    version = {version},
    aliases = {aliases},
{sdk_version_attrs})
"""

def _apple_developer_dir_repository_impl(rctx):
    toolchain_root = repo_root_from_marker(rctx, rctx.attr.toolchain_repo)
    sdk_root = repo_root_from_marker(rctx, rctx.attr.sdk_repo)

    # Toolchains repackaged from a full Xcode keep their contents in an
    # Xcode.app bundle shell (see scripts/create_hermetic_toolchain.sh);
    # plain Command Line Tools have everything at the repository root.
    toolchain_contents = toolchain_root.get_child("Xcode.app", "Contents")
    if not toolchain_contents.exists:
        toolchain_contents = toolchain_root

    rctx.execute(["mkdir", "-p", "CommandLineTools/SDKs"])

    for name in ["usr", "Library"]:
        entry = toolchain_root.get_child(name)
        if entry.exists:
            rctx.symlink(entry, "CommandLineTools/" + name)

    sdk_names = {}
    sdks_dir = sdk_root.get_child("SDKs")
    if sdks_dir.exists:
        for sdk in sdks_dir.readdir():
            rctx.symlink(sdk, "CommandLineTools/SDKs/" + sdk.basename)
            sdk_names[sdk.basename] = True

    # Fall back to the macOS SDKs bundled with the toolchain for tools built
    # for the exec platform, unless the SDK set already provides them.
    toolchain_sdks = toolchain_root.get_child("SDKs")
    if toolchain_sdks.exists:
        for sdk in toolchain_sdks.readdir():
            if sdk.basename not in sdk_names:
                rctx.symlink(sdk, "CommandLineTools/SDKs/" + sdk.basename)

    sdk_info = json.decode(rctx.read(sdk_root.get_child("sdk_info.json")))

    # Materialize the platform directories. When the toolchain was repackaged
    # from a full Xcode it ships the platform directories (metadata, support
    # libraries, and asset runtimes, without SDKs); link their contents and
    # place the vendored SDKs inside them. Otherwise (plain Command Line
    # Tools) create the empty directories that the Swift driver and linker
    # add to their search paths, so that links do not warn about missing
    # directories.
    platform_dirs = {
        SDK_PLATFORMS[platform]: sdk_info[platform]["name"]
        for platform in sdk_info.keys()
        if platform in SDK_PLATFORMS
    }
    for platform_dir, sdk_name in platform_dirs.items():
        base = "CommandLineTools/Platforms/{}.platform".format(platform_dir)
        toolchain_platform = toolchain_contents.get_child(
            "Developer",
            "Platforms",
            platform_dir + ".platform",
        )
        if toolchain_platform.exists:
            rctx.execute(["mkdir", "-p", base + "/Developer/SDKs"])
            for child in toolchain_platform.readdir():
                if child.basename == "Developer":
                    for dev_child in child.readdir():
                        if dev_child.basename == "SDKs":
                            continue
                        rctx.symlink(dev_child, base + "/Developer/" + dev_child.basename)
                else:
                    rctx.symlink(child, base + "/" + child.basename)
            sdk = sdks_dir.get_child(sdk_name)
            rctx.symlink(sdk, base + "/Developer/SDKs/" + sdk_name)
        else:
            rctx.execute(["mkdir", "-p", base + "/Developer/usr/lib", base + "/Developer/Library/Frameworks"])

    # Expose the macOS platform from the toolchain for exec-platform tools if
    # the SDK set does not provide one.
    if "MacOSX" not in platform_dirs:
        toolchain_macos = toolchain_contents.get_child("Developer", "Platforms", "MacOSX.platform")
        if toolchain_macos.exists:
            rctx.symlink(toolchain_macos, "CommandLineTools/Platforms/MacOSX.platform")

    # Toolchains repackaged from a full Xcode ship the Swift back-deployment
    # libraries for every platform; expose the whole toolchain as
    # XcodeDefault.xctoolchain so toolchain-relative lookups find them.
    # Command Line Tools only ship the macOS libraries, so for those create
    # empty directories to keep the linker from warning about missing search
    # paths (with modern minimum OS versions the Swift runtime ships in the
    # OS and no back-deployment libraries are required).
    if toolchain_root.get_child("usr", "lib", "swift", "iphoneos").exists:
        rctx.execute(["mkdir", "-p", "CommandLineTools/Toolchains/XcodeDefault.xctoolchain"])
        rctx.symlink(
            toolchain_root.get_child("usr"),
            "CommandLineTools/Toolchains/XcodeDefault.xctoolchain/usr",
        )
    else:
        for platform_dir in platform_dirs.keys():
            rctx.execute(["mkdir", "-p", (
                "CommandLineTools/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/" +
                platform_dir.lower()
            )])

    # The Interface Builder and asset catalog tools (actool, ibtool, ibtoold)
    # discover their platform support plug-ins from the containing Xcode.app
    # bundle. Hermetic developer directories are not app bundles, so link the
    # toolchain's plug-in roots next to CommandLineTools; rules_apple's
    # xctoolrunner points DVTExtraPlugInPaths at the PlugIns sibling when it
    # exists.
    for name in ["Frameworks", "SharedFrameworks", "PlugIns"]:
        entry = toolchain_contents.get_child(name)
        if entry.exists:
            rctx.symlink(entry, name)
    toolchain_info_path = toolchain_root.get_child("toolchain_info.json")
    toolchain_info = {}
    if toolchain_info_path.exists:
        toolchain_info = json.decode(rctx.read(toolchain_info_path))

    sdk_version_attrs = sdk_version_attrs_from_info(sdk_info)
    if "default_macos_sdk_version" not in sdk_version_attrs:
        macos_info = toolchain_info.get("macosx")
        if macos_info and macos_info.get("version"):
            sdk_version_attrs["default_macos_sdk_version"] = macos_info["version"]

    aliases = {alias: True for alias in rctx.attr.aliases}
    aliases[rctx.attr.developer_dir_name] = True

    rctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        version = repr(str(rctx.path("CommandLineTools"))),
        aliases = repr(sorted(aliases.keys())),
        sdk_version_attrs = "".join([
            "    {} = {},\n".format(attr_name, repr(version))
            for attr_name, version in sorted(sdk_version_attrs.items())
        ]),
    ))

apple_developer_dir_repository = repository_rule(
    doc = "Assembles a hermetic developer directory from a toolchain and an SDK set.",
    implementation = _apple_developer_dir_repository_impl,
    attrs = {
        "toolchain_repo": attr.label(
            doc = "MARKER file of the toolchain repository.",
            mandatory = True,
        ),
        "sdk_repo": attr.label(
            doc = "MARKER file of the SDK repository.",
            mandatory = True,
        ),
        "aliases": attr.string_list(
            doc = "Extra --xcode_version aliases accepted for this developer directory.",
        ),
        "developer_dir_name": attr.string(
            doc = "User facing name of this developer directory.",
            mandatory = True,
        ),
    },
)
