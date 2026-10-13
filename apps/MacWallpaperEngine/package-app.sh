#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacWallpaperEngine"
BUNDLE_ID="local.wallpaper.MacWallpaperEngine"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
WALLPAPER_SOURCE="$PROJECT_ROOT/wallpapers"
WALLPAPER_DEST="$RESOURCES_DIR/wallpapers"
SCHEMA_SOURCE="$SCRIPT_DIR/Resources/schemas/wallpaper-native-v2.schema.json"
SCHEMA_DEST="$RESOURCES_DIR/schemas"
# Inert Windows originals (Wallpaper Engine application sources) stay in the repo
# wallpapers/ tree for provenance but are excluded from packaged bundles to keep
# the .app slim. The runtime reads only wallpaper.native.json plus bundle assets,
# and source descriptors (project.json, source/*.json) still resolve in the
# packaged copy. No-ops for bundles without these files (e.g. an imported bundle).
PACKAGE_COPY_EXCLUDES=(
  # functional exclude: Windows build payload of an imported bundle
  --exclude "*_Data/"
  --exclude "MonoBleedingEdge/"
  --exclude "D3D12/"
  --exclude "*.exe"
  --exclude "*.dll"
)
STRICT_COMPOSITE_QUALITY="${STRICT_COMPOSITE_QUALITY:-0}"
PACKAGE_VALIDATE_ONLY="${PACKAGE_VALIDATE_ONLY:-0}"
PACKAGE_SMOKE_TEST="${PACKAGE_SMOKE_TEST:-0}"
PACKAGE_SMOKE_TEST_DURATION="${PACKAGE_SMOKE_TEST_DURATION:-9}"
PACKAGE_SMOKE_EVIDENCE="${PACKAGE_SMOKE_EVIDENCE:-}"
PACKAGE_RUNTIME_INTERACTION_SMOKE="${PACKAGE_RUNTIME_INTERACTION_SMOKE:-auto}"
PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE="${PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE:-auto}"
VALIDATOR_BIN="$SCRIPT_DIR/.build/release/$APP_NAME"
PACKAGE_SMOKE_TEST_PASSED=0

STRICT_COMPOSITE_QUALITY_ENABLED=0
case "$STRICT_COMPOSITE_QUALITY" in
  1|true|TRUE|yes|YES)
    STRICT_COMPOSITE_QUALITY_ENABLED=1
    ;;
  0|false|FALSE|no|NO|"")
    STRICT_COMPOSITE_QUALITY_ENABLED=0
    ;;
  *)
    echo "Invalid STRICT_COMPOSITE_QUALITY value: $STRICT_COMPOSITE_QUALITY" >&2
    echo "Use 1/true/yes or 0/false/no." >&2
    exit 1
    ;;
esac

PACKAGE_VALIDATE_ONLY_ENABLED=0
case "$PACKAGE_VALIDATE_ONLY" in
  1|true|TRUE|yes|YES)
    PACKAGE_VALIDATE_ONLY_ENABLED=1
    ;;
  0|false|FALSE|no|NO|"")
    PACKAGE_VALIDATE_ONLY_ENABLED=0
    ;;
  *)
    echo "Invalid PACKAGE_VALIDATE_ONLY value: $PACKAGE_VALIDATE_ONLY" >&2
    echo "Use 1/true/yes or 0/false/no." >&2
    exit 1
    ;;
esac

PACKAGE_SMOKE_TEST_MODE="auto"
case "$PACKAGE_SMOKE_TEST" in
  auto|AUTO|"")
    PACKAGE_SMOKE_TEST_MODE="auto"
    ;;
  1|true|TRUE|yes|YES)
    PACKAGE_SMOKE_TEST_MODE="enabled"
    ;;
  0|false|FALSE|no|NO)
    PACKAGE_SMOKE_TEST_MODE="disabled"
    ;;
  *)
    echo "Invalid PACKAGE_SMOKE_TEST value: $PACKAGE_SMOKE_TEST" >&2
    echo "Use auto, 1/true/yes, or 0/false/no." >&2
    exit 1
    ;;
esac

PACKAGE_RUNTIME_INTERACTION_SMOKE_ENABLED=0
case "$PACKAGE_RUNTIME_INTERACTION_SMOKE" in
  auto|AUTO|"")
    if [ -n "$PACKAGE_SMOKE_EVIDENCE" ]; then
      PACKAGE_RUNTIME_INTERACTION_SMOKE_ENABLED=1
    else
      PACKAGE_RUNTIME_INTERACTION_SMOKE_ENABLED=0
    fi
    ;;
  1|true|TRUE|yes|YES)
    PACKAGE_RUNTIME_INTERACTION_SMOKE_ENABLED=1
    ;;
  0|false|FALSE|no|NO)
    PACKAGE_RUNTIME_INTERACTION_SMOKE_ENABLED=0
    ;;
  *)
    echo "Invalid PACKAGE_RUNTIME_INTERACTION_SMOKE value: $PACKAGE_RUNTIME_INTERACTION_SMOKE" >&2
    echo "Use auto, 1/true/yes, or 0/false/no." >&2
    exit 1
    ;;
