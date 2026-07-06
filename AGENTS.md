# AGENTS.md

Context for AI agents (and new humans) working in this repository. The
README is the consumer-facing documentation; this file records the design
rationale, the non-obvious mechanics, the machine-local state, and the
traps that cost real debugging time. Trust but verify: re-check machine
state (installed runtimes, components, artifact paths) before relying on
it.

## What this is

`hermetic_apple_toolchains` builds (and runs) Apple-platform apps with
Bazel using **verbatim, unmodified Xcode.app copies** vendored into
external repositories — no Xcode installed via App Store/xcode-select, no
Xcode ever opened manually. Public repo (MIT) at
`github.com/AttilaTheFun/hermetic_apple_toolchains`, owned by Logan Shire
(AttilaTheFun). Modeled on keith's `hermetic_android_toolchains`
(`../hermetic_android_toolchains` may exist as a sibling checkout). BCR
submission is planned once the apple_support PR lands (see below).

The "verbatim" constraint is load-bearing, not aesthetic:

- Modifying anything inside Xcode.app breaks Apple's notarized seal, and
  Gatekeeper evaluates a modified unsealed bundle pathologically slowly on
  first launch (looks like a permanent hang). An ad-hoc reseal fixes it,
  but verbatim copies never hit the problem and keep every tool behaving
  exactly as installed.
- `actool`/`ibtool` (via the persistent `ibtoold` daemon) resolve
  platforms/SDKs/plug-ins relative to the app bundle containing their
  *realpathed* binary — every symlink-reconstructed Xcode fails. Slimmed
  Xcodes were prototyped and abandoned (~20% savings, high brittleness).
- Anything that must differ from the bundle lives *outside* it (e.g. the
  runner view under `$TMPDIR`, see below).

## Architecture

`extensions.bzl` defines module extension `apple` with tag classes:

