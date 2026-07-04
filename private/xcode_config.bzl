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
# bundle verbatim (and its notarized seal intact), and mirrors the
# Xcode.app/Contents/Developer layout: tools validate the app-style shape
# (rules_xcodeproj reads ../version.plist, xcrun keys license enforcement
# off the .app path).
_RUNNER_VIEW_WRAPPER_TEMPLATE = """\
#!/bin/bash
DEV="{developer_dir}"
if [[ ! -e "$DEV/Applications/Simulator.app" ]]; then
  APP="{app}"
  VIEW="${{TMPDIR:-/tmp}}/hermetic_xcode_runner_view_{name}/Xcode.app"
  mkdir -p "$VIEW/Contents/Developer/Applications"
  for entry in "$APP/Contents"/*; do
    base="$(basename "$entry")"
    if [[ "$base" != "Developer" ]]; then
      ln -sfn "$entry" "$VIEW/Contents/$base"
    fi
  done
  for entry in "$DEV"/*; do
    base="$(basename "$entry")"
    if [[ "$base" != "Applications" ]]; then
      ln -sfn "$entry" "$VIEW/Contents/Developer/$base"
    fi
  done
  if [[ -d "$DEV/Applications" ]]; then
    for entry in "$DEV/Applications"/*; do
      ln -sfn "$entry" "$VIEW/Contents/Developer/Applications/$(basename "$entry")"
    done
  fi
  ln -sfn "{donor_simulator_app}" "$VIEW/Contents/Developer/Applications/Simulator.app"
  DEV="$VIEW/Contents/Developer"
fi
export DEVELOPER_DIR="$DEV"
exec "$@"
"""

# check_<xcode> script pieces. Assembled per Xcode from the header, the
# optional simulator-components block, and one block per associated
# simulator runtime and component.
_CHECK_HEADER = """\
#!/bin/bash
#
# Reports the status of the one-time per-machine setup steps for the
# hermetic Xcode {name}. Exits non-zero when any step is still needed;
# `bazel run @apple_toolchains//:prepare_{name}` runs the needed steps.

APP="{app}"
DEV="$APP/Contents/Developer"
needed=0

ok() {{ printf '  [ok]     %s\\n' "$1"; }}
needs() {{ printf '  [needed] %s\\n' "$1"; needed=1; }}
info() {{ printf '  [info]   %s\\n' "$1"; }}

echo "Hermetic Xcode {name} ($APP)"

license_type=$(defaults read "$APP/Contents/Resources/LicenseInfo" licenseType 2>/dev/null || echo "GM")
license_id=$(defaults read "$APP/Contents/Resources/LicenseInfo" licenseID 2>/dev/null || echo "unknown")
agreed=$(defaults read /Library/Preferences/com.apple.dt.Xcode \\
    "IDELast${{license_type}}LicenseAgreedTo" 2>/dev/null || true)
if [[ "$license_id" == "$agreed" ]]; then
  ok "license $license_id ($license_type) accepted"
else
  needs "license $license_id ($license_type) not accepted: bazel run @apple_toolchains//:accept_license_{name}"
fi
"""

_CHECK_FIRST_LAUNCH = """\

PKG="$APP/Contents/Resources/Packages/XcodeSystemResources.pkg"
shipped=$(cd "$(mktemp -d)" && /usr/bin/xar -xf "$PKG" PackageInfo 2>/dev/null && \\
    grep -o 'version="[0-9][0-9.]*"' PackageInfo | grep -o '[0-9][0-9.]*' | sort -V | tail -1)
installed=$(pkgutil --pkg-info com.apple.pkg.XcodeSystemResources 2>/dev/null | \\
    sed -n 's/^version: //p')
installed="${{installed:-0}}"
if [[ "$(printf '%s\\n%s\\n' "$shipped" "$installed" | sort -V | tail -1)" == "$installed" ]]; then
  ok "Xcode system components $installed (this Xcode ships $shipped)"
else
  needs "system components $installed older than shipped $shipped: bazel run @apple_toolchains//:first_launch_{name}"
fi
"""

