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
#     Xcode.app            A slimmed, ad-hoc re-signed copy of the input
#                          Xcode: only the requested platforms (plus macOS)
#                          are kept, the requested platforms' SDKs are
#                          removed (they are vendored separately via the sdk
#                          output and placed back at assembly time), and the
#                          bundled apps are dropped. A real .app copy is
#                          required for the designer tools (actool, ibtool),
#                          which resolve their platform support relative to
#                          the app bundle containing their binary.
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

  # The toolchain artifact is a slimmed *real copy* of the Xcode.app bundle.
  # This is load-bearing: Xcode's designer tools (actool/ibtoold) resolve
  # their platform support relative to the app bundle containing their own
  # (realpath-resolved) binary, and no symlink-reconstructed layout satisfies
  # them. The copy is slimmed by deleting the platforms that were not
  # requested, the requested platforms' SDKs (they are vendored separately
  # via the sdk output and placed back at assembly time), and the bundled
  # apps. macOS Gatekeeper treats a modified bundle pathologically on first
  # launch (it appears to hang for many minutes), so the slimmed bundle is
  # re-sealed with an ad-hoc signature, after which first launch takes
  # seconds.
  #
  # The copy is built under a temporary name and only renamed to Xcode.app at
  # the end: macOS restricts writing into .app bundles under some
  # configurations, and nothing may modify the bundle after it is sealed.
  WORK="$TOOLCHAIN_OUT/xcode_work"
  echo "  - Copying $XCODE_PATH (APFS clone when possible)"
  if ! cp -Rc "$XCODE_PATH" "$WORK" 2>/dev/null; then
    rm -rf "$WORK"
    ditto "$XCODE_PATH" "$WORK"
  fi

  echo "  - Removing unrequested platforms and bundled applications"
  IFS=',' read -ra keep_list <<< "$PLATFORMS"
  keep_list+=("macosx")
  keep_names=""
  for platform in "${keep_list[@]}"; do
    keep_names="$keep_names $(platform_dir_name "$platform").platform"
  done
  for platform_dir in "$WORK"/Contents/Developer/Platforms/*.platform; do
    name=$(basename "$platform_dir")
    case " $keep_names " in
      *" $name "*) ;;
      *) rm -rf "$platform_dir" ;;
    esac
  done
  rm -rf "$WORK/Contents/Applications"

  # Remove the requested platforms' SDKs; the developer directory assembly
  # places the separately vendored SDKs back in these locations. The macOS
  # SDK stays: it belongs to the toolchain (exec-platform tools need it, and
  # ibtoold refuses to initialize without a macOS SDK).
  for platform in "${keep_list[@]}"; do
    [[ "$platform" == "macosx" ]] && continue
    dir_name=$(platform_dir_name "$platform")
    rm -rf "$WORK/Contents/Developer/Platforms/${dir_name}.platform/Developer/SDKs"
  done

  echo "  - Re-sealing the bundle (ad-hoc signature)"
  codesign -f -s - "$WORK" 2>/dev/null || codesign -f -s - "$WORK"

  mv "$WORK" "$TOOLCHAIN_OUT/Xcode.app"
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
  prepare_output "$SIMULATOR_OUT"
  echo "==> Simulator runtimes: $SIMULATOR_OUT"
  found_runtime=""

  # Old Xcodes bundled simulator runtimes inside the platform directories.
  for runtimes_dir in "$DEVELOPER"/Platforms/*.platform/Library/Developer/CoreSimulator/Profiles/Runtimes; do
    [[ -d "$runtimes_dir" ]] || continue
    for runtime in "$runtimes_dir"/*.simruntime; do
      [[ -e "$runtime" ]] || continue
      found_runtime=1
      echo "  - $(basename "$runtime") (bundled)"
      copy_tree "$runtime" "$SIMULATOR_OUT/$(basename "$runtime")"
    done
  done

  # Modern Xcode distributes simulator runtimes separately as cryptex disk
  # images, registered with CoreSimulator via 'simctl runtime add'. Export
  # any installed runtime image matching this Xcode's iOS SDK version so it
  # can be re-hosted alongside the toolchain and SDKs.
  ios_sdk_settings="$DEVELOPER/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.plist"
  ios_sdk_version=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$ios_sdk_settings" 2>/dev/null || echo "")
  if [[ -n "$ios_sdk_version" ]]; then
    while IFS=$'\t' read -r version build image_path; do
      [[ "$version" == "$ios_sdk_version" && -f "$image_path" ]] || continue
      found_runtime=1
      image_name="iOS_${version}_${build}.dmg"
      echo "  - ${image_name} (installed runtime image, $(du -h "$image_path" 2>/dev/null | cut -f1 || echo "?"))"
      cp -c "$image_path" "$SIMULATOR_OUT/$image_name" 2>/dev/null || cp "$image_path" "$SIMULATOR_OUT/$image_name"
    done < <(xcrun simctl runtime list -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
for r in json.load(sys.stdin).values():
    if r.get("platformIdentifier", "").endswith("iphonesimulator") and r.get("path"):
        print("\t".join([r.get("version", ""), r.get("build", ""), r["path"]]))
')
  fi

  cat > "$SIMULATOR_OUT/README.md" <<'EOF'
# Simulator runtimes

Simulator runtimes are cryptex disk images distributed separately from Xcode
(Xcode Settings > Components, `xcodebuild -downloadPlatform iOS`, or
developer.apple.com/download). They are only needed to *run* apps in a
simulator, not to build them.

Install an image on another machine with:

    xcrun simctl runtime add <image>.dmg

Note that apps built with a newer SDK run on older simulator runtimes as long
as their minimum OS version allows it.
EOF

  if [[ -z "$found_runtime" ]]; then
    echo "    (none found: this Xcode bundles no runtimes and no matching"
    echo "     runtime image is installed; see the README for how runtimes"
    echo "     are distributed)"
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
