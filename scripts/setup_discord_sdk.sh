#!/usr/bin/env bash
set -euo pipefail

# Setup Discord Game SDK for ProcessReporter
# - Downloads the SDK zip
# - Extracts macOS headers and dylib
# - Places them under Vendor/Discord/{include,lib}
#
# Usage:
#   scripts/setup_discord_sdk.sh [SDK_URL]
#
# Defaults to v3.2.1 if URL not provided:
#   https://dl-game-sdk.discordapp.net/3.2.1/discord_game_sdk.zip
#
# Requirements: curl, unzip, find, awk

DEFAULT_URL="https://dl-game-sdk.discordapp.net/3.2.1/discord_game_sdk.zip"
SDK_URL="${1:-${DISCORD_SDK_URL:-$DEFAULT_URL}}"

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
curl -fL "$SDK_URL" -o "$ZIP_PATH"

echo "[setup] Extracting SDK ..."
unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"

# Locate C++ headers directory (should contain discord.h and all dependencies)
CPP_HEADERS_DIR="$(find "$EXTRACT_DIR" -maxdepth 4 -type d -name "cpp" | head -n1 || true)"
HEADER_C="$(find "$EXTRACT_DIR" -maxdepth 4 -type f -name "discord_game_sdk.h" | head -n1 || true)"

if [[ -n "$CPP_HEADERS_DIR" && -f "$CPP_HEADERS_DIR/discord.h" ]]; then
  echo "[setup] Found C++ headers directory: $CPP_HEADERS_DIR"
  echo "[setup] Copying all C++ headers..."
  cp -f "$CPP_HEADERS_DIR"/*.h "$INCLUDE_DIR/"
  echo "[setup] Copied $(ls "$CPP_HEADERS_DIR"/*.h | wc -l | tr -d ' ') header files"
elif [[ -n "$HEADER_C" ]]; then
  echo "[setup] WARNING: C++ headers not found; using C header: $HEADER_C"
  echo "         The bridge prefers C++ headers. Build will fall back to shim if missing."
  cp -f "$HEADER_C" "$INCLUDE_DIR/discord_game_sdk.h"
else
  echo "[setup] ERROR: Could not locate C++ headers or discord_game_sdk.h in the SDK archive." >&2
  exit 1
fi

# Locate macOS dylib based on system architecture
SYSTEM_ARCH="$(uname -m)"
case "$SYSTEM_ARCH" in
"arm64")
  ARCH_DIR="aarch64"
  ;;
"x86_64")
  ARCH_DIR="x86_64"
  ;;
*)
  echo "[setup] WARNING: Unknown architecture '$SYSTEM_ARCH', defaulting to x86_64" >&2
  ARCH_DIR="x86_64"
  ;;
esac

echo "[setup] Detected system architecture: $SYSTEM_ARCH (using $ARCH_DIR)"

# First try to find architecture-specific dylib
DYLIB_SRC="$(find "$EXTRACT_DIR" -path "*/$ARCH_DIR/*.dylib" | head -n1 || true)"

# If architecture-specific not found, try any dylib as fallback
if [[ -z "$DYLIB_SRC" ]]; then
  echo "[setup] Architecture-specific dylib not found, searching for any dylib..."
  echo "[setup] ERROR: Could not locate a .dylib in the SDK archive." >&2
  echo "        Please verify you downloaded the macOS SDK package." >&2
  exit 1
fi

echo "[setup] Found dylib: $DYLIB_SRC"
cp -f "$DYLIB_SRC" "$LIB_DIR/discord_game_sdk.dylib"

echo "[setup] Verifying outputs ..."
ls -l "$INCLUDE_DIR" || true
ls -l "$LIB_DIR" || true

# Verify architecture slices
if command -v lipo >/dev/null 2>&1; then
  ARCHS=$(lipo -archs "$LIB_DIR/discord_game_sdk.dylib" 2>/dev/null || echo "")
  echo "[setup] dylib architectures: ${ARCHS:-unknown}"
  case "$ARCHS" in
    *arm64*) : ;; 
    *) echo "[setup] WARNING: dylib does not contain arm64 slice. Building for Apple Silicon will fail." ;;
  esac
else
  echo "[setup] Note: 'lipo' not found, skipping architecture check."
fi

echo "[setup] Done. You can now build the Xcode project."
