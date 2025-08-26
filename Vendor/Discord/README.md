Discord Game SDK Integration
=================================

Place the official Discord Game SDK files here to enable real Rich Presence.

Expected layout (macOS):

- include/
  - *.h (C++ header) from the SDK
- lib/
  - discord_game_sdk.dylib (macOS universal binary provided by the SDK)

Steps:

run `sh scripts/setup_discord_sdk.sh` to download the latest version of the Discord Game SDK.