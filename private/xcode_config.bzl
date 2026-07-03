"""Repository rule generating the hub `xcode_config` for hermetic developer dirs."""

_BUILD_TEMPLATE = """\
load("@apple_support//xcode:xcode_config.bzl", "xcode_config")

package(default_visibility = ["//visibility:public"])

xcode_config(
    name = "xcode_config",
    default = {default},
    versions = {versions},
)
"""

def _apple_xcode_config_repository_impl(rctx):
    versions = [
        "@{}//:version".format(repo)
        for repo in rctx.attr.developer_dir_repos
    ]
    default = "@{}//:version".format(rctx.attr.default_developer_dir_repo)
    rctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        default = repr(default),
        versions = repr(versions),
    ))

apple_xcode_config_repository = repository_rule(
    doc = "Generates an xcode_config wiring up all hermetic developer directories.",
    implementation = _apple_xcode_config_repository_impl,
    attrs = {
        "developer_dir_repos": attr.string_list(
            doc = "Names of the developer directory repositories.",
            mandatory = True,
        ),
        "default_developer_dir_repo": attr.string(
            doc = "Developer directory used when --xcode_version is not passed.",
            mandatory = True,
        ),
    },
)
