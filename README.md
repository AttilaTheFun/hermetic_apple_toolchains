# hermetic_apple_toolchains

Hermetic Bazel toolchains for building Apple platform applications from
**verbatim, re-hosted Xcode installations** — no Xcode ever needs to be
installed, launched, or discovered on the host. Check out a repository,
accept the license once, and `bazel run` an iOS app in a simulator; Bazel
fetches and caches the Xcode like any other dependency.

```
bazel build //examples/ios_example --config=xcode26        # Xcode 26.5
bazel run //examples/ios_example --config=xcode27beta2     # build + launch in a simulator
# or directly:
bazel build //examples/ios_example --xcode_version=xcode27beta2
```

Because each registered Xcode is a complete, unmodified copy, the full rule
surface works: compilers, linkers, asset catalogs (`actool`), Interface
Builder tools, Core Data models, and a fully functional `xcodebuild`.

A note on SDKs: modern Xcode ships **all platform SDKs inside the app** —
what Xcode's "install iOS platform support" dialog downloads is only the
*simulator runtime*. So registering an Xcode registers its SDKs, and the
runtime is the one additional artifact, handled by `apple.simulator_runtime`
below.

## Registering Xcodes

Xcode ships as a `.xip` from developer.apple.com; expanding the archive
yields a complete `Xcode.app` that never needs to be installed or opened.
Re-host it (for example as a `.tar.gz` on servers you manage) or keep it on
local disk, and register it:

```starlark
bazel_dep(name = "hermetic_apple_toolchains", version = "0.0.0")

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

# Simulator runtimes: only needed to *run* apps in a simulator. The xcode
# attribute selects which hermetic Xcode registers the runtime with
# CoreSimulator.
apple.simulator_runtime(
    name = "ios27_runtime",
    url = "https://mirror.example.com/iOS_27.0_24A5370g.dmg",
    sha256 = "...",
    xcode = "xcode27beta2",
)
use_repo(apple, "apple_toolchains", "hermetic_apple_cc", "hermetic_swift_config")

# Replace apple_support's autodetected C++ toolchain with one that allows
# builtin includes from the hermetic repositories.
apple_cc = use_extension("@apple_support//crosstool:setup.bzl", "apple_cc_configure_extension")
override_repo(apple_cc, local_config_apple_cc = "hermetic_apple_cc")

# Replace rules_swift's autoconfigured toolchain, which wires in explicit
# system modules selected by the *installed* Xcode versions.
swift_non_module_deps = use_extension("@rules_swift//swift:extensions.bzl", "non_module_deps")
override_repo(swift_non_module_deps, rules_swift_local_config = "hermetic_swift_config")
```

`.bazelrc`:

```
# You must have accepted Apple's software license agreements to use these
# artifacts (see Licensing below).
common --repo_env=ACCEPTED_APPLE_SLA=1

# Resolve Xcode through the hermetic Xcodes. Both flags are needed while
# apple_support migrates off the native apple fragment.
build --xcode_version_config=@apple_toolchains//:xcode_config
build --@apple_support//xcode:starlark_version_config=@apple_toolchains//:xcode_config

# Convenience configs.
build:xcode26 --xcode_version=xcode26_5
build:xcode27beta2 --xcode_version=xcode27beta2
```

One-time machine setup per Xcode / runtime (all runnables are idempotent or
safe to re-run):

```
# Accept the Xcode license (prompts for sudo; once per machine and license
# agreement revision — GM and Beta agreements are tracked separately).
bazel run @apple_toolchains//:accept_license_xcode27beta2

# Install the Xcode generation's system support components (CoreSimulator
# framework and friends; prompts for sudo). Needed on machines that have
# never installed an Xcode of this generation — in particular, *beta*
# simulator runtimes require the beta's CoreSimulator components.
bazel run @apple_toolchains//:first_launch_xcode27beta2

# Register the simulator runtime with CoreSimulator (no-op when a runtime
# with that build is already registered; macOS shows an admin authorization
# prompt — "xcodebuild is trying to install Apple software" — on first
# registration).
bazel run @apple_toolchains//:install_runtime_ios27_runtime
```

After that, `bazel run //your:ios_application --config=...` builds the app
with the hermetic Xcode, boots a simulator on the matching runtime, launches
the app, and streams its logs; the `run:` config options in `.bazelrc` point
rules_apple's simulator runner at the hermetic Xcode via a `--run_under`
wrapper (`@apple_toolchains//:with_developer_dir_<name>`).

## Exporting artifacts from a machine that has them

`bazel run //scripts:create_hermetic_toolchain` copies an Xcode verbatim
(APFS clone: instant on the same volume) and exports simulator runtime
images for re-hosting:

```
bazel run //scripts:create_hermetic_toolchain -- \
    --xcode_path /Applications/Xcode.app \
    --xcode_output_path /path/to/out/Xcode.app \
    --simulator_output_path /path/to/out/simulators
```

Simulator runtimes are only needed to *run* apps: they are cryptex disk
images distributed separately from Xcode, installed with
`xcrun simctl runtime add <image>.dmg`, and an app built with a newer SDK
runs on an older runtime as long as its minimum OS version allows.

## How it works

Each `apple.xcode` repository contains a verbatim copy of the Xcode.app (an
APFS clone when the source is on the same volume — instant and effectively
free; a symlink would leak the source path into `SDKROOT` because xcrun
canonicalizes). Keeping the bundle unmodified is deliberate:

* It preserves Apple's notarized seal, so Gatekeeper's first-launch
  evaluation takes the fast path. (A modified bundle without a fresh seal is
  evaluated pathologically slowly — it looks like a hang.)
* Xcode's designer tools (actool/ibtoold) resolve platforms, SDKs,
  plug-ins, and agents relative to the app bundle containing their own
  binary; a real, complete bundle is the only layout that fully satisfies
  them.

The repository defines an `xcode_version` target whose `version` is the
**absolute path** of `Xcode.app/Contents/Developer`. Bazel has first-class
support for this: when `XCODE_VERSION_OVERRIDE` starts with `/`, local
execution uses it directly as `DEVELOPER_DIR` (skipping discovery of
installed Xcodes) and resolves `SDKROOT` against it. apple_support,
rules_swift, and rules_apple treat a path-shaped Xcode version as "newest
Xcode" for feature checks, so the whole stack flows through unmodified.

The `@apple_toolchains//:xcode_config` hub lists every registered Xcode, so
`--xcode_version=<name-or-alias>` switches the entire build — compilers,
SDKs, asset catalog compilation, and the values stamped into `Info.plist`
(`DTSDKName`, `DTSDKBuild`, `DTXcode`, `DTXcodeBuild`) — to that Xcode.

## Example

`examples/ios_example` is an `ios_application` with an asset catalog that
logs the SDK it was built against and performs an
`if #available(iOS 27.0, *)` check at runtime. Built with the two configs
above and launched on the same iOS 26.5 simulator:

```
[hermetic] built against SDK: iphonesimulator26.5 (build 23F73)
[hermetic] if #available(iOS 27.0): not available, running on an older runtime
[hermetic] runtime OS: Version 26.5 (Build 23F77)
```

```
[hermetic] built against SDK: iphonesimulator27.0 (build 24A5370g)
[hermetic] if #available(iOS 27.0): not available, running on an older runtime
[hermetic] runtime OS: Version 26.5 (Build 23F77)
```

The binaries' `LC_BUILD_VERSION` records the SDK they were built with, and
the compiled `Assets.car` records the hermetic Xcode that produced it.

## Licensing

Apple's software license agreements do not permit redistributing Xcode to
parties who have not accepted them. However, individuals and organizations
who *have* accepted the agreements can re-host copies for their own use (for
example on internal mirrors) so that every fetch does not hit Apple's
servers. This module never downloads anything from Apple on your behalf; you
point it at artifacts you are licensed to use, and you must acknowledge this
by setting `--repo_env=ACCEPTED_APPLE_SLA=1`. Additionally, each machine must
accept the Xcode license agreement itself (`:accept_license_<name>`), exactly
as with an installed Xcode.

## Requirements and limitations

* Requires the `hermetic-developer-dirs` branch of
  [apple_support](https://github.com/AttilaTheFun/apple_support/tree/hermetic-developer-dirs):
  two small changes intended for upstreaming (an `extra_include_dirs` hook in
  the crosstool configuration, and path-valued Xcode version handling in two
  feature checks — following the same convention Apple contributed to
  `xcode_support` and rules_swift). No rules_apple or rules_swift changes are
  needed. Until the changes land upstream, consumers add:

  ```starlark
  git_override(
      module_name = "apple_support",
      remote = "https://github.com/AttilaTheFun/apple_support.git",
      commit = "92ebd80ca6a43335e8453e9640dee100bf1291f8",
  )
  ```
* One-time, per-machine `sudo` for the license acceptance of each new
  agreement revision.
* macOS host tools that are part of the OS are still used (`/usr/bin/xcrun`,
  `/usr/bin/codesign`, `/usr/bin/plutil`); these ship with macOS, not Xcode.
* Local execution only for now: the generated `xcode_version` embeds the
  absolute path of the repository's Xcode on this machine.
* Repository-rule *detection* steps of apple_support/rules_swift still probe
  the host's default toolchain at fetch time (feature probes such as
  `ld -reproducible`); the build actions themselves use only the hermetic
  Xcode.
