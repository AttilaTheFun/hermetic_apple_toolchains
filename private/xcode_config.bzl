"""Repository rule generating the hub `xcode_config` for hermetic Xcodes."""

_BUILD_TEMPLATE = """\
load("@apple_support//xcode:xcode_config.bzl", "xcode_config")

package(default_visibility = ["//visibility:public"])

xcode_config(
    name = "xcode_config",
    default = {default},
    versions = {versions},
)

# Convenience runnables:
#   `bazel run @apple_toolchains//:accept_license_<xcode>` accepts the Xcode
#   license (requires sudo; once per machine and agreement revision).
#   `bazel run @apple_toolchains//:install_runtime_<runtime>` registers a
#   vendored simulator runtime with CoreSimulator (idempotent).
# The with_developer_dir_<xcode> targets are `--run_under` wrappers that
# point DEVELOPER_DIR at the corresponding hermetic Xcode.
{aliases}
"""

def _apple_xcode_config_repository_impl(rctx):
    versions = [
        "@{}//:version".format(repo)
        for repo in rctx.attr.xcode_repos
    ]
    default = "@{}//:version".format(rctx.attr.default_xcode_repo)

    def alias(name, actual):
        return ("alias(\n" +
                "    name = \"{}\",\n" +
                "    actual = \"{}\",\n" +
                ")\n").format(name, actual)

    aliases = []
    for repo in rctx.attr.xcode_repos:
        # `bazel run @apple_toolchains//:<name>` opens the Xcode's GUI.
        aliases.append(alias(repo, "@{}//:open".format(repo)))
        aliases.append(alias("accept_license_" + repo, "@{}//:accept_license".format(repo)))
        aliases.append(alias("first_launch_" + repo, "@{}//:first_launch".format(repo)))
        aliases.append(alias("with_developer_dir_" + repo, "@{}//:with_developer_dir".format(repo)))
    for repo in rctx.attr.simulator_runtime_repos:
        aliases.append(alias("install_runtime_" + repo, "@{}//:install".format(repo)))

    rctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        default = repr(default),
        versions = repr(versions),
        aliases = "\n".join(aliases),
    ))

apple_xcode_config_repository = repository_rule(
    doc = "Generates an xcode_config wiring up all hermetic Xcodes.",
    implementation = _apple_xcode_config_repository_impl,
    attrs = {
        "xcode_repos": attr.string_list(
            doc = "Names of the Xcode repositories.",
            mandatory = True,
        ),
        "simulator_runtime_repos": attr.string_list(
            doc = "Names of the simulator runtime repositories.",
        ),
        "default_xcode_repo": attr.string(
            doc = "Xcode used when --xcode_version is not passed.",
            mandatory = True,
        ),
    },
)
