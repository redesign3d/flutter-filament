#!/usr/bin/env bash
set -euo pipefail

VERSION="1.68.4"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/ios"
XCFRAMEWORK_PATH="$OUT_DIR/Filament.xcframework"

if [[ -d "$XCFRAMEWORK_PATH" ]]; then
  echo "Filament xcframework already exists at $XCFRAMEWORK_PATH"
  exit 0
fi

WORK_DIR="$(mktemp -d)"
ARCHIVE_PATH="$WORK_DIR/filament-ios.tgz"

curl -L -o "$ARCHIVE_PATH" "https://github.com/google/filament/releases/download/v$VERSION/filament-v$VERSION-ios.tgz"

tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR"

SRC_DIR="$WORK_DIR/filament"
LIB_DIR="$SRC_DIR/lib/universal"
INCLUDE_DIR="$SRC_DIR/include"

mkdir -p "$OUT_DIR"

MERGED_LIB="$WORK_DIR/libfilament_all.a"
/usr/bin/libtool -static -o "$MERGED_LIB" "$LIB_DIR"/*.a

ARM64_DIR="$WORK_DIR/arm64"
X86_64_DIR="$WORK_DIR/x86_64"
mkdir -p "$ARM64_DIR" "$X86_64_DIR"

ARM64_LIB="$ARM64_DIR/libfilament_all.a"
X86_64_LIB="$X86_64_DIR/libfilament_all.a"

/usr/bin/lipo -extract arm64 "$MERGED_LIB" -output "$ARM64_LIB"
/usr/bin/lipo -extract x86_64 "$MERGED_LIB" -output "$X86_64_LIB"

/usr/bin/xcodebuild -create-xcframework \
  -library "$ARM64_LIB" -headers "$INCLUDE_DIR" \
  -library "$X86_64_LIB" -headers "$INCLUDE_DIR" \
  -output "$XCFRAMEWORK_PATH"

cp "$SRC_DIR/LICENSE" "$OUT_DIR/Filament.LICENSE"
cp "$SRC_DIR/README.md" "$OUT_DIR/Filament.README.md"

rm -rf "$WORK_DIR"

echo "Filament xcframework ready in $XCFRAMEWORK_PATH"
