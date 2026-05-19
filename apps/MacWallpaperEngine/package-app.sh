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
STRICT_COMPOSITE_QUALITY="${STRICT_COMPOSITE_QUALITY:-0}"
PACKAGE_VALIDATE_ONLY="${PACKAGE_VALIDATE_ONLY:-0}"
PACKAGE_SMOKE_TEST="${PACKAGE_SMOKE_TEST:-auto}"
PACKAGE_SMOKE_TEST_DURATION="${PACKAGE_SMOKE_TEST_DURATION:-2}"
PACKAGE_SMOKE_EVIDENCE="${PACKAGE_SMOKE_EVIDENCE:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_DEEP="${CODESIGN_DEEP:-1}"
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

CODESIGN_DEEP_ENABLED=0
case "$CODESIGN_DEEP" in
  1|true|TRUE|yes|YES)
    CODESIGN_DEEP_ENABLED=1
    ;;
  0|false|FALSE|no|NO|"")
    CODESIGN_DEEP_ENABLED=0
    ;;
  *)
    echo "Invalid CODESIGN_DEEP value: $CODESIGN_DEEP" >&2
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

sign_app_bundle() {
  if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign not found; packaged app will remain unsigned." >&2
    return
  fi

  local sign_args=(--force)
  if [ "$CODESIGN_DEEP_ENABLED" -eq 1 ]; then
    sign_args+=(--deep)
  fi
  sign_args+=(--sign "$CODESIGN_IDENTITY" "$APP_DIR")
  codesign "${sign_args[@]}" >/dev/null

  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "Packaged app was ad-hoc signed. macOS Accessibility permission may need to be re-granted after each rebuild." >&2
    echo "Set CODESIGN_IDENTITY to a stable local signing identity to keep TCC/Accessibility identity stable during development." >&2
  else
    echo "Packaged app signed with identity: $CODESIGN_IDENTITY" >&2
  fi
}

write_package_signing_metadata() {
  local codesign_mode="identity"
  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    codesign_mode="adhoc"
  fi

  cat > "$RESOURCES_DIR/package-signing.txt" <<EOF
metadataVersion: 1
bundleID: $BUNDLE_ID
codesignIdentity: $CODESIGN_IDENTITY
codesignMode: $codesign_mode
codesignDeep: $CODESIGN_DEEP_ENABLED
accessibilityTrustHint: click/touch actions require macOS Accessibility trust; ad-hoc signed rebuilds may need re-adding this app in System Settings
EOF
}

json_safe_text() {
  printf "%s" "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/'\''/g'
}

write_package_smoke_evidence() {
  if [ -z "$PACKAGE_SMOKE_EVIDENCE" ]; then
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
  local accessibility_status
  accessibility_status="$("$MACOS_DIR/$APP_NAME" --accessibility-status 2>/dev/null | awk -F': ' '/^accessibilityStatus:/ {print $2; exit}')"
  accessibility_status="$(json_safe_text "${accessibility_status:-unknown}")"
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
    "evidence": "Current packaged accessibility status: $accessibility_status; interaction status: $interaction_status. Grant Accessibility to the current app; enable click actions; verify head short tap=boll, head hold/rub>=0.18s=act, body tap=boll, empty click=no action, left-drag gaze changes direction.",
    "operatorNote": "Required before live-desktop-click-actions can pass."
  },
  "physicalDisplayHotplugSmoke": {
    "passed": false,
    "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
    "evidence": "Current packaged physical display count: $physical_display_count. Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays; reconnect or wake displays and confirm wallpaper windows restore on target displays.",
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

  if ! "$MACOS_DIR/$APP_NAME" \
    --wallpaper-only \
    --hidden \
    --duration "$PACKAGE_SMOKE_TEST_DURATION" \
    --display-mode selectedOnly >/dev/null; then
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

write_package_signing_metadata
sign_app_bundle

if ! "$MACOS_DIR/$APP_NAME" --self-test >/dev/null; then
  echo "Packaged app self-test failed: $APP_DIR" >&2
  exit 1
fi

if ! "$MACOS_DIR/$APP_NAME" --validate-bundles --strict-composite-quality >/dev/null; then
  echo "Packaged app bundle validation matrix failed: $APP_DIR" >&2
  exit 1
fi

run_packaged_smoke_test
write_package_smoke_evidence

echo "$APP_DIR"
