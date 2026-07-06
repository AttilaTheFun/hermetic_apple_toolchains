# hermetic_apple_toolchains

[![CI](https://github.com/AttilaTheFun/hermetic_apple_toolchains/actions/workflows/ci.yml/badge.svg)](https://github.com/AttilaTheFun/hermetic_apple_toolchains/actions/workflows/ci.yml)

Build (and optionally run) Apple platform applications with Bazel using
**verbatim, re-hosted Xcode installations** — nothing installed via the App
Store or `xcode-select`, no Xcode ever opened. Bazel fetches and caches each
registered Xcode like any other dependency, and a single flag switches the
entire build between them:

```
bazel build //app:ios_app --xcode_version=xcode26_5
bazel run   //app:ios_app --config=xcode27beta2
```

Each registered Xcode is a complete, unmodified copy, so the full toolchain
works: compilers, linkers, asset catalogs (`actool`), Interface Builder,
Core Data models, and a fully functional `xcodebuild`. **SDKs ship inside
Xcode** (what Xcode's "install iOS platform support" dialog downloads is only
the *simulator runtime*), so registering an Xcode is all that's needed to
build — the simulator section below is optional and only needed to *run*
apps in a simulator.

## Xcode

### Preparing an Xcode

1. Download Xcode as a `.xip` from
   [developer.apple.com](https://developer.apple.com/download/all/) and
   expand it. The resulting `Xcode.app` never needs to be installed, opened,
   or moved to `/Applications`.
2. Either keep it on local disk, or archive and host it somewhere your
   organization controls:

   ```
   tar --create --file Xcode_26.5.tar.zst --options zstd:compression-level=6 \
       --use-compress-program=zstd -C /path/to/dir Xcode.app
   ```

   To export a verbatim copy from a machine that already has Xcode
   installed:
   
   ```
   bazel run @hermetic_apple_toolchains//scripts:create_hermetic_toolchain -- \
   --xcode_path /Applications/Xcode.app --xcode_output_path <dir>/Xcode.app
   ```

### Registering an Xcode

`MODULE.bazel`:

```starlark
bazel_dep(name = "hermetic_apple_toolchains", version = "0.0.0")

# The rules-based Apple CC toolchain and its extra_include_directories
# flag are not yet in a tagged apple_support release; pin upstream main
# until one is.
git_override(
    module_name = "apple_support",
    commit = "1a9b8c2bb405c080ccd1ab8a58071588606f27b2",
    remote = "https://github.com/bazelbuild/apple_support.git",
)

apple = use_extension("@hermetic_apple_toolchains//:extensions.bzl", "apple")
apple.xcode(
    name = "xcode26_5",
    path = "/opt/hermetic/xcode_26_5/Xcode.app",   # local copy, or:
    # url = "https://mirror.example.com/Xcode_26.5.tar.zst", sha256 = "...",
    default = True,
)
apple.xcode(
    name = "xcode27beta2",
    url = "https://mirror.example.com/Xcode_27_beta_2.tar.zst",
    sha256 = "...",
)
use_repo(apple, "apple_toolchains", "hermetic_swift_config")

# Replace rules_swift's autoconfigured toolchain (which probes *installed*
# Xcodes) with a hermetic equivalent. (No C++ toolchain override is needed:
# apple_support's rules-based toolchain is driven by the xcode_config at
# analysis time.)
swift_non_module_deps = use_extension("@rules_swift//swift:extensions.bzl", "non_module_deps")
override_repo(swift_non_module_deps, rules_swift_local_config = "hermetic_swift_config")
```

`.bazelrc`:

```
# Use apple_support's rules-based CC toolchain (no fetch-time probing of
# installed Xcodes; a path-valued Xcode version becomes DEVELOPER_DIR).
common --repo_env=APPLE_SUPPORT_RULES_BASED_TOOLCHAIN=1

# Resolve Xcode through the registered hermetic Xcodes. (Both flags are
# needed while apple_support migrates off Bazel's native apple fragment.)
build --xcode_version_config=@apple_toolchains//:xcode_config
build --@apple_support//xcode:starlark_version_config=@apple_toolchains//:xcode_config

# Allowlist the hermetic developer directories for include validation.
build --@apple_support//toolchain:extra_include_directories=@apple_toolchains//:xcode_include_directories

# Convenience configs per Xcode.
build:xcode26 --xcode_version=xcode26_5
build:xcode27beta2 --xcode_version=xcode27beta2
```

### Using an Xcode

Each Xcode requires some one-time per-machine setup: accepting the Xcode
license (once per machine and license agreement revision; GM and Beta
agreements are tracked separately by macOS), and — when simulator runtimes
or components are registered — installing them. Two runnables manage all
of it:

```
bazel run @apple_toolchains//:check_xcode26_5     # report setup status (exits non-zero if anything is needed)
bazel run @apple_toolchains//:prepare_xcode26_5   # run only the needed steps (may prompt for sudo)
```

`check` prints one `[ok]`/`[needed]` line per step without changing
anything; `prepare` performs the same checks and runs just the steps that
are needed (vendored runtimes and components are only fetched when their
step actually runs). Tell developers to run `prepare` once per machine,
and again after a new Xcode, runtime, or component is registered; `check`
is handy for diagnostics and CI probes.

After that, build normally; `--xcode_version=<name or alias>` (or your
configs) selects the Xcode, and everything — compilers, SDKs, resource
tools, and the `DTXcode`/`DTSDKBuild` values stamped into `Info.plist` —
follows it. Each Xcode also answers to its version and build numbers (for
example `--xcode_version=26.5` or `17F42`) in addition to its name and
aliases.

Building for simulator and device both work with just the above. Running on
a physical device uses your normal signing/provisioning setup.

To open an Xcode's GUI (for example to use Instruments or browse
documentation), run its bare name:

```
bazel run @apple_toolchains//:xcode27beta2
```

The runnable also pre-records the GUI's one-time first-launch state (the
"Select platforms to develop for" sheet and the "What's New in Xcode"
splash), so the Xcode opens without prompting — simulator runtimes and the
Metal Toolchain are provided by their tags instead.

### Running tools against a hermetic Xcode

The `with_developer_dir_<xcode>` target runs any command with
`DEVELOPER_DIR` pointing at that hermetic Xcode. It exists for two
purposes:

1. **`bazel run` launchers** (its role in the `.bazelrc` configs above):
   `--xcode_version` only governs build actions. Tools that run *after*
   the build — rules_apple's simulator runner, rules_xcodeproj's project
   generator — discover Xcode themselves via `xcode-select -p`, which
   honors `DEVELOPER_DIR`. The `--run_under` wrapper points them at the
   hermetic Xcode instead of whatever the host has selected.

2. **Ad-hoc commands**, without ever needing to know where Bazel cached
   the Xcode:

   ```
   bazel run @apple_toolchains//:with_developer_dir_xcode27beta2 -- xcrun simctl list devices
   bazel run @apple_toolchains//:with_developer_dir_xcode26_5 -- xcrun --sdk iphonesimulator --show-sdk-path
   bazel run @apple_toolchains//:with_developer_dir_xcode27beta2 -- $SHELL
   ```

   The last form spawns an interactive shell in which every `xcrun`,
   `xcodebuild`, and `simctl` resolves through the hermetic Xcode — handy
   for exploratory work without per-command Bazel overhead.

Note that `bazel run` executes from the runfiles tree, so relative paths
in the command's arguments do not resolve against your shell's working
directory: use absolute paths (or the shell form, and `cd` afterwards).
For Xcode 27+ the wrapper also exposes a `Simulator.app` borrowed from
another registered Xcode, since the beta no longer bundles one.

### Metal Toolchain (optional)

Since Xcode 26, the Metal shader compiler is a separate download — it's the
"components" the Xcode GUI prompts to install on first launch, and `metal`
invocations fail without it. Only needed if you compile Metal shaders (or
want the GUI to open without prompting); each Xcode build wants its own
component build.

Vendor it from an Xcode whose license is accepted:

```
bazel run @hermetic_apple_toolchains//scripts:create_hermetic_toolchain -- \
    --xcode_path /path/to/Xcode.app \
    --component_output_path <dir> \
    --download_component MetalToolchain
```

This produces `<dir>/MetalToolchain_<xcode build>.exportedBundle` (a
directory; archive it to re-host). Register it:

```starlark
apple.component(
    name = "metal_toolchain_27",
    path = "/opt/hermetic/xcode_27/components/MetalToolchain_27A5209h.exportedBundle",
    # or url = "https://mirror.example.com/MetalToolchain_27A5209h.tar.zst", sha256 = "...",
    xcode = "xcode27beta2",
)
```

`prepare_<xcode>` installs it when needed, along with the rest of the
one-time setup.

### Xcode projects (rules_xcodeproj)

Generated projects work with hermetic Xcodes: rules_xcodeproj selects the
Xcode to build with by build number (for example `17F42`), which hermetic
Xcodes accept. Give top-level targets
`visibility = ["@rules_xcodeproj//xcodeproj:generated"]`, and set one
attribute explicitly, since its default derives from the resolved Xcode's
"version" — which is a path for hermetic Xcodes:

```starlark
xcodeproj(
    name = "xcodeproj",
    minimum_xcode_version = "26.0",   # required with hermetic Xcodes
    project_name = "my_app",
    top_level_targets = [...],
)
```

Generate the project with `bazel run //my_app:xcodeproj`, then open it in
the hermetic Xcode (`bazel run @apple_toolchains//:xcode26_5`) or build it
headlessly with the hermetic `xcodebuild`. See
`examples/ios_example/BUILD.bazel` for a working target.

## Simulator (optional)

Only needed to *run* apps in a simulator on a machine without Xcode
installed. Skip this section if you only build, or run on devices.

Simulator runtimes are disk images distributed separately from Xcode; note
that an app built with a newer SDK runs on an older runtime as long as its
minimum OS version allows (for example, an iOS 27 SDK build with
`minimum_os_version = 26.0` runs on the iOS 26.5 runtime).

### Preparing a simulator runtime

Download the runtime matching an Xcode and export it as a re-hostable image
(~8 GB; requires that the Xcode's license has been accepted):

```
bazel run @hermetic_apple_toolchains//scripts:create_hermetic_toolchain -- \
    --xcode_path /path/to/Xcode.app \
    --simulator_output_path <dir> \
    --download_platform iOS
```

This produces `<dir>/iOS_<version>_<build>.dmg`, which you can host next to
your Xcode archives. (Without `--download_platform`, the script instead
exports runtimes already present on the machine: images bundled inside old
Xcodes, or the installed runtime matching the Xcode's iOS version.)

### Registering a simulator runtime

```starlark
apple.simulator_runtime(
    name = "ios27_runtime",
    url = "https://mirror.example.com/iOS_27.0_24A5370g.dmg",  # or path = "..."
    sha256 = "...",
    # Which registered Xcode performs the registration (defaults to the
    # default Xcode).
    xcode = "xcode27beta2",
)
```

And per Xcode config in `.bazelrc`, point `bazel run` launchers (such as
rules_apple's simulator runner) at the hermetic Xcode and runtime:

```
run:xcode26 --run_under=@apple_toolchains//:with_developer_dir_xcode26_5
run:xcode26 --ios_simulator_version=26.5
run:xcode27beta2 --run_under=@apple_toolchains//:with_developer_dir_xcode27beta2
run:xcode27beta2 --ios_simulator_version=27.0
```

### Using a simulator runtime

Registering an `apple.simulator_runtime` tag adds two steps to the Xcode's
`prepare_<xcode>` runnable: installing the Xcode generation's simulator
system components (CoreSimulator framework; prompts for sudo — required
before beta runtimes will boot on a machine that has only seen older
Xcodes, since `xcodebuild -runFirstLaunch` alone never upgrades across
Xcode generations), and registering the runtime with CoreSimulator (macOS
shows an admin authorization dialog on first registration). So once per
machine:

```
bazel run @apple_toolchains//:prepare_xcode27beta2
```

Then `bazel run //app:ios_app --config=xcode27beta2` boots a simulator on
the matching runtime, installs the app, launches it, and streams its logs.

Note for Xcode 27+: the Simulator GUI (`Simulator.app`) no longer ships
inside the Xcode bundle, but rules_apple's runner launches it from there.
The `with_developer_dir_<name>` wrapper transparently borrows
`Simulator.app` from another registered Xcode that has one — so to `bazel
run` apps under an Xcode 27 toolchain, also register an Xcode 26.x.

## Licensing

Apple's license agreements do not permit redistributing Xcode or its
components to parties who have not accepted them; organizations that *have*
accepted them may re-host copies for their own use. This module never
downloads anything from Apple on your behalf — you point it at artifacts you
are licensed to use, and each machine accepts the Xcode license itself (the
`prepare_<xcode>` runnable's first step), exactly as with an installed
Xcode.

## Notes and limitations

* macOS host tools that ship with the OS are still used (`/usr/bin/xcrun`,
  `/usr/bin/codesign`, `/usr/bin/plutil`).
* Local execution only for now: the generated Xcode selection embeds
  absolute paths from this machine's Bazel output base.
* rules_swift's fetch-time feature probes still consult the host's default
  toolchain; build actions use only the hermetic Xcode.
* Xcodes are fetched as full copies (APFS clones when local — effectively
  free; ~10 GB downloads when remote, cached by Bazel across builds).
