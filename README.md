# hermetic_apple_toolchains

Hermetic Bazel toolchains for building Apple platform applications **without an
installed Xcode**. Xcode toolchains (compilers and tools) and platform SDKs are
repackaged from downloaded `Xcode.app` bundles into independent, re-hostable
artifacts and combined into selectable "developer directories", so you can
build the same target against, say, the Xcode 26.5 toolchain + iOS 26.5 SDK or
the Xcode 27 beta toolchain + iOS 27 SDK — switching with a single flag.

```
bazel build //examples/ios_example --config=xcode26        # Xcode 26.5 toolchain + iOS 26.5 SDK
bazel build //examples/ios_example --config=xcode27beta2   # Xcode 27 beta 2 toolchain + iOS 27 SDK
# or directly:
bazel build //examples/ios_example --xcode_version=xcode27beta2
```

The full rule surface works, including asset catalogs (`actool`), Interface
Builder tools, and Core Data models — none of which are available from the
Command Line Tools alone.

## Creating artifacts

Point the repackaging script at a downloaded `Xcode.app` (it never needs to be
installed or launched — extracting the `.xip` is enough):

```
bazel run //scripts:create_hermetic_toolchain -- \
    --xcode_path ~/Downloads/Xcode-beta.app \
    --toolchain_output_path /path/to/out/toolchain \
    --sdk_output_path /path/to/out/sdks \
    [--simulator_output_path /path/to/out/simulators] \
    [--platforms iphoneos,iphonesimulator]
```

Outputs:

* **toolchain/** — `Xcode.app`: a slimmed, ad-hoc re-signed copy of the input
  Xcode. Only the requested platforms (plus macOS) are kept, the requested
  platforms' SDKs are removed (they are vendored separately and placed back at
  assembly time), and the bundled apps are dropped. ~3–4 GB.
* **sdks/** — one `<Platform><Version>.sdk` directory per requested platform.
  ~150 MB per OS release.
* **simulators/** — simulator runtime disk images, when available: runtimes
  bundled in the Xcode (old Xcodes) or an installed runtime image matching the
  Xcode's iOS version. Modern Xcode distributes runtimes separately; they are
  only needed to *run* apps, not to build them, and install with
  `xcrun simctl runtime add <image>.dmg`.

All three are plain directory trees, suitable for tarring and re-hosting on
servers you manage (subject to Apple's SLA — see Licensing).

## Why toolchains and SDKs are orthogonal

Xcode's toolchain and the platform SDKs are separate artifacts that Apple
happens to ship together. A newer toolchain can generally build against older
SDKs, while older toolchains generally cannot consume newer SDKs. This module
models that reality:

* **`apple.toolchain`** — a repackaged Xcode toolchain, from a local path or a
  re-hosted archive.
* **`apple.sdk`** — a set of platform SDKs for one OS release, from local
  paths or re-hosted archives.
* **`apple.developer_dir`** — pairs one toolchain with one SDK set into a
  developer directory selectable via `--xcode_version=<name>`.

## Usage

`MODULE.bazel`:

```starlark
bazel_dep(name = "hermetic_apple_toolchains", version = "0.0.0")

apple = use_extension("@hermetic_apple_toolchains//:extensions.bzl", "apple")
apple.toolchain(
    name = "xcode26_5",
    path = "/opt/hermetic/xcode_26_5/toolchain",
    # or: url = "https://mirror.example.com/xcode_26_5_toolchain.tar.zst", sha256 = "...",
)
apple.toolchain(
    name = "xcode27beta2",
    path = "/opt/hermetic/xcode_27_beta_2/toolchain",
)
apple.sdk(
    name = "ios26_5",
    paths = {
        "iphoneos": "/opt/hermetic/xcode_26_5/sdks/iPhoneOS26.5.sdk",
        "iphonesimulator": "/opt/hermetic/xcode_26_5/sdks/iPhoneSimulator26.5.sdk",
    },
    # or: urls = {...}, sha256s = {...},
)
apple.sdk(
    name = "ios27",
    paths = {
        "iphoneos": "/opt/hermetic/xcode_27_beta_2/sdks/iPhoneOS27.0.sdk",
        "iphonesimulator": "/opt/hermetic/xcode_27_beta_2/sdks/iPhoneSimulator27.0.sdk",
    },
)
apple.developer_dir(
    name = "xcode26_5_ios26_5",
    toolchain = "xcode26_5",
    sdk = "ios26_5",
    aliases = ["xcode26"],
    default = True,
)
apple.developer_dir(
    name = "xcode27beta2_ios27",
    toolchain = "xcode27beta2",
    sdk = "ios27",
    aliases = ["xcode27beta2"],
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

# Resolve Xcode through the hermetic developer directories. Both flags are
# needed while apple_support migrates off the native apple fragment.
build --xcode_version_config=@apple_toolchains//:xcode_config
build --@apple_support//xcode:starlark_version_config=@apple_toolchains//:xcode_config

# Convenience configs.
build:xcode26 --xcode_version=xcode26_5_ios26_5
build:xcode27beta2 --xcode_version=xcode27beta2_ios27
```

## How it works

Each `apple.developer_dir` pair is assembled into an external repository:

* **`Xcode.app`** — a copy of the toolchain's slimmed Xcode.app (an APFS
  clone: instant and free on the same volume) with the vendored SDKs placed
  inside its platform directories, re-sealed with an ad-hoc signature. This is
  load-bearing twice over: Xcode's designer tools (actool/ibtoold) resolve
  platforms, SDKs, plug-ins, and agents relative to the *app bundle containing
  their own binary* — no symlink-reconstructed layout satisfies them — and
  macOS Gatekeeper evaluates a *modified, unsealed* bundle pathologically
  slowly on first launch, while a re-sealed one starts in seconds.
* **`Developer/usr`** — a merged view (directories of symlinks) of the
  toolchain's `XcodeDefault.xctoolchain/usr` and the app's `Developer/usr`:
  the real compilers win name conflicts (the app's `ld` and friends are shims
  that fail outside an Xcode installation), while the app contributes the
  designer tools and `libxcrun`.
* **`CommandLineTools`** — the developer directory handed to Bazel:
  `usr → ../Developer/usr` plus the woven SDKs under `SDKs/`. The directory
  name matters: `xcode-select`'s library recognizes a developer directory as a
  Command Line Tools installation *by that name*, resolves tools from
  `usr/bin`, and — unlike an Xcode.app-style developer dir — never enforces
  the `xcodebuild -license` check, which would otherwise require root on
  every machine. Tools launched through these symlinks resolve (dyld realpaths
  the main executable) into the sealed `Xcode.app`, giving the designer tools
  the bundle context they need.

The repository defines an `xcode_version` target whose `version` is the
**absolute path** of the `CommandLineTools` directory. Bazel has first-class
support for this: when `XCODE_VERSION_OVERRIDE` starts with `/`, local
execution uses it directly as `DEVELOPER_DIR` (skipping discovery of installed
Xcodes) and resolves `SDKROOT` against it. apple_support, rules_swift, and
rules_apple treat a path-shaped Xcode version as "newest Xcode" for feature
checks, so the whole stack flows through.

The `@apple_toolchains//:xcode_config` hub lists every registered developer
directory, so `--xcode_version=<name-or-alias>` switches the entire build
(compilers, SDKs, asset catalog compilation, and the values stamped into
`Info.plist` such as `DTSDKName`/`DTSDKBuild`) to that pair.

## Where these artifacts come from

Findings on how Apple distributes each piece (macOS 26 / Xcode 26–27 era):

* **Xcode** ships as a `.xip` archive from developer.apple.com. Expanding the
  archive yields a fully functional `Xcode.app` that never needs to be
  installed, launched, or have its license accepted for this module's use.
* **SDKs** live *inside* `Xcode.app` at
  `Contents/Developer/Platforms/<Platform>.platform/Developer/SDKs`. They are
  plain directories.
* **Simulator runtimes** are distributed separately as cryptex disk images
  (Xcode Settings → Components, `xcodebuild -downloadPlatform iOS`, or
  developer.apple.com), registered with `xcrun simctl runtime add`, and only
  needed to *run* apps. An app built with the iOS 27 SDK and
  `minimum_os_version <= 26.5` runs on the iOS 26.5 runtime.
* **Command Line Tools** (not used by this module, but part of the original
  investigation): a dmg containing installer packages rooted at
  `/Library/Developer/CommandLineTools`. The CLT contain the compilers but not
  the designer tools (`actool`, `ibtool`, ...) nor the iOS Swift
  back-deployment libraries, which is why this module repackages full Xcodes
  instead.

## Example

`examples/ios_example` is an `ios_application` with an asset catalog that logs
the SDK it was built against and performs an `if #available(iOS 27.0, *)`
check at runtime. Built with the two configs above and launched on the same
iOS 26.5 simulator:

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

The binaries' `LC_BUILD_VERSION` records `sdk 26.5` / `sdk 27.0`, and the
compiled `Assets.car` records the hermetic Xcode that produced it
(`Xcode 26.5 (17F42)` / `Xcode 27.0 (27A5209h)`).

## Licensing

Apple's software license agreements do not permit redistributing Xcode or the
SDKs to parties who have not accepted them. However, individuals and
organizations who *have* accepted the agreements can re-host copies for their
own use (for example on internal mirrors) so that every fetch does not hit
Apple's servers. This module never downloads anything from Apple on your
behalf; you point it at artifacts you are licensed to use, and you must
acknowledge this by setting `--repo_env=ACCEPTED_APPLE_SLA=1`.

## Requirements and limitations

* Requires the `hermetic-developer-dirs` branches of
  [apple_support](https://github.com/AttilaTheFun/apple_support/tree/hermetic-developer-dirs)
  and
  [rules_apple](https://github.com/AttilaTheFun/rules_apple/tree/hermetic-developer-dirs)
  (small patches intended for upstreaming: an `extra_include_dirs` hook and
  path-valued Xcode version handling in apple_support's crosstool, symlink
  support in its layering-check module map, and an Xcode-free fallback for
  rules_apple's `environment_plist`).
* macOS host tools that are part of the OS are still used (`/usr/bin/xcrun`,
  `/usr/bin/codesign`, `/usr/bin/plutil`, `PlistBuddy`); these ship with
  macOS, not Xcode.
* The first action that runs a designer tool (actool) after a developer
  directory is (re)fetched pays a one-time ~10–15 s Gatekeeper evaluation of
  the re-sealed bundle.
* Local execution only for now: the generated `xcode_version` embeds the
  absolute path of the assembled developer directory on this machine.
* Repository-rule *detection* steps of apple_support/rules_swift still probe
  the host's default toolchain at fetch time (feature probes such as
  `ld -reproducible`); the build actions themselves use only the hermetic
  developer directory.