- `apple.xcode(name, path|url+sha256+strip_prefix, aliases, default)` →
  `private/xcode.bzl` (`apple_xcode_repository`). Clones the Xcode.app
  (`cp -Rc`, APFS clone; `ditto` fallback; **never symlink** — xcrun
  canonicalizes symlinks and leaks the source path into SDKROOT, breaking
  the C++ toolchain's include validation). Generates:
  - `xcode_version(name = "version")` whose `version` is the **absolute
    path** of `Xcode.app/Contents/Developer`. Bazel uses a path-valued
    `XCODE_VERSION_OVERRIDE` directly as `DEVELOPER_DIR`
    (XcodeLocalEnvProvider) and resolves SDKROOT via
    `xcrun --sdk X --show-sdk-path`. Aliases: tag name, user aliases, plus
    the Xcode's version number and build number from
    `Contents/version.plist` (e.g. `26.5`, `17F42`) — rules_xcodeproj
    selects Xcodes by build number.
  - Scripts (repo-internal; reached via the hub): `accept_license.sh`
    (checks `LicenseInfo.plist` licenseID vs
    `/Library/Preferences/com.apple.dt.Xcode.plist`
    `IDELast{GM,Beta}LicenseAgreedTo`; sudo; no-TTY fallback prints the
    manual command), `first_launch.sh` (see "Beta simulator runtimes"),
    `with_developer_dir.sh`, `open_xcode.sh` (seeds GUI first-launch
    defaults, opens the app, forwards document args resolved against
    `BUILD_WORKING_DIRECTORY`).
- `apple.simulator_runtime(name, path|url+sha256, xcode)` →
  `private/simulator_runtime.bzl`. Vendors a runtime cryptex dmg with an
  `:install` runnable (`xcodebuild -importPlatform` through the associated
  Xcode; idempotent by grepping `simctl runtime list` for the build in
  `(Ready)` state, parsed from the `<Platform>_<version>_<build>.dmg`
  naming convention).
- `apple.component(name, path|url+sha256, component_type, xcode)` →
  `private/component.bzl`. Vendors a downloadable Xcode component
  (MetalToolchain is the known type) with an `:install` runnable
  (`xcodebuild -importComponent`; idempotent via
  `xcodebuild -showComponent <type> -json` status).
- Hub repo `@apple_toolchains` → `private/xcode_config.bzl`. Generates
  `xcode_config` + the **public interface** (see below) + per-Xcode
  check/prepare scripts. Receives label deps on each xcode repo's
  BUILD.bazel (forces xcode fetch, gives it repo roots) and *metadata
  dicts* for runtimes/components (`{name: [xcode, build-or-type]}`) so
  check/prepare can test status **without fetching** the multi-GB
  runtime/component repos.
- CC toolchain: apple_support's **rules-based toolchain**
  (`@apple_support//toolchain`), enabled via
  `--repo_env=APPLE_SUPPORT_RULES_BASED_TOOLCHAIN=1` in `.bazelrc`. It is
  driven by the `xcode_config` at analysis time (a path-valued Xcode
  version flows straight into `XCODE_VERSION_OVERRIDE` → `DEVELOPER_DIR`)
  and does **no fetch-time compiler probing** — the legacy
  `local_config_apple_cc` autoconf becomes a no-op, so no override repo is
  needed. Include validation for the hermetic SDK/toolchain headers
  (absolute paths inside the vendored Xcodes) is handled by the hub's
  generated `:xcode_include_directories` `cc_args` target, wired via
  `--@apple_support//toolchain:extra_include_directories=...` in
  `.bazelrc`. That flag is pending upstream (see below). The allowlist is
  deliberately only the vendored developer
  dirs, never the external root: an entry covering the output base makes
  Bazel's .d-file pruning silently drop real dependencies for every
  external repo's headers (bazel#29613).
- `hermetic_swift_config` (`private/swift_config.bzl`): static
  `xcode_swift_toolchain` targets without `system_sdk` (rules_swift 4's
  autoconfig probes *installed* Xcodes); wired via
  `override_repo(non_module_deps, rules_swift_local_config = ...)`.

Public interface per Xcode (everything else is internal, reached by
`prepare` through canonical labels like `@@+apple+<repo>//:target`):

- `check_<xcode>` — status of one-time per-machine setup, one
  `[ok]`/`[needed]` line per step, exits non-zero if anything is needed.
- `prepare_<xcode>` — same checks, runs only the needed steps (license →
  system components (only when runtimes registered) → runtime installs →
  component installs). Uses nested `bazel run` on canonical labels, so it
  fetches lazy repos only when their step actually runs.
- `<xcode>` (bare name) — opens the GUI, forwards document args
  (`bazel run @apple_toolchains//:xcode27beta2 -- path/to/proj.xcodeproj`).
- `with_developer_dir_<xcode>` — `--run_under` wrapper / ad-hoc
  `DEVELOPER_DIR` runner (`-- $SHELL` gives a pinned interactive shell).

The `.bazelrc` essentials (the two version-config flags are both required
while apple_support migrates off the native apple fragment — the resolver
analyzes both):

```
common --repo_env=APPLE_SUPPORT_RULES_BASED_TOOLCHAIN=1
build --xcode_version_config=@apple_toolchains//:xcode_config
build --@apple_support//xcode:starlark_version_config=@apple_toolchains//:xcode_config
build --@apple_support//toolchain:extra_include_directories=@apple_toolchains//:xcode_include_directories
```

`.bazelrc` also defines per-Xcode configs (`--config=xcode26`,
`--config=xcode27beta2`): build sets `--xcode_version`, run sets
`--run_under=with_developer_dir_<x>` + `--ios_simulator_version`.
`try-import %workspace%/.bazelrc.user` (gitignored) carries machine-local
settings.

## apple_support dependency (one ~15-line change pending upstream)

We use apple_support's **rules-based toolchain**, which is main-only (not
in any tagged release yet). MODULE.bazel `git_override`s the fork at a
commit that is upstream main plus one ~15-line change: a `label_flag`
`@apple_support//toolchain:extra_include_directories` (default: empty
`cc_args`) appended to the toolchain's args — the hook our hub's
generated `:xcode_include_directories` allowlist plugs into. That change
is pending upstream as
**https://github.com/bazelbuild/apple_support/pull/617** (fork branch
`extra-include-directories`, local checkout at `../apple_support`).

