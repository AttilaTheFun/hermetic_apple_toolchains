#!/bin/bash
#
# Repackages a downloaded Xcode.app into hermetic toolchain / SDK / simulator
# runtime artifacts consumable by hermetic_apple_toolchains (and suitable for
# tarring and re-hosting on servers you manage, subject to Apple's SLA).
#
#   bazel run //scripts:create_hermetic_toolchain -- \
#       --xcode_path ~/Downloads/Xcode-beta.app \
#       --toolchain_output_path /path/to/out/toolchain \
#       --sdk_output_path /path/to/out/sdks \
#       [--simulator_output_path /path/to/out/simruntimes] \
#       [--platforms iphoneos,iphonesimulator]
#
# Outputs:
#   toolchain_output_path/
#     usr                  Symlink to Xcode.app/Contents/Developer/usr, for
#                          Command Line Tools layout compatibility.
#     SDKs/MacOSX.sdk      The macOS SDK, for building exec-platform tools.
#     Xcode.app/Contents/
#       Developer/usr      XcodeDefault.xctoolchain/usr overlaid with the
#                          Xcode developer tools (actool, ibtool, ibtoold,
#                          momc, mapc, ...) from Contents/Developer/usr.
#       Developer/Library  XcodeKit and the Xcode agents (AssetCatalogAgent).
#       Developer/Platforms  Platform directories without their SDKs.
#       Frameworks/          )
#       SharedFrameworks/    ) The rpath roots the designer tools load their
#       PlugIns/             ) implementations from (@executable_path/../../..).
#
#   sdk_output_path/
#     <Platform><Version>.sdk    One per requested platform.
#
#   simulator_output_path/
#     *.simruntime         Only if the Xcode bundles simulator runtimes;
#                          Apple usually distributes them separately (see the
#                          note printed by the script).
#
# The toolchain output follows the Command Line Tools layout, so it can be
# registered directly:
#
#   apple.toolchain(name = "...", path = "<toolchain_output_path>")
#   apple.sdk(name = "...", paths = {"iphoneos": "<sdk_output_path>/iPhoneOS27.0.sdk", ...})

set -euo pipefail

XCODE_PATH=""
TOOLCHAIN_OUT=""
SDK_OUT=""
SIMULATOR_OUT=""
PLATFORMS="iphoneos,iphonesimulator"

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  arg="$1"
  value=""
  case "$arg" in
    *=*) value="${arg#*=}"; arg="${arg%%=*}" ;;
    *) if [[ $# -gt 1 ]]; then value="$2"; shift; fi ;;
  esac
  case "$arg" in
    --xcode_path) XCODE_PATH="$value" ;;
    --toolchain_output_path) TOOLCHAIN_OUT="$value" ;;
    --sdk_output_path) SDK_OUT="$value" ;;
    --simulator_output_path) SIMULATOR_OUT="$value" ;;
    --platforms) PLATFORMS="$value" ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $arg" >&2; usage ;;
  esac
  shift
done

