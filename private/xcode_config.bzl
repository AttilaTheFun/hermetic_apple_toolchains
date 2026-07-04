"""Repository rule generating the hub `xcode_config` for hermetic Xcodes."""

_BUILD_TEMPLATE = """\
load("@apple_support//xcode:xcode_config.bzl", "xcode_config")

package(default_visibility = ["//visibility:public"])

xcode_config(
    name = "xcode_config",
    default = {default},
    versions = {versions},
)

# Convenience runnables: `bazel run @apple_toolchains//:accept_license_<name>`
# accepts the Xcode license for that Xcode (requires sudo; needed once per
# machine and license agreement revision).
{license_aliases}
"""

def _apple_xcode_config_repository_impl(rctx):
    versions = [
        "@{}//:version".format(repo)
        for repo in rctx.attr.xcode_repos
    ]
    default = "@{}//:version".format(rctx.attr.default_xcode_repo)
    license_aliases = "\n".join([
        ("alias(\n" +
         "    name = \"accept_license_{name}\",\n" +
         "    actual = \"@{name}//:accept_license\",\n" +
         ")\n").format(name = repo)
        for repo in rctx.attr.xcode_repos
    ])
    rctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        default = repr(default),
        versions = repr(versions),
        license_aliases = license_aliases,
    ))

apple_xcode_config_repository = repository_rule(
    doc = "Generates an xcode_config wiring up all hermetic Xcodes.",
    implementation = _apple_xcode_config_repository_impl,
    attrs = {
        "xcode_repos": attr.string_list(
            doc = "Names of the Xcode repositories.",
            mandatory = True,
        ),
        "default_xcode_repo": attr.string(
            doc = "Xcode used when --xcode_version is not passed.",
            mandatory = True,
        ),
    },
)