History: an earlier fork PR (bazelbuild/apple_support#616, fork branch
`hermetic-developer-dirs`) patched the **legacy** autoconf crosstool
(`configure_osx_toolchain(extra_include_dirs = [external root])` + treating
a path-valued Xcode version as "latest" in two version checks). Keith
reviewed it: the legacy API is being replaced by the rules-based toolchain,
and passing the external root as a builtin include dir is a correctness
bug (bazel#29613 — .d pruning silently drops dependencies for everything
under external/). The rules-based toolchain makes both changes moot: it
has no Xcode version comparisons (those features are unconditional
`negatable_feature`s) and takes the path-valued version straight from
`xcode_config` at analysis time. Once #617 merges and ships in a tagged
release, point the git_override (or a plain bazel_dep) at it — then the
module needs **zero** deltas on its dependencies. rules_apple is **not**
forked (a previous fork/PR was closed as unnecessary — upstream
`environment_plist` works with app-style developer dirs).

## Non-obvious mechanics (hard-won)

- **Beta simulator runtimes need the beta's host CoreSimulator.**
  `xcodebuild -runFirstLaunch` reports "done" if *any* generation of
  XcodeSystemResources is installed and never upgrades across
  generations; booting a 27-beta runtime on 26.5-era CoreSimulator fails
  with SimError 401 "runtime path not found" even though
  `simctl runtime list` shows the runtime Ready/mounted and devices show
  available. `first_launch.sh` therefore compares
  `pkgutil --pkg-info com.apple.pkg.XcodeSystemResources` against the pkg
  shipped in `Xcode.app/Contents/Resources/Packages/` and runs
  `sudo installer -pkg ... -target /` + CoreSimulatorService restart when
  the shipped one is newer.
- **Xcode 27+ ships no `Developer/Applications/Simulator.app`** (there's
  a new `Contents/Applications/DeviceHub.app`, `com.apple.dt.Devices`).
  rules_apple's runner and rules_xcodeproj both hardcode expectations, so
  the hub generates `with_developer_dir_<x>` for such Xcodes as a symlink
  view at `$TMPDIR/hermetic_xcode_runner_view_<x>/Xcode.app/Contents/
  Developer` that mirrors the real bundle and borrows Simulator.app from
  another registered Xcode (donor = default Xcode if it has one). The
  view **must** be app-shaped: rules_xcodeproj validates
  `${DEVELOPER_DIR%/*}/version.plist`, and xcrun keys license enforcement
  off the `.app` path shape. Consequence: running (not building) under an
  Xcode 27 toolchain requires a 26.x Xcode registered as donor.
- **Xcode GUI one-time prompts** (appear even when everything is
  installed): the platforms sheet is keyed on per-user defaults
  `com.apple.dt.Xcode IDEPlatformsFirstLaunchPresentedSDKVersions-<platform>`
  (arrays of SDK build numbers read from each SDK's
  `System/Library/CoreServices/SystemVersion.plist` ProductBuildVersion);
  the What's New splash on `IDELastShownWhatsNewContentRevision` (int).
  `open_xcode.sh` seeds both before launching.
- **Metal Toolchain** (Xcode 26+) is a separate per-Xcode-build download;
  `metal` fails without it and the GUI prompts for it. Full CLI
  lifecycle: `xcodebuild -downloadComponent MetalToolchain -exportPath`
  (exports `<Component>_<build>.exportedBundle`; also installs as a side
  effect), `-importComponent ... -importPath`, `-showComponent -json`,
  `-deleteComponent` (handy for testing the install path for real).
