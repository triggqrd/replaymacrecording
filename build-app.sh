#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/dist/ReplayMac.app"
BIN_NAME="ReplayMac"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Resources/ReplayMac.dev.entitlements"
ICON_PATH="$ROOT_DIR/Resources/ReplayMac.icns"

# --appstore: Mac App Store variant — compiles out the GitHub update checker
# (-DAPPSTORE) and signs with the App Store entitlements (no network client).
# Local testing only; the actual MAS submission still needs Distribution
# signing and a provisioning profile via Xcode/Transporter.
APPSTORE_FLAG=""
if [ "${1:-}" = "--appstore" ]; then
  APPSTORE_FLAG="-Xswiftc -DAPPSTORE"
  ENTITLEMENTS="$ROOT_DIR/Resources/ReplayMac.appstore.entitlements"
  printf 'Building Mac App Store variant (update checker disabled).\n'
fi

resolve_signing_identity() {
  if [ -n "${SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' "$SIGNING_IDENTITY"
    return
  fi

  local line
  while IFS= read -r line; do
    case "$line" in
      *"Apple Development:"*)
        local identity
        identity="${line#*\"}"
        identity="${identity%\"*}"
        printf '%s\n' "$identity"
        return
        ;;
    esac
  done < <(security find-identity -v -p codesigning 2>/dev/null || true)

  printf '%s\n' "-"
}

SIGN_IDENTITY="$(resolve_signing_identity)"

if [ "$SIGN_IDENTITY" = "-" ]; then
  printf 'Warning: No Apple Development certificate found; using ad-hoc signing. macOS may ask for screen/audio permission repeatedly after rebuilds.\n'
else
  printf 'Using signing identity: %s\n' "$SIGN_IDENTITY"
fi

# Build once so SPM generates resource bundle accessors
# shellcheck disable=SC2086  # APPSTORE_FLAG intentionally word-splits into two args
swift build -c release --package-path "$ROOT_DIR" $APPSTORE_FLAG

# Patch generated accessors to load bundles from Contents/Resources
# instead of the app root, which avoids breaking code signing.
for accessor in "$ROOT_DIR"/.build/arm64-apple-macosx/release/*.build/DerivedSources/resource_bundle_accessor.swift; do
  if [ -f "$accessor" ]; then
    sed -i '' 's|Bundle.main.bundleURL.appendingPathComponent("\(.*\)_\1.bundle")|Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\1_\1.bundle")|g' "$accessor"
  fi
done

# Rebuild so the patched accessors are compiled in
# shellcheck disable=SC2086
swift build -c release --package-path "$ROOT_DIR" $APPSTORE_FLAG

BIN_DIR="$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")"
BIN_PATH="$BIN_DIR/$BIN_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"

if [ -f "$ICON_PATH" ]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/ReplayMac.icns"
fi

# Copy SPM resource bundles into Contents/Resources so they are sealed by codesign
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
  fi
done

# Hardened runtime + secure timestamp are required for notarization.
# Ad-hoc signatures support neither, so only add them for real identities.
HARDENING_FLAGS=""
if [ "$SIGN_IDENTITY" != "-" ]; then
  HARDENING_FLAGS="--options runtime --timestamp"
fi

# shellcheck disable=SC2086  # HARDENING_FLAGS intentionally word-splits
codesign --force --deep $HARDENING_FLAGS --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

printf "Built app: %s\n" "$APP_DIR"
