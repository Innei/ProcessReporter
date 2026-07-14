#!/usr/bin/env bash
set -euo pipefail

# Setup Discord Game SDK for ProcessReporter
# - Downloads the SDK zip
# - Extracts macOS headers and dylib
# - Places them under Vendor/Discord/{include,lib}
#
# Usage:
#   bash scripts/setup_discord_sdk.sh [SDK_URL] [SDK_SHA256]
#
# Defaults to v3.2.1 if URL not provided:
#   https://dl-game-sdk.discordapp.net/3.2.1/discord_game_sdk.zip
#
# Requirements: curl, unzip, find, awk

DEFAULT_URL="https://dl-game-sdk.discordapp.net/3.2.1/discord_game_sdk.zip"
DEFAULT_SHA256="6757bb4a1f5b42aa7b6707cbf2158420278760ac5d80d40ca708bb01d20ae6b4"
SDK_URL="${1:-${DISCORD_SDK_URL:-$DEFAULT_URL}}"
SDK_SHA256="${2:-${DISCORD_SDK_SHA256:-$DEFAULT_SHA256}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/Discord"
INCLUDE_DIR="$VENDOR_DIR/include"
LIB_DIR="$VENDOR_DIR/lib"

echo "[setup] Using SDK URL: $SDK_URL"

mkdir -p "$INCLUDE_DIR" "$LIB_DIR"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t discord_sdk)"
ZIP_PATH="$TMP_DIR/discord_game_sdk.zip"
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"

cleanup() { rm -rf "$TMP_DIR" || true; }
trap cleanup EXIT

echo "[setup] Downloading SDK to $ZIP_PATH ..."
curl -fL \
  --connect-timeout 15 \
  --max-time 180 \
  --retry 3 \
  --retry-all-errors \
  --retry-delay 2 \
  --retry-max-time 240 \
  "$SDK_URL" \
  -o "$ZIP_PATH"

echo "[setup] Verifying SDK archive checksum ..."
ACTUAL_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SDK_SHA256" ]]; then
  echo "[setup] ERROR: Discord SDK checksum mismatch." >&2
  echo "[setup] Expected: $SDK_SHA256" >&2
  echo "[setup] Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

echo "[setup] Extracting SDK ..."
unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"

# Locate C++ headers directory (should contain discord.h and all dependencies)
CPP_HEADERS_DIR="$(find "$EXTRACT_DIR" -maxdepth 4 -type d -name "cpp" | head -n1 || true)"
HEADER_C="$(find "$EXTRACT_DIR" -maxdepth 4 -type f -name "discord_game_sdk.h" | head -n1 || true)"

if [[ -n "$CPP_HEADERS_DIR" && -f "$CPP_HEADERS_DIR/discord.h" ]]; then
  echo "[setup] Found C++ headers directory: $CPP_HEADERS_DIR"
  echo "[setup] Copying all C++ headers..."
  CPP_HEADERS=("$CPP_HEADERS_DIR"/*.h)
  cp -f "${CPP_HEADERS[@]}" "$INCLUDE_DIR/"
  echo "[setup] Copied ${#CPP_HEADERS[@]} header files"
elif [[ -n "$HEADER_C" ]]; then
  echo "[setup] WARNING: C++ headers not found; using C header: $HEADER_C"
  echo "         The bridge will use the C header directly."
  cp -f "$HEADER_C" "$INCLUDE_DIR/discord_game_sdk.h"
else
  echo "[setup] ERROR: Could not locate C++ headers or discord_game_sdk.h in the SDK archive." >&2
  exit 1
fi

# Build one universal macOS dylib. The release archive is universal, so copying
# only the runner's native slice would make the other architecture fail at
# launch even when the application itself compiled successfully.
ARM64_DYLIB="$(find "$EXTRACT_DIR" \( -path "*/aarch64/*.dylib" -o -path "*/arm64/*.dylib" \) | head -n1 || true)"
X86_64_DYLIB="$(find "$EXTRACT_DIR" -path "*/x86_64/*.dylib" | head -n1 || true)"

if [[ -z "$ARM64_DYLIB" || -z "$X86_64_DYLIB" ]]; then
  echo "[setup] ERROR: Discord SDK archive does not contain both arm64 and x86_64 macOS dylibs." >&2
  exit 1
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "[setup] ERROR: lipo is required to create the universal Discord SDK dylib." >&2
  exit 1
fi

echo "[setup] Found arm64 dylib: $ARM64_DYLIB"
echo "[setup] Found x86_64 dylib: $X86_64_DYLIB"
lipo -create "$ARM64_DYLIB" "$X86_64_DYLIB" \
  -output "$LIB_DIR/discord_game_sdk.dylib"

echo "[setup] Verifying outputs ..."
ls -l "$INCLUDE_DIR" || true
ls -l "$LIB_DIR" || true

# Verify both required architecture slices.
ARCHS="$(lipo -archs "$LIB_DIR/discord_game_sdk.dylib")"
echo "[setup] dylib architectures: $ARCHS"
case " $ARCHS " in
  *" arm64 "*) ;;
  *) echo "[setup] ERROR: universal dylib is missing arm64." >&2; exit 1 ;;
esac
case " $ARCHS " in
  *" x86_64 "*) ;;
  *) echo "[setup] ERROR: universal dylib is missing x86_64." >&2; exit 1 ;;
esac

echo "[setup] Done. You can now build the Xcode project."
