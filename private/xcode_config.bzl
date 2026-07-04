"""Repository rule generating the hub `xcode_config` for hermetic Xcodes."""

_BUILD_TEMPLATE = """\
load("@apple_support//xcode:xcode_config.bzl", "xcode_config")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

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

# Wrapper used instead of the Xcode repository's own with_developer_dir when
# the Xcode does not ship Developer/Applications/Simulator.app (Xcode 27
# moved it out of the bundle). rules_apple's simulator runner launches the
# Simulator GUI from that fixed location, so expose a developer-dir view
# that symlinks the real developer dir and borrows Simulator.app from
# another registered Xcode. The view lives outside Xcode.app, keeping the
# bundle verbatim (and its notarized seal intact).
_RUNNER_VIEW_WRAPPER_TEMPLATE = """\
#!/bin/bash
DEV="{developer_dir}"
if [[ ! -e "$DEV/Applications/Simulator.app" ]]; then
  VIEW="${{TMPDIR:-/tmp}}/hermetic_xcode_runner_view_{name}"
  mkdir -p "$VIEW/Applications"
  for entry in "$DEV"/*; do
    base="$(basename "$entry")"
    if [[ "$base" != "Applications" ]]; then
      ln -sfn "$entry" "$VIEW/$base"
    fi
  done
  if [[ -d "$DEV/Applications" ]]; then
    for entry in "$DEV/Applications"/*; do
      ln -sfn "$entry" "$VIEW/Applications/$(basename "$entry")"
    done
  fi
  ln -sfn "{donor_simulator_app}" "$VIEW/Applications/Simulator.app"
  DEV="$VIEW"
fi
export DEVELOPER_DIR="$DEV"
exec "$@"
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

    def sh_binary(name, src):
        return ("sh_binary(\n" +
                "    name = \"{}\",\n" +
                "    srcs = [\"{}\"],\n" +
                ")\n").format(name, src)

    # Locate each Xcode's developer dir and Simulator.app (absent from
    # Xcode 27+, which ships DeviceHub.app instead). The first registered
    # Xcode that has one — preferring the default — donates it to the
    # run wrappers of those that don't.
    developer_dirs = {}
    simulator_apps = {}
    for i in range(len(rctx.attr.xcode_repos)):
        repo = rctx.attr.xcode_repos[i]
        build_file = rctx.attr.xcode_repo_files[i]
        developer = rctx.path(build_file).dirname.get_child("Xcode.app", "Contents", "Developer")
        developer_dirs[repo] = developer
        simulator_app = developer.get_child("Applications", "Simulator.app")
        if simulator_app.exists:
            simulator_apps[repo] = simulator_app
    donor = None
    if rctx.attr.default_xcode_repo in simulator_apps:
        donor = simulator_apps[rctx.attr.default_xcode_repo]
    elif simulator_apps:
        donor = simulator_apps[simulator_apps.keys()[0]]

    aliases = []
    for repo in rctx.attr.xcode_repos:
        # `bazel run @apple_toolchains//:<name>` opens the Xcode's GUI.
        aliases.append(alias(repo, "@{}//:open".format(repo)))
        aliases.append(alias("accept_license_" + repo, "@{}//:accept_license".format(repo)))
        aliases.append(alias("first_launch_" + repo, "@{}//:first_launch".format(repo)))
        if repo in simulator_apps or not donor:
            aliases.append(alias("with_developer_dir_" + repo, "@{}//:with_developer_dir".format(repo)))
        else:
            script = "with_developer_dir_{}.sh".format(repo)
            rctx.file(
                script,
                _RUNNER_VIEW_WRAPPER_TEMPLATE.format(
                    name = repo,
                    developer_dir = str(developer_dirs[repo]),
                    donor_simulator_app = str(donor),
                ),
                executable = True,
            )
            aliases.append(sh_binary("with_developer_dir_" + repo, script))
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
        "xcode_repo_files": attr.label_list(
            doc = "A file in each Xcode repository, parallel to xcode_repos.",
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