_CHECK_RUNTIME = """\

if env DEVELOPER_DIR="$DEV" /usr/bin/xcrun simctl runtime list 2>/dev/null | \\
    grep "({build})" | grep -q "(Ready)"; then
  ok "simulator runtime {runtime} ({build}) registered"
else
  needs "simulator runtime {runtime} not registered: bazel run @apple_toolchains//:install_runtime_{runtime}"
fi
"""

_CHECK_RUNTIME_UNKNOWN = """\

info "simulator runtime {runtime}: build not derivable from the image name; install_runtime_{runtime} is idempotent"
"""

_CHECK_COMPONENT = """\

if env DEVELOPER_DIR="$DEV" "$DEV/usr/bin/xcodebuild" -showComponent {component_type} -json 2>/dev/null | \\
    grep -q '"status" : "installed"'; then
  ok "component {component} ({component_type}) installed"
else
  needs "component {component} ({component_type}) not installed: bazel run @apple_toolchains//:install_component_{component}"
fi
"""

_CHECK_FOOTER = """\

exit $needed
"""

_PREPARE_TEMPLATE = """\
#!/bin/bash
#
# Runs the one-time per-machine setup steps for the hermetic Xcode {name}.
# Every step is idempotent; steps that are already done no-op quickly.

set -euo pipefail

if [[ -z "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then
  echo "Run this with: bazel run @apple_toolchains//:prepare_{name}" >&2
  exit 1
fi
cd "$BUILD_WORKING_DIRECTORY"

{steps}"""

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
        app = str(developer_dirs[repo].dirname.dirname)

        # Runtimes and components associated with this Xcode, as
        # (repo name, build or component type) pairs.
        runtimes = [
            (name, info[1])
            for name, info in sorted(rctx.attr.simulator_runtime_repos.items())
            if info[0] == repo
        ]
        components = [
            (name, info[1])
            for name, info in sorted(rctx.attr.component_repos.items())
            if info[0] == repo
        ]

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
                    app = app,
                    developer_dir = str(developer_dirs[repo]),
                    donor_simulator_app = str(donor),
                ),
                executable = True,
            )
            aliases.append(sh_binary("with_developer_dir_" + repo, script))

        # `check_<xcode>` reports the one-time per-machine setup status;
        # `prepare_<xcode>` runs the needed steps (license, simulator
        # system components when runtimes are registered, runtime and
        # component installation).
        check = _CHECK_HEADER.format(name = repo, app = app)
        steps = ["accept_license_" + repo]
        if runtimes:
            check += _CHECK_FIRST_LAUNCH.format(name = repo)
            steps.append("first_launch_" + repo)
        for name, build in runtimes:
            if build:
                check += _CHECK_RUNTIME.format(runtime = name, build = build)
            else:
                check += _CHECK_RUNTIME_UNKNOWN.format(runtime = name)
            steps.append("install_runtime_" + name)
        for name, component_type in components:
            check += _CHECK_COMPONENT.format(
                component = name,
                component_type = component_type,
            )
            steps.append("install_component_" + name)
        check += _CHECK_FOOTER

        rctx.file("check_{}.sh".format(repo), check, executable = True)
        aliases.append(sh_binary("check_" + repo, "check_{}.sh".format(repo)))
        rctx.file(
            "prepare_{}.sh".format(repo),
            _PREPARE_TEMPLATE.format(
                name = repo,
                steps = "".join([
                    'echo "==> {}"\nbazel run @apple_toolchains//:{}\n'.format(step, step)
                    for step in steps
                ]),
            ),
            executable = True,
        )
        aliases.append(sh_binary("prepare_" + repo, "prepare_{}.sh".format(repo)))

    for repo in sorted(rctx.attr.simulator_runtime_repos.keys()):
        aliases.append(alias("install_runtime_" + repo, "@{}//:install".format(repo)))
    for repo in sorted(rctx.attr.component_repos.keys()):
        aliases.append(alias("install_component_" + repo, "@{}//:install".format(repo)))

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
        "simulator_runtime_repos": attr.string_list_dict(
            doc = "Simulator runtime repository name -> [xcode repo, runtime build or ''].",
        ),
        "component_repos": attr.string_list_dict(
            doc = "Component repository name -> [xcode repo, component type].",
        ),
        "default_xcode_repo": attr.string(
            doc = "Xcode used when --xcode_version is not passed.",
            mandatory = True,
        ),
    },
)
