"""Repository rule vendoring a hermetic Apple toolchain.

Toolchain artifacts are produced from a downloaded Xcode.app by
`bazel run //scripts:create_hermetic_toolchain` and contain a single
`Xcode.app`: a slimmed, ad-hoc re-signed copy of the input Xcode with the
vendored platforms' SDKs removed (SDKs are vendored separately and placed
back when a developer directory is assembled).

The artifact can be consumed from a local path or from an archive that your
organization re-hosts (subject to Apple's software license agreement).
"""

load(
    ":utils.bzl",
    "APPLE_SLA_ENV",
    "require_apple_sla",
)

_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(["MARKER"])
"""

def _apple_toolchain_repository_impl(rctx):
    require_apple_sla(rctx, "the Apple toolchain")

    if rctx.attr.path:
        if rctx.attr.url:
            fail("apple.toolchain(name = {}): path and url are mutually exclusive".format(
                repr(rctx.attr.name),
            ))
        root = rctx.path(rctx.attr.path)
        if not root.exists:
            fail("apple.toolchain(name = {}): path {} does not exist".format(
                repr(rctx.attr.name),
                rctx.attr.path,
            ))
        for entry in root.readdir():
            rctx.symlink(entry, entry.basename)
    elif rctx.attr.url:
        rctx.download_and_extract(
            url = rctx.attr.url,
            sha256 = rctx.attr.sha256,
            stripPrefix = rctx.attr.strip_prefix,
        )
    else:
        fail("apple.toolchain(name = {}): either path or url is required".format(
            repr(rctx.attr.name),
        ))

    clang = "Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    if not rctx.path(clang).exists:
        fail(("apple.toolchain(name = {}): the toolchain does not contain " +
              "{}; expected an artifact produced by " +
              "//scripts:create_hermetic_toolchain").format(
            repr(rctx.attr.name),
            clang,
        ))

    rctx.file("MARKER", "")
    rctx.file("BUILD.bazel", _BUILD)

apple_toolchain_repository = repository_rule(
    doc = "Vendors a hermetic Apple toolchain produced by create_hermetic_toolchain.",
    environ = [APPLE_SLA_ENV],
    implementation = _apple_toolchain_repository_impl,
    attrs = {
        "path": attr.string(
            doc = "Absolute path to a toolchain produced by create_hermetic_toolchain.",
        ),
        "url": attr.string(
            doc = "URL of a re-hosted archive of such a toolchain.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "strip_prefix": attr.string(
            doc = "Prefix to strip when extracting the archive.",
        ),
    },
)