- **rules_xcodeproj** (BCR dep, 4.1.0) works end to end:
  its runner uses `DEVELOPER_DIR` when set (hence generate with the
  config: `bazel run //examples/ios_example:xcodeproj --config=xcode26`),
  reads the build number from `../version.plist`, and passes
  `--xcode_version=<build>` to an inner bazel that resolves it through
  our xcode_config (workspace .bazelrc applies). `xcodeproj` targets
  **must** set `minimum_xcode_version` (the default derives from the
  resolved Xcode "version", which is a path here) and top-level targets
  need `visibility = ["@rules_xcodeproj//xcodeproj:generated"]`. The
  generated project embeds no Xcode paths — `$(DEVELOPER_DIR)` /
  `$XCODE_PRODUCT_BUILD_VERSION` come from the Xcode that opens it, which
  resolves via our build-number aliases. Projects are gitignored
  (`*.xcodeproj`).
- **iOS 27 + UIKit**: an `@main` UIApplicationDelegate without a scene
  delegate asserts at runtime on iOS 27; the example app is a SwiftUI
  `@main App` for that reason.
- **License acceptance** is system-wide per agreement revision
  (`licenseID`, GM vs Beta tracked separately), so accepting once covers
  every copy of the same revision. App-style DEVELOPER_DIR enforces the
  license on xcrun calls (CLT-style dirs don't — a previous design
  exploited that; abandoned with the slimming approach).
- No `ACCEPTED_APPLE_SLA` env gate: the module never provides Apple
  artifacts itself, per-machine license acceptance is the enforcement
  point (see README Licensing).

## Debug traps (each cost significant time)

- `ibtoold` is a **persistent daemon** that serves later actool calls
  from whatever context it was born in — it poisons A/B tests. Between
  experiments: `pkill -f ibtoold`, clear `~/Library/Caches/com.apple.ibtool`
  and `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.{ibtool,dt.AssetCatalogAgent-*}`.
- xcrun has its own cache: `xcrun --kill-cache` after swapping repo
  contents, and the **Bazel server caches SDKROOT per developer-dir for
  its lifetime** — `bazel shutdown` after changing what an Xcode repo
  path points at (the generated project's bazel_build.sh restarts the
  server on DEVELOPER_DIR change for the same reason).
- dyld realpaths the main executable — symlinked-binary A/B tests
  silently test the target, not the symlink arrangement.
- Never touch hdiutil mount points via `rctx.path` (Bazel records them
  as repo inputs).
- Stale simulator devices: a device created against a since-deleted
  runtime *instance* fails to boot even when an identical runtime build
  is registered again; delete the device.
- `simctl runtime list` idempotence checks must require `(Ready)` —
  runtimes linger in `(Deleting)` state.
- Apps built with a newer SDK run on older runtimes when
  `minimum_os_version` allows (iOS-27-SDK app with min 26.0 runs on the
  26.5 runtime).

## CI

`.github/workflows/ci.yml` (push to main + PRs; badge in README): a
`macos-26` arm64 job registers the runner's preinstalled
`/Applications/Xcode_26.5.app` as the hermetic Xcode by **rewriting the
marked block in MODULE.bazel** (`.github/register_ci_xcode.py`; the
markers are `# --- BEGIN/END machine-local registration ---` — keep
them). It builds the example, asserts the app's `DTXcodeBuild` equals the
registered Xcode's build, then runs it in the runner's iOS 26.5 simulator
and greps for the app's `[hermetic]` NSLog lines. GitHub macOS runners are
free for public repos; the image ships several Xcodes, matching simulator
runtimes, and bazelisk (`.bazelversion` pins 9.1.1 to match the image).

## Machine-local state (Logan's laptop; verify before relying on it)

