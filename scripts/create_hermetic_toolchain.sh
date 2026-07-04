#!/bin/bash
#
# Exports hermetic Xcode / simulator runtime artifacts, suitable for tarring
# and re-hosting on servers you manage (subject to Apple's SLA).
#
#   bazel run //scripts:create_hermetic_toolchain -- \
#       --xcode_path ~/Downloads/Xcode-beta.app \
#       [--xcode_output_path /path/to/out/Xcode.app] \
#       [--simulator_output_path /path/to/out/simulators] \
#       [--download_platform iOS] \
#       [--component_output_path /path/to/out/components] \
#       [--download_component MetalToolchain]
#
# Outputs:
#   xcode_output_path        A verbatim copy of the input Xcode.app (an APFS
#                            clone when on the same volume: instant and free).
#                            The copy is deliberately unmodified: it keeps
#                            Apple's notarized seal, so Gatekeeper's
#                            first-launch evaluation stays fast, and every
#                            tool (xcodebuild, actool, ibtool, ...) behaves
#                            exactly as in a normal installation. If the
#                            input is already where you want it, you can skip
#                            this and register the .app directly.
#
#   simulator_output_path/   Simulator runtime disk images, when available:
#     *.simruntime           runtimes bundled inside the Xcode (old Xcodes),
#     iOS_<ver>_<build>.dmg  or an installed runtime image matching the
#                            Xcode's iOS version, exported from the system's
#                            MobileAsset store. With --download_platform, the
#                            runtime matching this Xcode is downloaded from
#                            Apple (`xcodebuild -downloadPlatform`, requires
#                            an accepted license) and exported here. Modern
#                            Xcode distributes runtimes separately; they are
#                            only needed to *run* apps, and are registered
#                            with hermetic_apple_toolchains'
#                            apple.simulator_runtime tag (or manually with
#                            `xcrun simctl runtime add <image>.dmg`).
#
#   component_output_path/   Downloadable Xcode components, with
#                            --download_component (repeatable). Since
#                            Xcode 26, the Metal Toolchain is a separate
#                            download that the Xcode GUI prompts for on
#                            first launch; vendor it and register it with
#                            the apple.component tag so the prompt never
#                            appears. Exported as
#                            <Component>_<build>.exportedBundle, importable
#                            with `xcodebuild -importComponent`.
#
# Register the Xcode with hermetic_apple_toolchains:
#
#   apple.xcode(name = "...", path = "<xcode_output_path>")
#   # or, re-hosted: apple.xcode(name = "...", url = "https://...", sha256 = "...")

set -euo pipefail

XCODE_PATH=""
XCODE_OUT=""
SIMULATOR_OUT=""
DOWNLOAD_PLATFORM=""
COMPONENT_OUT=""
DOWNLOAD_COMPONENTS=()