esac

PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE_ENABLED=0
case "$PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE" in
  auto|AUTO|"")
    if [ -n "$PACKAGE_SMOKE_EVIDENCE" ]; then
      PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE_ENABLED=1
    else
      PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE_ENABLED=0
    fi
    ;;
  1|true|TRUE|yes|YES)
    PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE_ENABLED=1
    ;;
  0|false|FALSE|no|NO)
    PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE_ENABLED=0
    ;;
  *)
    echo "Invalid PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE value: $PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE" >&2
    echo "Use auto, 1/true/yes, or 0/false/no." >&2
    exit 1
    ;;
esac

print_composite_quality_notice() {
  local bundle_dir="$1"
  local bundle_name="$2"
  local context="$3"
  local quality_output
  local has_warning=0
  local has_recommendation=0

  quality_output="$("$VALIDATOR_BIN" --wallpaper-root "$bundle_dir" --composite-quality-plan)"
  if grep -q '^status: warning' <<< "$quality_output"; then
    has_warning=1
  fi
  if grep -q '^recommendations:$' <<< "$quality_output"; then
    has_recommendation=1
  fi
  if [ "$has_warning" -eq 1 ] || [ "$has_recommendation" -eq 1 ]; then
    if [ "$has_warning" -eq 1 ]; then
      echo "$context composite fallback quality warning: $bundle_name" >&2
    else
      echo "$context composite fallback quality recommendation: $bundle_name" >&2
    fi
    echo "$quality_output" >&2
    if [ "$has_warning" -eq 1 ] && [ "$STRICT_COMPOSITE_QUALITY_ENABLED" -eq 1 ]; then
      echo "STRICT_COMPOSITE_QUALITY is enabled; packaging will fail on this warning." >&2
    elif [ "$has_warning" -eq 1 ]; then
      echo "Set STRICT_COMPOSITE_QUALITY=1 to fail packaging on this warning." >&2
    fi
  fi
}

validate_wallpaper_bundle() {
  local bundle_dir="$1"
  local bundle_name="$2"
  local context="$3"

  if ! "$VALIDATOR_BIN" --wallpaper-root "$bundle_dir" --validate-only >/dev/null; then
    echo "$context wallpaper bundle failed validation: $bundle_name ($bundle_dir)" >&2
    exit 1
  fi

  print_composite_quality_notice "$bundle_dir" "$bundle_name" "$context"

  if [ "$STRICT_COMPOSITE_QUALITY_ENABLED" -eq 1 ]; then
    if ! "$VALIDATOR_BIN" --wallpaper-root "$bundle_dir" --validate-only --strict-composite-quality >/dev/null; then
      echo "$context wallpaper bundle failed strict composite quality validation: $bundle_name ($bundle_dir)" >&2
      exit 1
    fi
  fi
}

write_package_runtime_metadata() {
  cat > "$RESOURCES_DIR/package-runtime.txt" <<EOF
metadataVersion: 1
bundleID: $BUNDLE_ID
packageMode: local-manual-start
signaturePolicy: unsigned-no-certificate
inputPermissionHint: Accessibility prompt once in GUI session; event tap when trusted; global monitors fallback otherwise
EOF
}

json_safe_text() {
  printf "%s" "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/'\''/g'
}

