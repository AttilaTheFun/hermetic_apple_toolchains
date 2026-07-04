"""Module extension for hermetic, verbatim Xcode installations.

Each registered Xcode is an unmodified copy of a real Xcode distribution
(an extracted `.xip`), consumed from a local path or an archive re-hosted on
servers you manage. Registered Xcodes become selectable per invocation with
`--xcode_version=<name or alias>`; no Xcode ever needs to be installed,
launched, or discovered on the host.

Example:

    apple = use_extension("@hermetic_apple_toolchains//:extensions.bzl", "apple")
    apple.xcode(
        name = "xcode26_5",
        path = "/opt/hermetic/xcode_26_5/Xcode.app",
        default = True,
    )
    apple.xcode(
        name = "xcode27beta2",
        url = "https://mirror.example.com/Xcode_27_beta_2.tar.zst",
        sha256 = "...",
    )
    use_repo(apple, "apple_toolchains", "hermetic_apple_cc", "hermetic_swift_config")

    apple_cc = use_extension("@apple_support//crosstool:setup.bzl", "apple_cc_configure_extension")
    override_repo(apple_cc, local_config_apple_cc = "hermetic_apple_cc")

    swift_non_module_deps = use_extension("@rules_swift//swift:extensions.bzl", "non_module_deps")
    override_repo(swift_non_module_deps, rules_swift_local_config = "hermetic_swift_config")

And in .bazelrc:

    common --repo_env=ACCEPTED_APPLE_SLA=1
    build --xcode_version_config=@apple_toolchains//:xcode_config
    build --@apple_support//xcode:starlark_version_config=@apple_toolchains//:xcode_config

Before the first build with a given Xcode, accept its license once per
machine (and per license agreement revision):

    bazel run @apple_toolchains//:accept_license_<name>
"""

load("//private:apple_cc.bzl", "hermetic_apple_cc_repository")
load("//private:simulator_runtime.bzl", "apple_simulator_runtime_repository")
load("//private:swift_config.bzl", "hermetic_swift_config_repository")
load("//private:xcode.bzl", "apple_xcode_repository")
load("//private:xcode_config.bzl", "apple_xcode_config_repository")

_XCODE_TAG = tag_class(
    doc = "Registers a hermetic, verbatim Xcode installation.",
    attrs = {
        "name": attr.string(
            doc = "Repository name; also accepted by --xcode_version.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Absolute path to an Xcode.app (for example an extracted xip).",
        ),
        "url": attr.string(
            doc = "URL of a re-hosted archive containing the Xcode.app.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "strip_prefix": attr.string(
            doc = "Prefix to strip when extracting the archive.",
        ),
        "aliases": attr.string_list(
            doc = "Extra aliases accepted by --xcode_version.",
        ),
        "default": attr.bool(
            doc = "Use this Xcode when --xcode_version is not passed.",
        ),
    },
)

_SIMULATOR_RUNTIME_TAG = tag_class(
    doc = "Registers a hermetic simulator runtime disk image.",
    attrs = {
        "name": attr.string(
            doc = "Repository name for the runtime.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Absolute path to a simulator runtime .dmg.",
        ),
        "url": attr.string(
            doc = "URL of a re-hosted simulator runtime .dmg.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "xcode": attr.string(
            doc = "Name of the apple.xcode tag used to register the runtime; " +
                  "defaults to the default Xcode.",
        ),
    },
)

def _collect_root_tags(module_ctx, tag_name):
    tags = []
    for module in module_ctx.modules:
        if module.is_root:
            tags.extend(getattr(module.tags, tag_name))
    return tags

def _apple_impl(module_ctx):
    xcodes = _collect_root_tags(module_ctx, "xcode")
    runtimes = _collect_root_tags(module_ctx, "simulator_runtime")

    if not xcodes:
        fail("Expected at least one apple.xcode(...) tag in the root module.")

    default_repo = None
    xcode_repos = []
    for tag in xcodes:
        if tag.name in xcode_repos:
            fail("Duplicate apple.xcode(name = {})".format(repr(tag.name)))
        apple_xcode_repository(
            name = tag.name,
            xcode_name = tag.name,
            path = tag.path,
            url = tag.url,
            sha256 = tag.sha256,
            strip_prefix = tag.strip_prefix,
            aliases = tag.aliases,
        )
        xcode_repos.append(tag.name)
        if tag.default:
            if default_repo:
                fail("Multiple apple.xcode tags have default = True.")
            default_repo = tag.name

    runtime_repos = []
    for tag in runtimes:
        if tag.name in runtime_repos or tag.name in xcode_repos:
            fail("Duplicate repository name {}".format(repr(tag.name)))
        xcode = tag.xcode or default_repo or xcode_repos[0]
        if xcode not in xcode_repos:
            fail("apple.simulator_runtime(name = {}): unknown xcode {}".format(
                repr(tag.name),
                repr(xcode),
            ))
        apple_simulator_runtime_repository(
            name = tag.name,
            path = tag.path,
            url = tag.url,
            sha256 = tag.sha256,
            xcode_repo = "@{}//:BUILD.bazel".format(xcode),
        )
        runtime_repos.append(tag.name)

    apple_xcode_config_repository(
        name = "apple_toolchains",
        xcode_repos = xcode_repos,
        simulator_runtime_repos = runtime_repos,
        default_xcode_repo = default_repo or xcode_repos[0],
    )

    hermetic_apple_cc_repository(name = "hermetic_apple_cc")
    hermetic_swift_config_repository(name = "hermetic_swift_config")

    return module_ctx.extension_metadata(reproducible = True)

apple = module_extension(
    doc = "Registers hermetic, verbatim Xcode installations and simulator runtimes.",
    implementation = _apple_impl,
    tag_classes = {
        "simulator_runtime": _SIMULATOR_RUNTIME_TAG,
        "xcode": _XCODE_TAG,
    },
)
