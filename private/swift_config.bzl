"""Repository rule replacing rules_swift's `rules_swift_local_config`.

rules_swift's autoconfigured Xcode toolchain wires in explicit system modules
from its `@system_sdk` repository, whose targets `select()` on the exact
versions of the Xcodes *installed on the host* (discovered via xcode-locator).
That cannot match a hermetic developer directory, so this repository provides
the same toolchain targets without the system SDK explicit module support;
system modules are built implicitly from the hermetic SDK instead.

Use it to replace the autoconfigured repository:

    swift_non_module_deps = use_extension("@rules_swift//swift:extensions.bzl", "non_module_deps")
    override_repo(swift_non_module_deps, rules_swift_local_config = "hermetic_swift_config")
"""

_BUILD = """\
load(
    "@rules_swift//swift/toolchains:xcode_swift_toolchain.bzl",
    "xcode_swift_toolchain",
)

package(default_visibility = ["//visibility:public"])

xcode_swift_toolchain(
    name = "xcode-sdk-toolchain",
    features = ["swift.module_map_no_private_headers"],
)

xcode_swift_toolchain(
    name = "xcode-toolchain",
    features = ["swift.module_map_no_private_headers"],
)

# Stubs for the non-Apple toolchain targets referenced by rules_swift's
# registered `toolchain` targets. They are never resolved when building on and
# for Apple platforms.
alias(
    name = "linux-toolchain",
    actual = ":xcode-sdk-toolchain",
)

alias(
    name = "windows-toolchain",
    actual = ":xcode-sdk-toolchain",
)
"""

def _hermetic_swift_config_repository_impl(rctx):
    rctx.file("BUILD.bazel", _BUILD)

hermetic_swift_config_repository = repository_rule(
    doc = "Provides rules_swift toolchains without host Xcode system SDK detection.",
    implementation = _hermetic_swift_config_repository_impl,
)
