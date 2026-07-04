"""Repository rule assembling a hermetic Apple developer directory.

A developer directory pairs one toolchain (a slimmed Xcode.app produced from
a downloaded Xcode by `//scripts:create_hermetic_toolchain`) with one SDK
set. The repository contains:

    Xcode.app             A copy of the toolchain's slimmed Xcode.app with
                          the vendored SDKs placed inside its platform
                          directories, re-sealed with an ad-hoc signature.
                          Xcode's designer tools (actool, ibtoold) resolve
                          platforms, SDKs, plug-ins, and agents relative to
                          the app bundle containing their own binary, so the
                          pairing has to be materialized as a real bundle;
                          the copy is an APFS clone when possible, which
                          costs no disk space.
    Developer/usr         A merged view (directories of symlinks) of the
                          toolchain's XcodeDefault.xctoolchain/usr and the
                          app's Developer/usr: real compilers win conflicts
                          (the app's ld and friends are shims that fail
                          outside an Xcode installation), and the app
                          contributes the designer tools and libxcrun.
    CommandLineTools/     The developer directory handed to Bazel:
                          usr -> ../Developer/usr, SDKs/ with the woven
                          SDKs, and the toolchain exposed as
                          Toolchains/XcodeDefault.xctoolchain.

The directory name `CommandLineTools` matters: `xcode-select`'s library (used
by `/usr/bin/xcrun`) recognizes a developer directory as a Command Line Tools
installation by that name, resolves tools from `usr/bin` (delegating through
`usr/lib/libxcrun.dylib`), and — unlike an Xcode.app-style developer
directory — never enforces the `xcodebuild -license` acceptance check, which
would otherwise require root on every machine.

The repository also defines an `xcode_version` target whose `version` is the
absolute path of the `CommandLineTools` directory. Passing a path instead of
a version number makes Bazel use it directly as `DEVELOPER_DIR` (and resolve
`SDKROOT` against it) when running actions, bypassing discovery of installed
Xcodes entirely. Tools launched through `CommandLineTools/usr/bin` symlinks
resolve (dyld realpaths the main executable) into the sealed `Xcode.app`,
giving the designer tools the bundle context they require.
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

# Tools that must come from the app's Developer/usr/bin even when the
# xctoolchain provides a same-named binary (there are no such conflicts for
# these today; the list documents intent).
_EXCLUDED_APP_TOOLS = {
    # Checking the license (and requiring root to accept it) is xcodebuild's
    # job; a Command Line Tools style developer directory has neither
    # xcodebuild nor its own xcrun and skips those checks.
    "xcodebuild": True,
    "xcrun": True,
}

def _run(rctx, args, timeout = 600):
    result = rctx.execute(args, timeout = timeout)
    if result.return_code != 0:
        fail("Command {} failed:\n{}".format(args, result.stderr))
    return result

def _merge_symlink_dir(rctx, out, primary, secondary):
    """Creates out/ with symlinks to every child of primary, then secondary.

    Children of `primary` win name conflicts.
    """
    rctx.execute(["mkdir", "-p", out])
    seen = {}
    for source in [primary, secondary]:
        if not source.exists:
            continue
        for child in source.readdir():
            if child.basename in seen:
                continue
            seen[child.basename] = True
            rctx.symlink(child, out + "/" + child.basename)

def _apple_developer_dir_repository_impl(rctx):
    toolchain_root = repo_root_from_marker(rctx, rctx.attr.toolchain_repo)
    sdk_root = repo_root_from_marker(rctx, rctx.attr.sdk_repo)

    source_app = toolchain_root.get_child("Xcode.app")
    if not source_app.exists:
        fail(("The toolchain repository at {} does not contain Xcode.app; " +
              "expected an artifact produced by //scripts:create_hermetic_toolchain.").format(
            toolchain_root,
        ))

    # Copy the slimmed Xcode.app (an APFS clone when the artifact is on the
    # same volume: instant and free). Build it under a temporary name; macOS
    # restricts writes into .app bundles in some configurations, and nothing
    # may touch the bundle once it has been sealed and executed.
    rctx.report_progress("Copying the toolchain's Xcode.app")
    work = "xcode_work"
    result = rctx.execute(["/bin/cp", "-Rc", str(source_app), work], timeout = 3600)
    if result.return_code != 0:
        rctx.delete(work)
        _run(rctx, ["/usr/bin/ditto", str(source_app), work], timeout = 3600)

    # Weave the vendored SDKs into the platform directories, as real copies
    # (clones): the sealed bundle the designer tools see must be a plain
    # directory tree.
    sdk_info = json.decode(rctx.read(sdk_root.get_child("sdk_info.json")))
    sdks_dir = sdk_root.get_child("SDKs")
    platform_dirs = {
        SDK_PLATFORMS[platform]: sdk_info[platform]["name"]
        for platform in sdk_info.keys()
        if platform in SDK_PLATFORMS
    }
    for platform_dir, sdk_name in platform_dirs.items():
        dest_platform = "{}/Contents/Developer/Platforms/{}.platform".format(work, platform_dir)
        if not rctx.path(dest_platform).exists:
            fail(("The toolchain at {} has no {}.platform; repackage the Xcode " +
                  "with --platforms including it.").format(toolchain_root, platform_dir))
        dest_sdks = dest_platform + "/Developer/SDKs"
        rctx.execute(["mkdir", "-p", dest_sdks])
        source_sdk = sdks_dir.get_child(sdk_name)
        result = rctx.execute(
            ["/bin/cp", "-Rc", str(source_sdk), dest_sdks + "/" + sdk_name],
            timeout = 3600,
        )
        if result.return_code != 0:
            _run(rctx, ["/usr/bin/ditto", str(source_sdk), dest_sdks + "/" + sdk_name], timeout = 3600)
        rctx.symlink(sdk_name, dest_sdks + "/" + platform_dir + ".sdk")

    # Re-seal the modified bundle with an ad-hoc signature. Without a
    # consistent seal, Gatekeeper's first-launch evaluation of the modified
    # bundle takes pathologically long (it looks like a hang); with it, the
    # first launch costs a few seconds.
    rctx.report_progress("Re-sealing Xcode.app (ad-hoc signature)")
    _run(rctx, ["/usr/bin/codesign", "-f", "-s", "-", work], timeout = 1800)
    _run(rctx, ["/bin/mv", work, "Xcode.app"])

    app = rctx.path("Xcode.app")
    contents = app.get_child("Contents")
    xctoolchain_usr = contents.get_child("Developer", "Toolchains", "XcodeDefault.xctoolchain", "usr")
    app_dev_usr = contents.get_child("Developer", "usr")

    # Merged usr: toolchain compilers + the app's designer tools/libxcrun.
    for name in ["bin", "lib", "libexec", "share", "include"]:
        _merge_symlink_dir(
            rctx,
            "Developer/usr/" + name,
            xctoolchain_usr.get_child(name),
            app_dev_usr.get_child(name),
        )
    for tool in _EXCLUDED_APP_TOOLS.keys():
        path = rctx.path("Developer/usr/bin/" + tool)
        if path.exists and not xctoolchain_usr.get_child("bin", tool).exists:
            rctx.delete(path)

    # The Command Line Tools style developer directory used as DEVELOPER_DIR.
    rctx.execute(["mkdir", "-p", "CommandLineTools/SDKs", "CommandLineTools/Toolchains/XcodeDefault.xctoolchain"])
    rctx.symlink(rctx.path("Developer/usr"), "CommandLineTools/usr")
    rctx.symlink(xctoolchain_usr, "CommandLineTools/Toolchains/XcodeDefault.xctoolchain/usr")

    sdk_names = {}
    for platform_dir, sdk_name in platform_dirs.items():
        sdk = contents.get_child(
            "Developer",
            "Platforms",
            platform_dir + ".platform",
            "Developer",
            "SDKs",
            sdk_name,
        )
        rctx.symlink(sdk, "CommandLineTools/SDKs/" + sdk_name)
        sdk_names[sdk_name] = True

    # The toolchain's macOS SDKs, for tools built for the exec platform.
    macos_sdks = contents.get_child("Developer", "Platforms", "MacOSX.platform", "Developer", "SDKs")
    macos_sdk_version = None
    if macos_sdks.exists:
        for sdk in macos_sdks.readdir():
            if sdk.basename not in sdk_names:
                rctx.symlink(sdk, "CommandLineTools/SDKs/" + sdk.basename)
        settings = macos_sdks.get_child("MacOSX.sdk", "SDKSettings.plist")
        if settings.exists:
            result = rctx.execute(["/usr/bin/plutil", "-extract", "Version", "raw", "-o", "-", str(settings)])
            if result.return_code == 0:
                macos_sdk_version = result.stdout.strip()

    sdk_version_attrs = sdk_version_attrs_from_info(sdk_info)
    if "default_macos_sdk_version" not in sdk_version_attrs and macos_sdk_version:
        sdk_version_attrs["default_macos_sdk_version"] = macos_sdk_version

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
