"""Repository rule vendoring a hermetic simulator runtime disk image.

Simulator runtimes are cryptex disk images that Apple distributes separately
from Xcode (Xcode Settings > Components, or
`xcodebuild -downloadPlatform iOS -exportPath ...`, which
`//scripts:create_hermetic_toolchain --download_platform` wraps). They are
only needed to *run* apps in a simulator, not to build them.

The repository caches the image and generates an `:install` runnable that
registers it with CoreSimulator through the associated hermetic Xcode
(`xcodebuild -importPlatform`). Registration is per-machine system state —
CoreSimulator copies the runtime into its own store — and is idempotent: the
runnable no-ops when a runtime with the same build is already registered.
"""

_BUILD = """\
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

package(default_visibility = ["//visibility:public"])

# Registers this simulator runtime with CoreSimulator via the associated
# hermetic Xcode. Idempotent; needed once per machine before running apps in
# a simulator with this OS version.
sh_binary(
    name = "install",
    srcs = ["install_runtime.sh"],
)
"""

_INSTALL_TEMPLATE = """\
#!/bin/bash
#
# Registers the simulator runtime image {dmg} with CoreSimulator using the
# hermetic Xcode at {developer_dir}.

set -euo pipefail

DMG="{dmg}"
DEV="{developer_dir}"

# When the image follows the iOS_<version>_<build>.dmg naming convention
# produced by //scripts:create_hermetic_toolchain, skip the import if a
# runtime with that build is already registered.
name=$(basename "$DMG")
if [[ "$name" =~ ^[A-Za-z]+_[0-9.]+_([A-Za-z0-9]+)\\.dmg$ ]]; then
  build="${{BASH_REMATCH[1]}}"
  if env DEVELOPER_DIR="$DEV" /usr/bin/xcrun simctl runtime list 2>/dev/null | grep "($build)" | grep -q "(Ready)"; then
    echo "Simulator runtime build $build is already registered with CoreSimulator."
    exit 0
  fi
fi

echo "Registering simulator runtime $name with CoreSimulator..."
exec env DEVELOPER_DIR="$DEV" "$DEV/usr/bin/xcodebuild" -importPlatform "$DMG"
"""

def _apple_simulator_runtime_repository_impl(rctx):
    if rctx.attr.path:
        if rctx.attr.url:
            fail("apple.simulator_runtime(name = {}): path and url are mutually exclusive".format(
                repr(rctx.attr.name),
            ))
        source = rctx.path(rctx.attr.path)
        if not source.exists:
            fail("apple.simulator_runtime(name = {}): path {} does not exist".format(
                repr(rctx.attr.name),
                rctx.attr.path,
            ))
        dmg_name = source.basename

        # Copy rather than symlink so the repository is self-contained; the
        # copy is an APFS clone (free) when the source is on the same volume.
        result = rctx.execute(["/bin/cp", "-c", str(source), dmg_name])
        if result.return_code != 0:
            result = rctx.execute(["/bin/cp", str(source), dmg_name], timeout = 3600)
            if result.return_code != 0:
                fail("Failed to copy {}: {}".format(rctx.attr.path, result.stderr))
    elif rctx.attr.url:
        dmg_name = rctx.attr.url.rsplit("/", 1)[-1]
        if not dmg_name.endswith(".dmg"):
            dmg_name = "runtime.dmg"
        rctx.download(
            url = rctx.attr.url,
            output = dmg_name,
            sha256 = rctx.attr.sha256,
        )
    else:
        fail("apple.simulator_runtime(name = {}): either path or url is required".format(
            repr(rctx.attr.name),
        ))

    xcode_root = rctx.path(rctx.attr.xcode_repo).dirname
    developer_dir = xcode_root.get_child("Xcode.app", "Contents", "Developer")

    rctx.file(
        "install_runtime.sh",
        _INSTALL_TEMPLATE.format(
            dmg = str(rctx.path(dmg_name)),
            developer_dir = str(developer_dir),
        ),
        executable = True,
    )
    rctx.file("BUILD.bazel", _BUILD)

apple_simulator_runtime_repository = repository_rule(
    doc = "Vendors a simulator runtime disk image with an install runnable.",
    implementation = _apple_simulator_runtime_repository_impl,
    attrs = {
        "path": attr.string(
            doc = "Absolute path to a simulator runtime .dmg.",
        ),
        "url": attr.string(
            doc = "URL of a re-hosted simulator runtime .dmg.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "xcode_repo": attr.label(
            doc = "A file in the Xcode repository used to register the runtime.",
            mandatory = True,
        ),
    },
)