write_package_smoke_evidence() {
  if [ -z "$PACKAGE_SMOKE_EVIDENCE" ]; then
    return
  fi
  if [ -f "$PACKAGE_SMOKE_EVIDENCE" ]; then
    echo "Packaged runtime smoke evidence written: $PACKAGE_SMOKE_EVIDENCE" >&2
    return
  fi
  if [ "$PACKAGE_SMOKE_TEST_PASSED" -ne 1 ]; then
    echo "Packaged launch smoke evidence skipped: packaged smoke test did not run successfully." >&2
    return
  fi

  local evidence_dir
  evidence_dir="$(dirname "$PACKAGE_SMOKE_EVIDENCE")"
  mkdir -p "$evidence_dir"

  local recorded_at
  recorded_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  local interaction_status
  interaction_status="$("$MACOS_DIR/$APP_NAME" --interaction-plan 2>/dev/null | sed -n 's/^desktopMonitor: //p' | head -n 1)"
  interaction_status="$(json_safe_text "${interaction_status:-unknown}")"
  local input_permission_status
  input_permission_status="$("$MACOS_DIR/$APP_NAME" --input-status 2>/dev/null | awk -F': ' '/^inputPolicy:/ {print $2; exit}')"
  input_permission_status="$(json_safe_text "${input_permission_status:-unknown}")"
  local physical_display_count
  physical_display_count="$("$MACOS_DIR/$APP_NAME" --physical-render-plan 2>/dev/null | awk '/^displayCount:/ {print $2; exit}')"
  physical_display_count="$(json_safe_text "${physical_display_count:-unknown}")"
  cat > "$PACKAGE_SMOKE_EVIDENCE" <<EOF
{
  "schemaVersion": "mac-wallpaper-manual-smoke.v1",
  "packagedAppLaunchSmoke": {
    "passed": true,
    "recordedAt": "$recorded_at",
    "evidence": "package smoke gate launched dist/MacWallpaperEngine.app without crash for ${PACKAGE_SMOKE_TEST_DURATION}s"
  },
  "liveDesktopClickActions": {
    "passed": false,
    "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
    "evidence": "Current packaged input policy: $input_permission_status; interaction status: $interaction_status. Run --interaction-plan for the selected bundle; verify manifest-declared pointerMove/pointerDown click and gaze behavior plus application-window gating. No Accessibility permission should be requested.",
    "operatorNote": "Manual live interaction confirmation is still required, but no macOS Accessibility grant is part of the checklist."
  },
  "physicalDisplayHotplugSmoke": {
    "passed": false,
    "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
    "evidence": "Current packaged physical display count: $physical_display_count. Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays on multiple physical displays; reconnect or wake displays; record whether macOS Displays have separate Spaces is enabled or disabled; confirm wallpaper windows restore on target displays.",
    "operatorNote": "Required before physical-display-hotplug-smoke can pass."
  },
  "blackFrameFlickerSmoke": {
    "passed": false,
    "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
    "evidence": "Current packaged physical display count: $physical_display_count. Start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; confirm no black frame, no visible flicker loop, and no crash.",
    "operatorNote": "Required before black-frame-flicker-smoke can pass."
  }
}
EOF
  echo "Packaged launch smoke evidence written: $PACKAGE_SMOKE_EVIDENCE" >&2
}

run_packaged_smoke_test() {
  if [ "$PACKAGE_SMOKE_TEST_MODE" = "disabled" ]; then
    echo "Packaged hidden launch smoke test skipped: PACKAGE_SMOKE_TEST=0" >&2
    return
  fi

  if [ "$PACKAGE_SMOKE_TEST_MODE" = "auto" ] && ! pgrep -x WindowServer >/dev/null 2>&1; then
    echo "Packaged hidden launch smoke test skipped: no WindowServer detected; set PACKAGE_SMOKE_TEST=1 to force." >&2
    return
  fi

  local smoke_args=(
    --wallpaper-only
    --hidden
    --duration "$PACKAGE_SMOKE_TEST_DURATION"
    --display-mode selectedOnly
  )
  if [ "$PACKAGE_RUNTIME_INTERACTION_SMOKE_ENABLED" -eq 1 ]; then
    smoke_args+=(--run-runtime-interaction-smoke)
  fi
  if [ "$PACKAGE_RUNTIME_DISPLAY_REBUILD_SMOKE_ENABLED" -eq 1 ]; then
    smoke_args+=(--run-runtime-display-rebuild-smoke)
  fi
  if [ -n "$PACKAGE_SMOKE_EVIDENCE" ]; then
    local evidence_dir
    evidence_dir="$(dirname "$PACKAGE_SMOKE_EVIDENCE")"
    mkdir -p "$evidence_dir"
    smoke_args+=(--write-runtime-smoke-evidence "$PACKAGE_SMOKE_EVIDENCE")
  fi

  if ! "$MACOS_DIR/$APP_NAME" "${smoke_args[@]}" >/dev/null; then
    echo "Packaged hidden launch smoke test failed: $APP_DIR" >&2
    exit 1
  fi
  echo "Packaged hidden launch smoke test OK (${PACKAGE_SMOKE_TEST_DURATION}s)" >&2
  PACKAGE_SMOKE_TEST_PASSED=1
}

find_bundle_symlink_entries() {
  local bundle_dir="$1"
  find "$bundle_dir" \
    \( -name ".DS_Store" -o -name "._*" -o -name ".git" -o -name ".hg" -o -name ".svn" -o -name ".Spotlight-V100" -o -name ".Trashes" -o -name "__MACOSX" \) -prune \
    -o -type l -print
}

