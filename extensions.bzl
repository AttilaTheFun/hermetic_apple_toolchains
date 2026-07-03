"""Module extension for hermetic Apple toolchains, SDKs, and developer dirs.

Toolchains (compilers) and SDKs are registered independently and combined
into "developer directories". This mirrors reality: Xcode's toolchain and the
platform SDKs are orthogonal artifacts, and a given toolchain can usually
build against several SDK releases (while old toolchains generally cannot use
newer SDKs).

Example:

    apple = use_extension("@hermetic_apple_toolchains//:extensions.bzl", "apple")
    apple.toolchain(
        name = "xcode26",
        path = "/Library/Developer/CommandLineTools",
    )
    apple.toolchain(
        name = "xcode27beta2",
        url = "https://mirror.example/Command_Line_Tools_27_beta_2.dmg",
        sha256 = "...",
    )
    apple.sdk(
        name = "ios26_5",
        paths = {
            "iphoneos": "/path/to/iPhoneOS26.5.sdk",
            "iphonesimulator": "/path/to/iPhoneSimulator26.5.sdk",
        },
    )
    apple.developer_dir(
        name = "xcode26_ios26_5",
        toolchain = "xcode26",
        sdk = "ios26_5",
        default = True,
    )
    use_repo(apple, "apple_toolchains", "hermetic_apple_cc")

    apple_cc = use_extension("@apple_support//crosstool:setup.bzl", "apple_cc_configure_extension")
    override_repo(apple_cc, local_config_apple_cc = "hermetic_apple_cc")

And in .bazelrc:

    common --repo_env=ACCEPTED_APPLE_SLA=1
    build --xcode_version_config=@apple_toolchains//:xcode_config

Select a developer directory per invocation with
`--xcode_version=<developer_dir name or alias>`.
"""

load("//private:apple_cc.bzl", "hermetic_apple_cc_repository")
load("//private:developer_dir.bzl", "apple_developer_dir_repository")
load("//private:sdk.bzl", "apple_sdk_repository")
load("//private:swift_config.bzl", "hermetic_swift_config_repository")
load("//private:toolchain.bzl", "apple_toolchain_repository")
load("//private:xcode_config.bzl", "apple_xcode_config_repository")

_TOOLCHAIN_TAG = tag_class(
    doc = "Registers a hermetic Apple toolchain (Command Line Tools).",
    attrs = {
        "name": attr.string(
            doc = "Name used to reference this toolchain from developer_dir tags.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Absolute path to an existing Command Line Tools directory.",
        ),
        "url": attr.string(
            doc = "URL of a Command Line Tools .dmg or a re-hosted archive.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "strip_prefix": attr.string(
            doc = "Prefix to strip when extracting a plain archive.",
        ),
    },
)

_SDK_TAG = tag_class(
    doc = "Registers a hermetic set of Apple platform SDKs for one OS release.",
    attrs = {
        "name": attr.string(
            doc = "Name used to reference this SDK set from developer_dir tags.",
            mandatory = True,
        ),
        "paths": attr.string_dict(
            doc = "Platform key (e.g. iphoneos, iphonesimulator) to absolute .sdk path.",
        ),
        "urls": attr.string_dict(
            doc = "Platform key to archive URL containing the .sdk.",
        ),
        "sha256s": attr.string_dict(
            doc = "Platform key to SHA-256 for the corresponding url.",
        ),
        "strip_prefixes": attr.string_dict(
            doc = "Platform key to archive prefix to strip.",
        ),
    },
)

_DEVELOPER_DIR_TAG = tag_class(
    doc = "Pairs a toolchain with an SDK set into a selectable developer directory.",
    attrs = {
        "name": attr.string(
            doc = "Repository name; also accepted by --xcode_version.",
            mandatory = True,
        ),
        "toolchain": attr.string(
            doc = "Name of a registered apple.toolchain tag.",
            mandatory = True,
        ),
        "sdk": attr.string(
            doc = "Name of a registered apple.sdk tag.",
            mandatory = True,
        ),
        "aliases": attr.string_list(
            doc = "Extra aliases accepted by --xcode_version.",
        ),
        "default": attr.bool(
            doc = "Use this developer directory when --xcode_version is not passed.",
        ),
    },
)

