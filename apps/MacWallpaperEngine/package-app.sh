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
STRICT_COMPOSITE_QUALITY="${STRICT_COMPOSITE_QUALITY:-0}"

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

print_composite_quality_warning() {
  local bundle_dir="$1"
  local bundle_name="$2"
  local context="$3"
  local quality_output

  quality_output="$("$MACOS_DIR/$APP_NAME" --wallpaper-root "$bundle_dir" --composite-quality-plan)"
  if grep -q '^status: warning' <<< "$quality_output"; then
    echo "$context composite fallback quality warning: $bundle_name" >&2
    echo "$quality_output" >&2
    if [ "$STRICT_COMPOSITE_QUALITY_ENABLED" -eq 1 ]; then
      echo "STRICT_COMPOSITE_QUALITY is enabled; packaging will fail on this warning." >&2
    else
      echo "Set STRICT_COMPOSITE_QUALITY=1 to fail packaging on this warning." >&2
    fi
  fi
}

validate_wallpaper_bundle() {
  local bundle_dir="$1"
  local bundle_name="$2"
  local context="$3"

  if ! "$MACOS_DIR/$APP_NAME" --wallpaper-root "$bundle_dir" --validate-only >/dev/null; then
    echo "$context wallpaper bundle failed validation: $bundle_name ($bundle_dir)" >&2
    exit 1
  fi

  print_composite_quality_warning "$bundle_dir" "$bundle_name" "$context"

  if [ "$STRICT_COMPOSITE_QUALITY_ENABLED" -eq 1 ]; then
    if ! "$MACOS_DIR/$APP_NAME" --wallpaper-root "$bundle_dir" --validate-only --strict-composite-quality >/dev/null; then
      echo "$context wallpaper bundle failed strict composite quality validation: $bundle_name ($bundle_dir)" >&2
      exit 1
    fi
  fi
}

if [ ! -d "$WALLPAPER_SOURCE" ]; then
  echo "Wallpaper source directory is missing: $WALLPAPER_SOURCE" >&2
  exit 1
fi

swift build -c release --package-path "$SCRIPT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$WALLPAPER_DEST"

cp "$SCRIPT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"

bundle_count=0
for bundle_dir in "$WALLPAPER_SOURCE"/*; do
  [ -d "$bundle_dir" ] || continue
  [ -f "$bundle_dir/wallpaper.native.json" ] || continue
  bundle_name="$(basename "$bundle_dir")"

  if [ -L "$bundle_dir" ]; then
    echo "Skipping symlinked wallpaper bundle: $bundle_name" >&2
    continue
  fi
  symlink_path="$(find "$bundle_dir" -type l -print)"
  if [ -n "$symlink_path" ]; then
    first_symlink="${symlink_path%%$'\n'*}"
    echo "Invalid wallpaper bundle contains symlinked entry: $bundle_name ($first_symlink)" >&2
    exit 1
  fi

  validate_wallpaper_bundle "$bundle_dir" "$bundle_name" "Source"

  mkdir -p "$WALLPAPER_DEST/$bundle_name"
  rsync -a --exclude ".DS_Store" "$bundle_dir/" "$WALLPAPER_DEST/$bundle_name/"

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

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

if ! "$MACOS_DIR/$APP_NAME" --self-test >/dev/null; then
  echo "Packaged app self-test failed: $APP_DIR" >&2
  exit 1
fi

echo "$APP_DIR"
