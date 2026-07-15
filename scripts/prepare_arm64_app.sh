#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/ProcessReporter.app" >&2
  exit 64
fi

APP_PATH="$1"
DISTRIBUTION_MODE="${DISTRIBUTION_MODE:-adhoc}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Application bundle does not exist: $APP_PATH" >&2
  exit 1
fi

case "$DISTRIBUTION_MODE" in
  adhoc)
    SIGNING_TARGET=-
    ;;
  developer-id)
    if [[ -z "$SIGNING_IDENTITY" ]]; then
      echo "SIGNING_IDENTITY is required for Developer ID distribution." >&2
      exit 1
    fi
    SIGNING_TARGET="$SIGNING_IDENTITY"
    ;;
  *)
    echo "Unsupported distribution mode: $DISTRIBUTION_MODE" >&2
    exit 1
    ;;
esac

DISCORD_BINARY="$APP_PATH/Contents/Frameworks/discord_game_sdk.dylib"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
SPARKLE_BINARY="$SPARKLE_VERSION/Sparkle"
AUTOUPDATE_BINARY="$SPARKLE_VERSION/Autoupdate"
UPDATER_APP="$SPARKLE_VERSION/Updater.app"
UPDATER_BINARY="$UPDATER_APP/Contents/MacOS/Updater"
DOWNLOADER_XPC="$SPARKLE_VERSION/XPCServices/Downloader.xpc"
DOWNLOADER_BINARY="$DOWNLOADER_XPC/Contents/MacOS/Downloader"
INSTALLER_XPC="$SPARKLE_VERSION/XPCServices/Installer.xpc"
INSTALLER_BINARY="$INSTALLER_XPC/Contents/MacOS/Installer"
APP_BINARY="$APP_PATH/Contents/MacOS/ProcessReporter"

BINARIES=(
  "$APP_BINARY"
  "$DISCORD_BINARY"
  "$SPARKLE_BINARY"
  "$AUTOUPDATE_BINARY"
  "$UPDATER_BINARY"
  "$DOWNLOADER_BINARY"
  "$INSTALLER_BINARY"
)

thin_arm64() {
  local binary="$1"
  local architectures mode temporary

  if [[ ! -f "$binary" ]]; then
    echo "Missing release binary: $binary" >&2
    exit 1
  fi

  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" == "arm64" ]]; then
    return
  fi
  if [[ " $architectures " != *" arm64 "* ]]; then
    echo "Binary has no arm64 slice: $binary ($architectures)" >&2
    exit 1
  fi

  mode="$(stat -f '%Lp' "$binary")"
  temporary="$(mktemp "${TMPDIR:-/tmp}/processreporter-arm64.XXXXXX")"
  lipo "$binary" -thin arm64 -output "$temporary"
  chmod "$mode" "$temporary"
  mv -f "$temporary" "$binary"
  echo "Thinned to arm64: $binary"
}

sign_code() {
  local code_path="$1"
  local arguments=(
    --force
    --sign "$SIGNING_TARGET"
    --preserve-metadata=identifier,entitlements
    --generate-entitlement-der
  )

  if [[ "$DISTRIBUTION_MODE" == "developer-id" ]]; then
    arguments+=(--options runtime --timestamp)
  fi
  codesign "${arguments[@]}" "$code_path"
}

for binary in "${BINARIES[@]}"; do
  thin_arm64 "$binary"
done

# Re-sign from the deepest nested code outward after lipo invalidates the
# original code directories.
sign_code "$AUTOUPDATE_BINARY"
sign_code "$UPDATER_APP"
sign_code "$DOWNLOADER_XPC"
sign_code "$INSTALLER_XPC"
sign_code "$SPARKLE_FRAMEWORK"
sign_code "$DISCORD_BINARY"
sign_code "$APP_PATH"

for binary in "${BINARIES[@]}"; do
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Binary is not arm64-only after preparation: $binary ($architectures)" >&2
    exit 1
  fi
done

# Guard the complete artifact rather than only the currently known dependency
# layout. Any future framework, plug-in, helper, or executable must either ship
# as arm64-only or make the release fail visibly.
mach_o_count=0
while IFS= read -r -d '' candidate; do
  case "$(file -b "$candidate")" in
    Mach-O*)
      architectures="$(lipo -archs "$candidate")"
      if [[ "$architectures" != "arm64" ]]; then
        echo "Unexpected architecture in application bundle: $candidate ($architectures)" >&2
        exit 1
      fi
      mach_o_count=$((mach_o_count + 1))
      ;;
  esac
done < <(find "$APP_PATH" -type f -print0)

if ((mach_o_count == 0)); then
  echo "Application bundle contains no Mach-O binaries: $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Prepared arm64-only application ($mach_o_count Mach-O files): $APP_PATH"
