#!/usr/bin/env bash
set -euo pipefail

VERSION="1.68.4"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/ios"
XCFRAMEWORK_PATH="$OUT_DIR/Filament.xcframework"

has_required_slices() {
  [[ -d "$XCFRAMEWORK_PATH/ios-arm64" ]] || return 1
  [[ -d "$XCFRAMEWORK_PATH/ios-x86_64-simulator" ]] || return 1
  return 0
}

if [[ -d "$XCFRAMEWORK_PATH" ]]; then
  if has_required_slices; then
    echo "Filament xcframework already exists at $XCFRAMEWORK_PATH"
    exit 0
  fi
  echo "Existing xcframework missing simulator slices; rebuilding."
  rm -rf "$XCFRAMEWORK_PATH"
fi

WORK_DIR="$(mktemp -d)"
ARCHIVE_PATH="$WORK_DIR/filament-ios.tgz"

curl -L -o "$ARCHIVE_PATH" "https://github.com/google/filament/releases/download/v$VERSION/filament-v$VERSION-ios.tgz"

tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR"

SRC_DIR="$WORK_DIR/filament"
LIB_DIR="$SRC_DIR/lib/universal"
INCLUDE_DIR="$SRC_DIR/include"

mkdir -p "$OUT_DIR"

DEVICE_DIR="$WORK_DIR/device_arm64"
SIM_X86_64_DIR="$WORK_DIR/sim_x86_64"
mkdir -p "$DEVICE_DIR" "$SIM_X86_64_DIR"

DEVICE_LIB="$DEVICE_DIR/libfilament_all.a"
SIM_X86_64_LIB="$SIM_X86_64_DIR/libfilament_all.a"


/usr/bin/libtool -static -arch_only arm64 -o "$DEVICE_LIB" "$LIB_DIR"/*.a
/usr/bin/libtool -static -arch_only x86_64 -o "$SIM_X86_64_LIB" "$LIB_DIR"/*.a

echo "Device lib architectures: $(/usr/bin/lipo -info "$DEVICE_LIB")"
echo "Simulator x86_64 lib architectures: $(/usr/bin/lipo -info "$SIM_X86_64_LIB")"

/usr/bin/xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$INCLUDE_DIR" \
  -library "$SIM_X86_64_LIB" -headers "$INCLUDE_DIR" \
  -output "$XCFRAMEWORK_PATH"

cp "$SRC_DIR/LICENSE" "$OUT_DIR/Filament.LICENSE"
cp "$SRC_DIR/README.md" "$OUT_DIR/Filament.README.md"

rm -rf "$WORK_DIR"

echo "Filament xcframework ready in $XCFRAMEWORK_PATH"