if [ ! -d "$WALLPAPER_SOURCE" ]; then
  echo "Wallpaper source directory is missing: $WALLPAPER_SOURCE" >&2
  exit 1
fi

swift build -c release --package-path "$SCRIPT_DIR"

if [ "$PACKAGE_VALIDATE_ONLY_ENABLED" -eq 1 ]; then
  bundle_count=0
  for bundle_dir in "$WALLPAPER_SOURCE"/*; do
    [ -d "$bundle_dir" ] || continue
    [ -f "$bundle_dir/wallpaper.native.json" ] || continue
    bundle_name="$(basename "$bundle_dir")"

    if [ -L "$bundle_dir" ]; then
      echo "Skipping symlinked wallpaper bundle: $bundle_name" >&2
      continue
    fi
    symlink_path="$(find_bundle_symlink_entries "$bundle_dir")"
    if [ -n "$symlink_path" ]; then
      first_symlink="${symlink_path%%$'\n'*}"
      echo "Invalid wallpaper bundle contains symlinked entry: $bundle_name ($first_symlink)" >&2
      exit 1
    fi

    validate_wallpaper_bundle "$bundle_dir" "$bundle_name" "Source"
    bundle_count=$((bundle_count + 1))
  done

  if [ "$bundle_count" -eq 0 ]; then
    echo "No valid wallpaper bundles found under $WALLPAPER_SOURCE" >&2
    exit 1
  fi

  echo "Package validation-only OK: $bundle_count bundle(s)"
  exit 0
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$WALLPAPER_DEST" "$SCHEMA_DEST"

cp "$SCRIPT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"
cp "$SCHEMA_SOURCE" "$SCHEMA_DEST/wallpaper-native-v2.schema.json"

bundle_count=0
for bundle_dir in "$WALLPAPER_SOURCE"/*; do
  [ -d "$bundle_dir" ] || continue
  [ -f "$bundle_dir/wallpaper.native.json" ] || continue
  bundle_name="$(basename "$bundle_dir")"

  if [ -L "$bundle_dir" ]; then
    echo "Skipping symlinked wallpaper bundle: $bundle_name" >&2
    continue
  fi
  symlink_path="$(find_bundle_symlink_entries "$bundle_dir")"
  if [ -n "$symlink_path" ]; then
    first_symlink="${symlink_path%%$'\n'*}"
    echo "Invalid wallpaper bundle contains symlinked entry: $bundle_name ($first_symlink)" >&2
    exit 1
  fi

  validate_wallpaper_bundle "$bundle_dir" "$bundle_name" "Source"

  mkdir -p "$WALLPAPER_DEST/$bundle_name"
  rsync -a \
    --exclude ".DS_Store" \
    --exclude "._*" \
    --exclude ".git/" \
    --exclude ".hg/" \
    --exclude ".svn/" \
    --exclude ".Spotlight-V100/" \
    --exclude ".Trashes/" \
    --exclude "__MACOSX/" \
    "${PACKAGE_COPY_EXCLUDES[@]}" \
    "$bundle_dir/" "$WALLPAPER_DEST/$bundle_name/"

  validate_wallpaper_bundle "$WALLPAPER_DEST/$bundle_name" "$bundle_name" "Packaged"

  bundle_count=$((bundle_count + 1))
done

if [ "$bundle_count" -eq 0 ]; then
  echo "No valid wallpaper bundles found under $WALLPAPER_SOURCE" >&2
  exit 1
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Mac Wallpaper Engine</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Mac Wallpaper Engine</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

write_package_runtime_metadata

# Anchor the packaged self-test to the repo root and point the active wallpaper
# root into the dist bundle. A packaged binary resolves projectRoot to its own
# bundle resources, so the retired fixture tree is handed over explicitly by
# absolute path for the audit union.
if ! (cd "$PROJECT_ROOT" && MAC_WALLPAPER_ENGINE_RETIRED_FIXTURES="$PROJECT_ROOT/.build-cache/sample-fixtures-retired" "$MACOS_DIR/$APP_NAME" --self-test --wallpaper-root "$WALLPAPER_DEST/yumeko" >/dev/null); then
  echo "Packaged app self-test failed: $APP_DIR" >&2
  exit 1
fi

if ! "$MACOS_DIR/$APP_NAME" --validate-bundles --strict-composite-quality --bundle-library "$WALLPAPER_DEST" >/dev/null; then
  echo "Packaged app bundle validation matrix failed: $APP_DIR" >&2
  exit 1
fi

run_packaged_smoke_test
write_package_smoke_evidence

echo "$APP_DIR"
