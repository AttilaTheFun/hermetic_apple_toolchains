# hermetic_apple_toolchains

Hermetic Bazel toolchains for building Apple platform applications **without a
full Xcode installation**. Xcode toolchains (compilers) and platform SDKs are
registered as independent, orthogonal artifacts and combined into selectable
"developer directories", so you can build the same target against, say, the
iOS 26.5 SDK with the Xcode 26 toolchain or the iOS 27 beta SDK with the
Xcode 27 beta toolchain — switching with a single flag.

```
bazel build //examples/ios_example --config=xcode26        # CLT 26 + iOS 26.5 SDK
bazel build //examples/ios_example --config=xcode27beta2   # CLT 27 beta 2 + iOS 27 SDK
# or directly:
bazel build //examples/ios_example --xcode_version=xcode27beta2
```

## Why toolchains and SDKs are orthogonal

Xcode's compiler toolchain and the platform SDKs are separate artifacts that
Apple happens to ship together. A newer Xcode can generally build against
older SDKs, while older toolchains generally cannot consume newer SDKs. This
module models that reality:

* **`apple.toolchain`** — a compiler toolchain in Apple *Command Line Tools*
  layout (`usr/bin/clang`, `usr/bin/swiftc`, bundled macOS SDKs). Sourced from
  a local directory, a Command Line Tools `.dmg` straight from Apple (or your
  own mirror), or a re-hosted archive.
* **`apple.sdk`** — a set of platform SDKs for one OS release (for example
  `iPhoneOS26.5.sdk` + `iPhoneSimulator26.5.sdk`). Sourced from local paths
  (for example inside an extracted `Xcode.app`) or re-hosted archives.
* **`apple.developer_dir`** — pairs one toolchain with one SDK set into a
  developer directory that is selectable via `--xcode_version=<name>`.

## Usage

`MODULE.bazel`:

```starlark
bazel_dep(name = "hermetic_apple_toolchains", version = "0.0.0")

apple = use_extension("@hermetic_apple_toolchains//:extensions.bzl", "apple")
apple.toolchain(
    name = "xcode26",
    # Any Command Line Tools style directory works:
    path = "/Library/Developer/CommandLineTools",
)
apple.toolchain(
    name = "xcode27beta2",
    # Or a Command Line Tools dmg, re-hosted on servers you manage
    # (file://, https://, gs:// via a downloader config, ...):
    url = "https://mirror.example.com/Command_Line_Tools_27_beta_2.dmg",
    sha256 = "...",
)
apple.sdk(
    name = "ios26_5",
    paths = {
        "iphoneos": "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk",
        "iphonesimulator": "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
    },
)
apple.sdk(
    name = "ios27",
    urls = {
        "iphoneos": "https://mirror.example.com/iPhoneOS27.0.sdk.tar.zst",
        "iphonesimulator": "https://mirror.example.com/iPhoneSimulator27.0.sdk.tar.zst",
    },
    sha256s = {...},
)
apple.developer_dir(
    name = "xcode26_ios26_5",
    toolchain = "xcode26",
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
build:xcode26 --xcode_version=xcode26_ios26_5
build:xcode27beta2 --xcode_version=xcode27beta2_ios27
```

## How it works

Each `apple.developer_dir` pair is assembled into an external repository
containing a directory literally named `CommandLineTools`:

```
CommandLineTools/
├── usr      -> (toolchain repository)/usr
├── Library  -> (toolchain repository)/Library
└── SDKs/
    ├── iPhoneOS26.5.sdk          -> (SDK repository)
    ├── iPhoneSimulator26.5.sdk   -> (SDK repository)
    └── MacOSX.sdk                -> (toolchain repository, for exec tools)
```

The directory name matters: `xcode-select`'s library — used by
`/usr/bin/xcrun`, which nearly everything in the Apple build stack shells out
through — recognizes a developer directory as a Command Line Tools
installation *by that name* and resolves tools from `usr/bin` and SDKs from
`SDKs/` inside it, with no Xcode.app required.

The repository also generates an `xcode_version` target whose `version` is the
**absolute path** of that directory. Bazel has first-class support for this:
when `XCODE_VERSION_OVERRIDE` starts with `/`, local execution uses it
directly as `DEVELOPER_DIR` (skipping discovery of installed Xcodes entirely)
and resolves `SDKROOT` with `xcrun --sdk <platform> --show-sdk-path` against
it. apple_support, rules_swift, and rules_apple already treat a path-shaped
Xcode version as "newest Xcode" for feature checks, so the whole stack flows
through with a hermetic developer directory.

The `@apple_toolchains//:xcode_config` hub lists every registered developer
directory, so `--xcode_version=<name-or-alias>` switches the entire build
(compilers, SDKs, and the values stamped into `Info.plist`, such as
`DTSDKName` and `DTSDKBuild`) to that pair.

## Repackaging a full Xcode (asset catalogs, ibtool, momc, ...)

The Command Line Tools contain the compilers but not Xcode's designer tools
(`actool`, `ibtool`, `momc`, ...), so asset catalogs cannot be built with a
CLT-based toolchain. To lift that restriction, repackage a downloaded
`Xcode.app` (it never needs to be installed or launched) into hermetic
artifacts:

```
bazel run //scripts:create_hermetic_toolchain -- \
    --xcode_path ~/Downloads/Xcode-beta.app \
    --toolchain_output_path /path/to/out/toolchain \
    --sdk_output_path /path/to/out/sdks \
    [--simulator_output_path /path/to/out/simruntimes] \
    [--platforms iphoneos,iphonesimulator]
```