# When invoked via `bazel run`, resolve user-supplied relative paths against
# the invocation directory instead of the runfiles tree.
resolve() {
  local path="$1"
  path="${path/#\~/$HOME}"
  if [[ "$path" != /* && -n "${BUILD_WORKING_DIRECTORY:-}" ]]; then
    path="${BUILD_WORKING_DIRECTORY}/${path}"
  fi
  echo "$path"
}

[[ -n "$XCODE_PATH" ]] || { echo "error: --xcode_path is required" >&2; usage; }
[[ -n "$TOOLCHAIN_OUT" || -n "$SDK_OUT" || -n "$SIMULATOR_OUT" ]] || {
  echo "error: at least one output path is required" >&2; usage;
}

XCODE_PATH="$(resolve "$XCODE_PATH")"
DEVELOPER="$XCODE_PATH/Contents/Developer"
[[ -d "$DEVELOPER" ]] || { echo "error: $XCODE_PATH does not look like an Xcode app (missing Contents/Developer)" >&2; exit 1; }

XCODE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XCODE_PATH/Contents/Info.plist" 2>/dev/null || echo "unknown")
XCODE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$XCODE_PATH/Contents/version.plist" 2>/dev/null || echo "unknown")
echo "Repackaging Xcode ${XCODE_VERSION} (${XCODE_BUILD}) from ${XCODE_PATH}"

# Copies a tree, preferring APFS clones (instant, no extra space) and
# preserving symlinks. Falls back to ditto across volumes.
copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if ! cp -Rc "$src" "$dst" 2>/dev/null; then
    rm -rf "$dst"
    ditto "$src" "$dst"
  fi
}

prepare_output() {
  local out="$1"
  if [[ -e "$out" && -n "$(ls -A "$out" 2>/dev/null)" ]]; then
    echo "error: output path $out already exists and is not empty" >&2
    exit 1
  fi
  mkdir -p "$out"
}

platform_dir_name() {
  case "$1" in
    iphoneos) echo "iPhoneOS" ;;
    iphonesimulator) echo "iPhoneSimulator" ;;
    macosx) echo "MacOSX" ;;
    appletvos) echo "AppleTVOS" ;;
    appletvsimulator) echo "AppleTVSimulator" ;;
    watchos) echo "WatchOS" ;;
    watchsimulator) echo "WatchSimulator" ;;
    xros) echo "XROS" ;;
    xrsimulator) echo "XRSimulator" ;;
    *) echo "error: unknown platform '$1'" >&2; exit 1 ;;
  esac
}

if [[ -n "$TOOLCHAIN_OUT" ]]; then
  TOOLCHAIN_OUT="$(resolve "$TOOLCHAIN_OUT")"
  prepare_output "$TOOLCHAIN_OUT"
  echo "==> Toolchain: $TOOLCHAIN_OUT"

  # The artifact mirrors an Xcode.app bundle: everything lives under
  # Xcode.app/Contents so that the designer tools' @executable_path-relative
  # rpaths and the DVT plug-in machinery (which resolves resources relative
  # to the containing app bundle) work no matter where the artifact is
  # extracted. A top-level usr symlink provides Command Line Tools layout
  # compatibility for xcrun and friends.
  CONTENTS="$TOOLCHAIN_OUT/Xcode.app/Contents"
  mkdir -p "$CONTENTS"
  cp "$XCODE_PATH/Contents/Info.plist" "$XCODE_PATH/Contents/version.plist" "$CONTENTS/" 2>/dev/null || true

  echo "  - XcodeDefault.xctoolchain/usr (compilers, linkers, Swift runtimes)"
  copy_tree "$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr" "$CONTENTS/Developer/usr"
  ln -s Xcode.app/Contents/Developer/usr "$TOOLCHAIN_OUT/usr"

  echo "  - Developer tools from Contents/Developer/usr (actool, ibtool, ...)"
  # Merge into the toolchain's usr without overwriting: for the handful of
  # names that exist in both (for example ld), the Contents/Developer/usr
  # variant is a shim that relocates itself through xcrun and fails outside
  # of a real Xcode installation, while the toolchain variant is the real
  # tool. xcodebuild and xcrun are excluded: a Command Line Tools style
  # developer directory intentionally has neither, and shipping them would
  # move xcrun/xcode-select onto less well-trodden code paths.
  TMP_DEV_USR=$(mktemp -d "${TMPDIR:-/tmp}/hermetic_dev_usr.XXXXXX")
  trap 'rm -rf "$TMP_DEV_USR"' EXIT
  ditto "$DEVELOPER/usr" "$TMP_DEV_USR"
  rm -f "$TMP_DEV_USR/bin/xcodebuild" "$TMP_DEV_USR/bin/xcrun"
  rsync -a --ignore-existing "$TMP_DEV_USR/" "$CONTENTS/Developer/usr/"

  # Xcode's frameworks reference the toolchain through
  # Developer/Toolchains/XcodeDefault.xctoolchain (for example the
  # libclang.dylib symlink in Contents/Frameworks); expose the merged usr
  # under that path so those references resolve inside the artifact.
  mkdir -p "$CONTENTS/Developer/Toolchains/XcodeDefault.xctoolchain"
  ln -s ../../usr "$CONTENTS/Developer/Toolchains/XcodeDefault.xctoolchain/usr"

  echo "  - Frameworks, SharedFrameworks, PlugIns (rpath roots for the designer tools)"
  copy_tree "$XCODE_PATH/Contents/Frameworks" "$CONTENTS/Frameworks"
  copy_tree "$XCODE_PATH/Contents/SharedFrameworks" "$CONTENTS/SharedFrameworks"
  copy_tree "$XCODE_PATH/Contents/PlugIns" "$CONTENTS/PlugIns"

  echo "  - Developer/Library (XcodeKit, agents for the asset catalog tools)"
  copy_tree "$DEVELOPER/Library/Frameworks" "$CONTENTS/Developer/Library/Frameworks"
  copy_tree "$DEVELOPER/Library/Xcode" "$CONTENTS/Developer/Library/Xcode"

  # The platform directories (minus their SDKs, which are vendored separately
  # via the sdk output) provide the platform definitions and asset runtimes
  # that the designer tools need to know a platform at all: ibtoold spawns
  # AssetCatalogAgent from Developer/Library/Xcode/Agents against the
  # platform's System/AssetRuntime, and treats platforms without them as
  # unknown. macOS is always included for exec-platform tools.
  IFS=',' read -ra toolchain_platform_list <<< "$PLATFORMS"
  toolchain_platform_list+=("macosx")
  seen_platforms=""
  for platform in "${toolchain_platform_list[@]}"; do
    dir_name=$(platform_dir_name "$platform")
    case " $seen_platforms " in *" $dir_name "*) continue ;; esac
    seen_platforms="$seen_platforms $dir_name"
    src="$DEVELOPER/Platforms/${dir_name}.platform"
    [[ -d "$src" ]] || continue
    echo "  - Platforms/${dir_name}.platform (excluding SDKs)"
    dst="$CONTENTS/Developer/Platforms/${dir_name}.platform"
    mkdir -p "$dst/Developer"
    for child in "$src"/*; do
      name=$(basename "$child")
      if [[ "$name" == "Developer" ]]; then
        for dev_child in "$src/Developer"/*; do
          dev_name=$(basename "$dev_child")
          [[ "$dev_name" == "SDKs" ]] && continue
          copy_tree "$dev_child" "$dst/Developer/$dev_name"
        done
      else
        copy_tree "$child" "$dst/$name"
      fi
    done
  done

  # Xcode's toolchain binaries resolve llbuild.framework from
  # Contents/SharedFrameworks via an Xcode.app-relative rpath that does not
  # exist in this flat layout. The Command Line Tools solve the same problem
  # by shipping the framework at usr/lib/swift/pm/llbuild, which is also on
  # swift-driver's rpath list; mirror that with a relative symlink.
  if [[ ! -e "$CONTENTS/Developer/usr/lib/swift/pm/llbuild/llbuild.framework" ]]; then
    mkdir -p "$CONTENTS/Developer/usr/lib/swift/pm/llbuild"
    ln -s ../../../../../../SharedFrameworks/llbuild.framework \
      "$CONTENTS/Developer/usr/lib/swift/pm/llbuild/llbuild.framework"
  fi

  echo "  - MacOSX SDK (for exec-platform tools)"
  macos_sdks="$DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs"
  mkdir -p "$TOOLCHAIN_OUT/SDKs"
  macos_sdk_real=$(cd "$macos_sdks" && pwd -P)/$(readlink "$macos_sdks/MacOSX.sdk" 2>/dev/null || echo "MacOSX.sdk")
  copy_tree "$macos_sdk_real" "$TOOLCHAIN_OUT/SDKs/MacOSX.sdk"
fi

if [[ -n "$SDK_OUT" ]]; then
  SDK_OUT="$(resolve "$SDK_OUT")"
  prepare_output "$SDK_OUT"
  echo "==> SDKs: $SDK_OUT"
  IFS=',' read -ra platform_list <<< "$PLATFORMS"
  for platform in "${platform_list[@]}"; do
    dir_name=$(platform_dir_name "$platform")
    sdk_dir="$DEVELOPER/Platforms/${dir_name}.platform/Developer/SDKs/${dir_name}.sdk"
    [[ -d "$sdk_dir" ]] || { echo "error: no SDK at $sdk_dir" >&2; exit 1; }
    version=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$sdk_dir/SDKSettings.plist")
    echo "  - ${dir_name}${version}.sdk"
    copy_tree "$sdk_dir/" "$SDK_OUT/${dir_name}${version}.sdk"
  done
fi

if [[ -n "$SIMULATOR_OUT" ]]; then
  SIMULATOR_OUT="$(resolve "$SIMULATOR_OUT")"
  found_runtime=""
  for runtimes_dir in "$DEVELOPER"/Platforms/*.platform/Library/Developer/CoreSimulator/Profiles/Runtimes; do
    [[ -d "$runtimes_dir" ]] || continue
    for runtime in "$runtimes_dir"/*.simruntime; do
      [[ -e "$runtime" ]] || continue
      if [[ -z "$found_runtime" ]]; then
        prepare_output "$SIMULATOR_OUT"
        echo "==> Simulator runtimes: $SIMULATOR_OUT"
      fi
      found_runtime=1
      echo "  - $(basename "$runtime")"
      copy_tree "$runtime" "$SIMULATOR_OUT/$(basename "$runtime")"
    done
  done
  if [[ -z "$found_runtime" ]]; then
    echo "==> Simulator runtimes: none bundled in this Xcode."
    echo "    Modern Xcode distributes simulator runtimes separately as disk"
    echo "    images (Xcode Settings > Components, xcodebuild -downloadPlatform"
    echo "    iOS, or developer.apple.com/download). Those images can be"
    echo "    re-hosted as-is and installed with 'xcrun simctl runtime add'."
  fi
fi

echo ""
echo "Done. Register the artifacts in MODULE.bazel, for example:"
echo ""
if [[ -n "$TOOLCHAIN_OUT" ]]; then
  cat <<EOF
    apple.toolchain(
        name = "xcode${XCODE_VERSION//./_}",
        path = "${TOOLCHAIN_OUT}",
    )
EOF
fi
if [[ -n "$SDK_OUT" ]]; then
  echo "    apple.sdk("
  echo "        name = \"...\","
  echo "        paths = {"
  for sdk in "$SDK_OUT"/*.sdk; do
    [[ -e "$sdk" ]] || continue
    canonical=$(/usr/libexec/PlistBuddy -c 'Print :CanonicalName' "$sdk/SDKSettings.plist" 2>/dev/null || basename "$sdk")
    platform_key="${canonical%%[0-9]*}"
    echo "            \"${platform_key}\": \"${sdk}\","
  done
  echo "        },"
  echo "    )"
fi
echo ""
echo "These artifacts may only be re-hosted for use within your own"
echo "organization, per Apple's software license agreement."
