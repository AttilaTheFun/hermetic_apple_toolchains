"""Repository rule generating an Apple C++ toolchain aware of hermetic repos.

This reuses apple_support's own crosstool configuration, but extends the
toolchain's `cxx_builtin_include_directories` so that headers resolved from
hermetic developer directories (which live under Bazel's external repository
root rather than /Applications or /Library) are not flagged as undeclared
inclusions.

Use it to replace apple_support's `local_config_apple_cc` repository:

    apple_cc = use_extension("@apple_support//crosstool:setup.bzl", "apple_cc_configure_extension")
    override_repo(apple_cc, local_config_apple_cc = "hermetic_apple_cc")
"""

load("@apple_support//crosstool:osx_cc_configure.bzl", "configure_osx_toolchain")

def _hermetic_apple_cc_repository_impl(rctx):
    # Cover every repository under the external root, which includes all of
    # the assembled developer directories (and through their symlinks, the
    # vendored toolchains and SDKs).
    external_root = str(rctx.path(".").dirname)
    success, error = configure_osx_toolchain(
        rctx,
        extra_include_dirs = [external_root + "/"],
    )
    if not success:
        fail("Failed to configure the hermetic Apple CC toolchain: {}".format(error))

hermetic_apple_cc_repository = repository_rule(
    doc = "Configures apple_support's C++ toolchain with hermetic include directories.",
    environ = [
        "APPLE_SUPPORT_LAYERING_CHECK_BETA",
        "BAZEL_ALLOW_NON_APPLICATIONS_XCODE",
        "BAZEL_CONLYOPTS",
        "BAZEL_COPTS",
        "BAZEL_CXXOPTS",
        "BAZEL_LINKOPTS",
        "DEVELOPER_DIR",
        "GCOV",
        "USER",
    ],
    implementation = _hermetic_apple_cc_repository_impl,
    configure = True,
)