The toolchain output (~2 GB) contains the `XcodeDefault.xctoolchain` compilers
merged with the Xcode developer tools, the framework roots those tools load
their implementations from (`Frameworks`, `SharedFrameworks`, `PlugIns`), the
Xcode agents (`AssetCatalogAgent`), and the platform directories minus their
SDKs — wrapped in an `Xcode.app/Contents` shell so all of the tools'
bundle-relative rpaths resolve, with a top-level `usr` symlink for Command
Line Tools layout compatibility. The SDK output contains the platform SDKs as
plain directories. Both are self-contained, relocatable, and suitable for
tarring and re-hosting; register them with the same `apple.toolchain(path/url
= ...)` and `apple.sdk(...)` tags as any other artifact.

Compared to a CLT toolchain, a repackaged Xcode toolchain additionally
provides working `actool`/`ibtool` (see `//examples/ios_example:
ios_example_assets`) and the Swift back-deployment libraries for all
platforms. Two integration details make the designer tools work outside a
real Xcode installation: platform definitions are discovered through
`DEVELOPER_DIR`'s `Platforms` directory (which the assembled developer dir
provides), and Interface Builder's platform support plug-ins are discovered
through `DVTExtraPlugInPaths`, which rules_apple's `xctoolrunner` (patched on
the fork branch) points at the `PlugIns` directory that the assembly places
next to `CommandLineTools`.

## Where these artifacts come from

Findings on how Apple distributes and installs each piece (macOS 26 / Xcode
26–27 era):

* **Command Line Tools** ship as a `.dmg` (from
  developer.apple.com/download/all) containing a single distribution installer
  package. Its component packages (`CLTools_Executables`,
  `CLTools_macOS_SDK`, `CLTools_SwiftBackDeploy`, ...) all install under
  `/Library/Developer/CommandLineTools`. This module's `apple.toolchain(url =
  "....dmg")` mounts the image and expands those payloads into a repository
  without installing anything system-wide (`hdiutil attach` + `pkgutil
  --expand-full`), so nothing touches `/Library` and no `sudo` is needed.
* **Device SDKs** (for example `iPhoneOS27.0.sdk`) ship *inside* `Xcode.app`
  at `Contents/Developer/Platforms/<Platform>.platform/Developer/SDKs`. They
  are plain directories and can be vendored as-is; that is what `apple.sdk`
  consumes. Xcode itself ships as a `.xip` archive, so an SDK can be pulled
  out of an expanded archive without ever installing or launching Xcode.
* **"Platform support" downloads** (Xcode's Settings → Components, or
  `xcodebuild -downloadPlatform iOS`) are the *simulator runtimes*: cryptex
  disk images downloaded from Apple's CDN and registered with
  `xcrun simctl runtime add`, stored under `/Library/Developer/CoreSimulator`.
  They are only needed to *run* apps in a simulator, not to build them, so
  they are out of scope for the build toolchain. Note that an app built with
  the iOS 27 SDK and `minimum_os_version <= 26.5` runs fine on the iOS 26.5
  simulator runtime.

## Example

`examples/ios_example` is an `ios_application` that logs the SDK it was built
against and performs an `if #available(iOS 27.0, *)` check at runtime. Built
with the two configs above and launched on the same iOS 26.5 simulator:

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

The `LC_BUILD_VERSION` load command of the produced binaries records
`sdk 26.5` and `sdk 27.0` respectively.

## Licensing

Apple's software license agreements do not permit redistributing Xcode, the
Command Line Tools, or the SDKs to parties who have not accepted them.
However, individuals and organizations who *have* accepted the agreements can
re-host copies for their own use (for example on internal mirrors or GCS
buckets) so that every fetch does not hit Apple's servers. This module never
downloads anything from Apple on your behalf; you point it at artifacts you
are licensed to use, and you must acknowledge this by setting
`--repo_env=ACCEPTED_APPLE_SLA=1`.

## Requirements and limitations

* Requires the `hermetic-developer-dirs` branches of
  [apple_support](https://github.com/AttilaTheFun/apple_support/tree/hermetic-developer-dirs)
  and
  [rules_apple](https://github.com/AttilaTheFun/rules_apple/tree/hermetic-developer-dirs)
  (small patches intended for upstreaming: an `extra_include_dirs` hook in
  apple_support's crosstool, symlink support in its layering-check module map,
  and an Xcode-free fallback for rules_apple's `environment_plist`).
* macOS host tools that are part of the OS are still used (`/usr/bin/xcrun`,
  `/usr/bin/codesign`, `/usr/bin/plutil`, `PlistBuddy`); these ship with
  macOS, not Xcode.
* Resource processing that requires Xcode-only tools (`actool`, `ibtool`,
  storyboards, asset catalogs) does not work with a plain Command Line Tools
  toolchain; use a toolchain repackaged from a full `Xcode.app` with
  `bazel run //scripts:create_hermetic_toolchain` for those (see
  "Repackaging a full Xcode" above).
* Local execution only for now: the generated `xcode_version` embeds the
  absolute path of the assembled developer directory on this machine.
* Repository-rule *detection* steps of apple_support/rules_swift still probe
  the host's default toolchain at fetch time (feature probes such as
  `ld -reproducible`); the build actions themselves use only the hermetic
  developer directory.