_TOOLCHAIN_REPO_PREFIX = "apple_toolchain_"
_SDK_REPO_PREFIX = "apple_sdk_"

def _collect_root_tags(module_ctx, tag_name):
    tags = []
    for module in module_ctx.modules:
        if module.is_root:
            tags.extend(getattr(module.tags, tag_name))
    return tags

def _apple_impl(module_ctx):
    toolchains = _collect_root_tags(module_ctx, "toolchain")
    sdks = _collect_root_tags(module_ctx, "sdk")
    developer_dirs = _collect_root_tags(module_ctx, "developer_dir")

    if not developer_dirs:
        fail("Expected at least one apple.developer_dir(...) tag in the root module.")

    toolchain_names = {}
    for tag in toolchains:
        if tag.name in toolchain_names:
            fail("Duplicate apple.toolchain(name = {})".format(repr(tag.name)))
        toolchain_names[tag.name] = True
        apple_toolchain_repository(
            name = _TOOLCHAIN_REPO_PREFIX + tag.name,
            path = tag.path,
            url = tag.url,
            sha256 = tag.sha256,
            strip_prefix = tag.strip_prefix,
        )

    sdk_names = {}
    for tag in sdks:
        if tag.name in sdk_names:
            fail("Duplicate apple.sdk(name = {})".format(repr(tag.name)))
        sdk_names[tag.name] = True
        apple_sdk_repository(
            name = _SDK_REPO_PREFIX + tag.name,
            paths = tag.paths,
            urls = tag.urls,
            sha256s = tag.sha256s,
            strip_prefixes = tag.strip_prefixes,
        )

    default_repo = None
    developer_dir_repos = []
    for tag in developer_dirs:
        if tag.toolchain not in toolchain_names:
            fail("apple.developer_dir(name = {}): unknown toolchain {}".format(
                repr(tag.name),
                repr(tag.toolchain),
            ))
        if tag.sdk not in sdk_names:
            fail("apple.developer_dir(name = {}): unknown sdk {}".format(
                repr(tag.name),
                repr(tag.sdk),
            ))
        if tag.name in developer_dir_repos:
            fail("Duplicate apple.developer_dir(name = {})".format(repr(tag.name)))
        apple_developer_dir_repository(
            name = tag.name,
            developer_dir_name = tag.name,
            toolchain_repo = "@{}{}//:MARKER".format(_TOOLCHAIN_REPO_PREFIX, tag.toolchain),
            sdk_repo = "@{}{}//:MARKER".format(_SDK_REPO_PREFIX, tag.sdk),
            aliases = tag.aliases,
        )
        developer_dir_repos.append(tag.name)
        if tag.default:
            if default_repo:
                fail("Multiple apple.developer_dir tags have default = True.")
            default_repo = tag.name

    apple_xcode_config_repository(
        name = "apple_toolchains",
        developer_dir_repos = developer_dir_repos,
        default_developer_dir_repo = default_repo or developer_dir_repos[0],
    )

    hermetic_apple_cc_repository(name = "hermetic_apple_cc")
    hermetic_swift_config_repository(name = "hermetic_swift_config")

    return module_ctx.extension_metadata(reproducible = True)

apple = module_extension(
    doc = "Registers hermetic Apple toolchains, SDKs, and developer directories.",
    implementation = _apple_impl,
    tag_classes = {
        "developer_dir": _DEVELOPER_DIR_TAG,
        "sdk": _SDK_TAG,
        "toolchain": _TOOLCHAIN_TAG,
    },
)