usage() {
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    -h|--help) usage ;;
  esac
  value=""
  case "$arg" in
    *=*) value="${arg#*=}"; arg="${arg%%=*}" ;;
    *) if [[ $# -gt 1 ]]; then value="$2"; shift; fi ;;
  esac
  case "$arg" in
    --xcode_path) XCODE_PATH="$value" ;;
    --xcode_output_path) XCODE_OUT="$value" ;;
    --simulator_output_path) SIMULATOR_OUT="$value" ;;
    --download_platform) DOWNLOAD_PLATFORM="$value" ;;
    --component_output_path) COMPONENT_OUT="$value" ;;
    --download_component) DOWNLOAD_COMPONENTS+=("$value") ;;
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
[[ -n "$XCODE_OUT" || -n "$SIMULATOR_OUT" || -n "$COMPONENT_OUT" ]] || {
  echo "error: at least one output path is required" >&2; usage;
}
[[ ${#DOWNLOAD_COMPONENTS[@]} -eq 0 || -n "$COMPONENT_OUT" ]] || {
  echo "error: --component_output_path is required with --download_component" >&2; usage;
}

XCODE_PATH="$(resolve "$XCODE_PATH")"
DEVELOPER="$XCODE_PATH/Contents/Developer"
[[ -d "$DEVELOPER" ]] || { echo "error: $XCODE_PATH does not look like an Xcode app (missing Contents/Developer)" >&2; exit 1; }

XCODE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XCODE_PATH/Contents/Info.plist" 2>/dev/null || echo "unknown")
XCODE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$XCODE_PATH/Contents/version.plist" 2>/dev/null || echo "unknown")
echo "Exporting Xcode ${XCODE_VERSION} (${XCODE_BUILD}) from ${XCODE_PATH}"

if [[ -n "$XCODE_OUT" ]]; then
  XCODE_OUT="$(resolve "$XCODE_OUT")"
  if [[ -e "$XCODE_OUT" ]]; then
    echo "error: output path $XCODE_OUT already exists" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$XCODE_OUT")"
  echo "==> Xcode: $XCODE_OUT (verbatim copy)"
  if ! cp -Rc "$XCODE_PATH" "$XCODE_OUT" 2>/dev/null; then
    rm -rf "$XCODE_OUT"
    ditto "$XCODE_PATH" "$XCODE_OUT"
  fi
fi

if [[ -n "$SIMULATOR_OUT" ]]; then
  SIMULATOR_OUT="$(resolve "$SIMULATOR_OUT")"
  mkdir -p "$SIMULATOR_OUT"
  echo "==> Simulator runtimes: $SIMULATOR_OUT"
  found_runtime=""

  # Download the runtime matching this Xcode from Apple and export it. This
  # requires the Xcode's license to have been accepted, and also registers
  # the runtime with CoreSimulator on this machine as a side effect.
  if [[ -n "$DOWNLOAD_PLATFORM" ]]; then
    echo "  - Downloading the $DOWNLOAD_PLATFORM runtime via xcodebuild (large)..."
    env DEVELOPER_DIR="$DEVELOPER" "$DEVELOPER/usr/bin/xcodebuild" \
      -downloadPlatform "$DOWNLOAD_PLATFORM" \
      -exportPath "$SIMULATOR_OUT" \
      -architectureVariant arm64
    # Flatten the exported bundle to <Platform>_<version>_<build>.dmg.
    for bundle in "$SIMULATOR_OUT"/*.exportedBundle; do
      [[ -d "$bundle" ]] || continue
      base=$(basename "$bundle" .exportedBundle)
      IFS='_' read -r _canonical version build <<< "$base"
      dmg=$(ls "$bundle"/Restore/*.dmg 2>/dev/null | head -1)
      [[ -n "$dmg" ]] || continue
      out_name="${DOWNLOAD_PLATFORM}_${version}_${build}.dmg"
      echo "  - ${out_name}"
      cp -c "$dmg" "$SIMULATOR_OUT/$out_name" 2>/dev/null || cp "$dmg" "$SIMULATOR_OUT/$out_name"
      rm -rf "$bundle"
      found_runtime=1
    done
  fi

  # Old Xcodes bundled simulator runtimes inside the platform directories.
  for runtimes_dir in "$DEVELOPER"/Platforms/*.platform/Library/Developer/CoreSimulator/Profiles/Runtimes; do
    [[ -d "$runtimes_dir" ]] || continue
    for runtime in "$runtimes_dir"/*.simruntime; do
      [[ -e "$runtime" ]] || continue
      found_runtime=1
      echo "  - $(basename "$runtime") (bundled)"
      cp -Rc "$runtime" "$SIMULATOR_OUT/$(basename "$runtime")" 2>/dev/null || \
        ditto "$runtime" "$SIMULATOR_OUT/$(basename "$runtime")"
    done
  done

  # Modern Xcode distributes simulator runtimes separately as cryptex disk
  # images, registered with CoreSimulator via 'simctl runtime add'. Export
  # any installed runtime image matching this Xcode's iOS SDK version so it
  # can be re-hosted alongside the Xcode.
  ios_sdk_settings="$DEVELOPER/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.plist"
  ios_sdk_version=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$ios_sdk_settings" 2>/dev/null || echo "")
  if [[ -n "$ios_sdk_version" ]]; then
    while IFS=$'\t' read -r version build image_path; do
      [[ "$version" == "$ios_sdk_version" && -f "$image_path" ]] || continue
      image_name="iOS_${version}_${build}.dmg"
      [[ -e "$SIMULATOR_OUT/$image_name" ]] && continue
      found_runtime=1
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

if [[ -n "$COMPONENT_OUT" && ${#DOWNLOAD_COMPONENTS[@]} -gt 0 ]]; then
  COMPONENT_OUT="$(resolve "$COMPONENT_OUT")"
  mkdir -p "$COMPONENT_OUT"
  echo "==> Components: $COMPONENT_OUT"
  for component in "${DOWNLOAD_COMPONENTS[@]}"; do
    build=$(env DEVELOPER_DIR="$DEVELOPER" "$DEVELOPER/usr/bin/xcodebuild" \
      -showComponent "$component" -json 2>/dev/null | \
      /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("buildVersion", ""))' \
      2>/dev/null || echo "")
    echo "  - Downloading $component${build:+ ($build)} via xcodebuild (large)..."
    tmp="$COMPONENT_OUT/.export_$$"
    mkdir -p "$tmp"
    env DEVELOPER_DIR="$DEVELOPER" "$DEVELOPER/usr/bin/xcodebuild" \
      -downloadComponent "$component" \
      -exportPath "$tmp"
    # Normalize the export to <Component>_<build>.<same extension>.
    exported=$(ls -d "$tmp"/* 2>/dev/null | head -1)
    if [[ -z "$exported" ]]; then
      echo "error: xcodebuild exported nothing for $component" >&2
      rm -rf "$tmp"
      exit 1
    fi
    ext="${exported##*.}"
    out_name="${component}${build:+_$build}.${ext}"
    echo "  - ${out_name}"
    rm -rf "${COMPONENT_OUT:?}/${out_name}"
    mv "$exported" "$COMPONENT_OUT/$out_name"
    rm -rf "$tmp"
  done
fi

echo ""
echo "These artifacts may only be re-hosted for use within your own"
echo "organization, per Apple's software license agreement."
