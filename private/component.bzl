"""Repository rule vendoring a downloadable Xcode component.

Since Xcode 26, some components are separate downloads that the Xcode GUI
prompts for on first launch — notably the Metal Toolchain, which is also
required to compile Metal shaders from the command line. Apple distributes
them per Xcode build via `xcodebuild -downloadComponent <type>` (which
`//scripts:create_hermetic_toolchain --download_component` wraps and
exports as a re-hostable bundle).

The repository caches the exported bundle and generates an `:install`
runnable that registers it through the associated hermetic Xcode
(`xcodebuild -importComponent`). Installation is per-machine state and
idempotent: the runnable no-ops when the Xcode reports the component as
installed.
"""

_BUILD = """\
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

package(default_visibility = ["//visibility:public"])

# Installs this Xcode component via the associated hermetic Xcode.
# Idempotent; needed once per machine (and per Xcode build) before the
# component's tools are available.
sh_binary(
    name = "install",
    srcs = ["install_component.sh"],
)
"""

_INSTALL_TEMPLATE = """\
#!/bin/bash
#
# Installs the {component_type} component from {bundle} using the hermetic
# Xcode at {developer_dir}.

set -euo pipefail

BUNDLE="{bundle}"
DEV="{developer_dir}"
TYPE="{component_type}"

if env DEVELOPER_DIR="$DEV" "$DEV/usr/bin/xcodebuild" -showComponent "$TYPE" -json 2>/dev/null | \\
    grep -q '"status" : "installed"'; then
  echo "$TYPE is already installed for this Xcode."
  exit 0
fi

echo "Installing $TYPE from $(basename "$BUNDLE")..."
exec env DEVELOPER_DIR="$DEV" "$DEV/usr/bin/xcodebuild" -importComponent "$TYPE" -importPath "$BUNDLE"
"""

def _apple_component_repository_impl(rctx):
    if rctx.attr.path:
        if rctx.attr.url:
            fail("apple.component(name = {}): path and url are mutually exclusive".format(
                repr(rctx.attr.name),
            ))
        source = rctx.path(rctx.attr.path)
        if not source.exists:
            fail("apple.component(name = {}): path {} does not exist".format(
                repr(rctx.attr.name),
                rctx.attr.path,
            ))
        bundle_name = source.basename

        # Copy rather than symlink so the repository is self-contained; the
        # copy is an APFS clone (free) when the source is on the same volume.
        result = rctx.execute(["/bin/cp", "-Rc", str(source), bundle_name])
        if result.return_code != 0:
            result = rctx.execute(["/bin/cp", "-R", str(source), bundle_name], timeout = 3600)
            if result.return_code != 0:
                fail("Failed to copy {}: {}".format(rctx.attr.path, result.stderr))
    elif rctx.attr.url:
        bundle_name = rctx.attr.url.rsplit("/", 1)[-1]
        is_archive = False
        for ext in [".tar.zst", ".tar.gz", ".tgz", ".tar.xz", ".zip"]:
            if bundle_name.endswith(ext):
                is_archive = True
        if is_archive:
            # Archived exported bundle: extract, then use its root entry.
            rctx.download_and_extract(
                url = rctx.attr.url,
                output = "extracted",
                sha256 = rctx.attr.sha256,
            )
            entries = rctx.path("extracted").readdir()
            if len(entries) != 1:
                fail("apple.component(name = {}): expected the archive to contain a single bundle, got {}".format(
                    repr(rctx.attr.name),
                    [e.basename for e in entries],
                ))
            bundle_name = "extracted/" + entries[0].basename
        else:
            rctx.download(
                url = rctx.attr.url,
                output = bundle_name,
                sha256 = rctx.attr.sha256,
            )
    else:
        fail("apple.component(name = {}): either path or url is required".format(
            repr(rctx.attr.name),
        ))

    xcode_root = rctx.path(rctx.attr.xcode_repo).dirname
    developer_dir = xcode_root.get_child("Xcode.app", "Contents", "Developer")

    rctx.file(
        "install_component.sh",
        _INSTALL_TEMPLATE.format(
            bundle = str(rctx.path(bundle_name)),
            developer_dir = str(developer_dir),
            component_type = rctx.attr.component_type,
        ),
        executable = True,
    )
    rctx.file("BUILD.bazel", _BUILD)

apple_component_repository = repository_rule(
    doc = "Vendors a downloadable Xcode component with an install runnable.",
    implementation = _apple_component_repository_impl,
    attrs = {
        "path": attr.string(
            doc = "Absolute path to an exported component bundle.",
        ),
        "url": attr.string(
            doc = "URL of a re-hosted component bundle (optionally archived).",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "component_type": attr.string(
            doc = "The xcodebuild component type, for example MetalToolchain.",
            default = "MetalToolchain",
        ),
        "xcode_repo": attr.label(
            doc = "A file in the Xcode repository used to install the component.",
            mandatory = True,
        ),
    },
)