- Artifacts: `~/Downloads/hermetic/xcode_26_5/{Xcode.app, simulators/iOS_26.5_23F77.dmg, components/MetalToolchain_17F42.exportedBundle}`
  and `~/Downloads/hermetic/xcode_27_beta_2/{Xcode.app, simulators/iOS_27.0_24A5370g.dmg, components/MetalToolchain_27A5209h.exportedBundle}`.
  (`sdks/` subdirs are legacy leftovers from the abandoned design.) The
  27 beta Xcode.app is ~3.6G on disk and genuinely has no
  Developer/Applications — that is how Apple ships it, nothing was lost.
- MODULE.bazel's marked block registers: `xcode26_5` (default, alias
  `xcode26`), `xcode27beta2`, both runtimes, both Metal toolchains.
- Both licenses accepted (EA1990 GM, EA2002 Beta); host
  XcodeSystemResources upgraded to the 27 beta's; both runtimes
  registered with CoreSimulator; both Metal toolchains installed.
  `bazel run @apple_toolchains//:check_<x>` reports ground truth.
- Producer-side tooling: `scripts/create_hermetic_toolchain.sh` exports a
  verbatim Xcode copy (`--xcode_path/--xcode_output_path`), simulator
  runtimes (`--simulator_output_path`, `--download_platform iOS` wraps
  `xcodebuild -downloadPlatform -exportPath`, flattens to
  `<Platform>_<version>_<build>.dmg`), and components
  (`--component_output_path`, `--download_component MetalToolchain`).
  This is intentionally separate from the consumer-side check/prepare.

## Verification workflows

```bash
# Build + run the example on each Xcode (expect matching [hermetic] SDK
# and runtime lines in the streamed logs):
bazel run //examples/ios_example --config=xcode26
bazel run //examples/ios_example --config=xcode27beta2

# Setup state:
bazel run @apple_toolchains//:check_xcode27beta2

# rules_xcodeproj (regenerate when switching Xcodes; project is keyed to
# the generating Xcode's build number):
bazel run //examples/ios_example:xcodeproj --config=xcode27beta2
bazel run @apple_toolchains//:xcode27beta2 -- examples/ios_example/ios_example.xcodeproj

# Hermetic stamp proof on any built app:
# Info.plist DTXcodeBuild/DTSDKBuild must match the selected Xcode
# (26.5: DTXcode 2650, build 17F42, SDK 23F73; 27b2: DTXcode 2700,
# build 27A5209h, SDK 24A5370g).
```

When a `bazel run` boots a simulator, the runner streams logs forever —
background it, poll the log file for `[hermetic]`, then kill it (CI does
exactly this).

## Conventions

- Commits are authored solely by Logan — **no Co-Authored-By, no
  Claude-Session trailers, no attribution in PR bodies** (his
  `~/.claude/settings.json` disables all of it; do not re-add).
- Logan hand-edits the README for style; never clobber his wording —
  check `git diff` before writing over it, and beware that
  `git checkout <file>` discards uncommitted work (this bit us once).
- Keep the apple_support fork minimal and upstreamable; do not fork
  rules_apple or rules_swift.
- LICENSE is MIT (keith-style, Logan's copyright).
- `MODULE.bazel.lock`, `bazel-*`, `*.xcodeproj`, `.bazelrc.user` are
  gitignored.

## Known limitations / possible next steps

- Local execution only: the generated `xcode_version` embeds absolute
  paths from this machine's Bazel output base.
- rules_swift's fetch-time feature probes still consult the host's
  default toolchain (build actions are hermetic).
- macOS host tools that ship with the OS are still used
  (`/usr/bin/xcrun`, `/usr/bin/codesign`, `/usr/bin/plutil`).
- After apple_support#617 merges and ships in a tagged release: drop the
  git_override, update README's Registering section, then BCR submission
  (Logan is coordinating with keith).
- Simulator GUI for Xcode 27+ depends on a donor Xcode; if Apple's
  DeviceHub.app turns out to accept `-CurrentDeviceUDID`-style launching,
  the runner view could use it instead.
