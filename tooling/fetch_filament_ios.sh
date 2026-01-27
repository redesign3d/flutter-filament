#!/usr/bin/env bash
set -euo pipefail

VERSION="1.68.4"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/ios"
XCFRAMEWORK_PATH="$OUT_DIR/Filament.xcframework"
SOURCE_URL="https://github.com/google/filament"
SOURCE_REF="v$VERSION"

has_required_slices() {
  [[ -d "$XCFRAMEWORK_PATH/ios-arm64" ]] || return 1
  if [[ -d "$XCFRAMEWORK_PATH/ios-arm64-simulator" ]] || [[ -d "$XCFRAMEWORK_PATH/ios-arm64_x86_64-simulator" ]]; then
    return 0
  fi
  return 1
}

has_optional_slice() {
  [[ -d "$XCFRAMEWORK_PATH/ios-x86_64-simulator" ]] || [[ -d "$XCFRAMEWORK_PATH/ios-arm64_x86_64-simulator" ]]
}

if [[ -d "$XCFRAMEWORK_PATH" ]]; then
  if has_required_slices; then
    echo "Filament xcframework already exists at $XCFRAMEWORK_PATH"
    if has_optional_slice; then
      echo "Found optional ios-x86_64-simulator slice."
    else
      echo "Warning: ios-x86_64-simulator slice not found (optional)."
    fi
    exit 0
  fi
  echo "Existing xcframework missing required slices; rebuilding."
  rm -rf "$XCFRAMEWORK_PATH"
fi

WORK_DIR="$(mktemp -d)"
SRC_DIR="${FILAMENT_SOURCE_DIR:-$WORK_DIR/filament}"

if [[ -z "${FILAMENT_SOURCE_DIR:-}" ]]; then
  echo "Cloning Filament source at $SOURCE_REF..."
  git clone --depth 1 --branch "$SOURCE_REF" "$SOURCE_URL" "$SRC_DIR"
fi

TOOLCHAIN_FILE="$SRC_DIR/third_party/clang/iOS.cmake"
if [[ -f "$TOOLCHAIN_FILE" ]] && ! grep -q "ios-simulator" "$TOOLCHAIN_FILE"; then
  perl -0pi -e 's/SET\(PLATFORM_FLAG_NAME ios\)/SET(PLATFORM_FLAG_NAME ios)\n\nIF(PLATFORM_NAME STREQUAL "iphonesimulator")\n  SET(PLATFORM_FLAG_NAME ios-simulator)\nENDIF()/s' "$TOOLCHAIN_FILE"
fi

BUILD_ROOT="$WORK_DIR/build"
DEVICE_PREFIX="$BUILD_ROOT/ios-release-device/filament"
SIM_ARM64_PREFIX="$BUILD_ROOT/ios-release-sim-arm64/filament"
SIM_X86_64_PREFIX="$BUILD_ROOT/ios-release-sim-x86_64/filament"

echo "Building Filament host tools (release)..."
pushd "$SRC_DIR" > /dev/null
./build.sh -p desktop -i release matc resgen cmgen filamesh uberz
popd > /dev/null

BUILD_GENERATOR="Unix Makefiles"
BUILD_COMMAND="make -j$(sysctl -n hw.ncpu)"

build_ios() {
  local arch="$1"
  local platform="$2"
  local build_dir="$3"
  local install_prefix="$4"

  mkdir -p "$build_dir"
  pushd "$build_dir" > /dev/null
  cmake \
    -G "$BUILD_GENERATOR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_prefix" \
    -DIOS_ARCH="$arch" \
    -DPLATFORM_NAME="$platform" \
    -DIOS=1 \
    -DFILAMENT_SKIP_SAMPLES=ON \
    -DIMPORT_EXECUTABLES_DIR="out" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    "$SRC_DIR"
  $BUILD_COMMAND
  $BUILD_COMMAND install
  popd > /dev/null
}

echo "Building Filament iOS device arm64..."
build_ios "arm64" "iphoneos" "$BUILD_ROOT/cmake-ios-release-arm64" "$DEVICE_PREFIX"

echo "Building Filament iOS simulator arm64..."
build_ios "arm64" "iphonesimulator" "$BUILD_ROOT/cmake-ios-release-arm64-sim" "$SIM_ARM64_PREFIX"

echo "Building Filament iOS simulator x86_64 (optional)..."
build_ios "x86_64" "iphonesimulator" "$BUILD_ROOT/cmake-ios-release-x86_64-sim" "$SIM_X86_64_PREFIX"

mkdir -p "$OUT_DIR"

DEVICE_LIB="$BUILD_ROOT/device/libfilament_all.a"
SIM_ARM64_LIB="$BUILD_ROOT/sim/libfilament_all_arm64.a"
SIM_X86_64_LIB="$BUILD_ROOT/sim/libfilament_all_x86_64.a"
SIM_UNIVERSAL_LIB="$BUILD_ROOT/sim/libfilament_all.a"

DEVICE_LIB_DIR="$DEVICE_PREFIX/lib/arm64"
SIM_ARM64_LIB_DIR="$SIM_ARM64_PREFIX/lib/arm64"
SIM_X86_64_LIB_DIR="$SIM_X86_64_PREFIX/lib/x86_64"

mkdir -p "$(dirname "$DEVICE_LIB")" "$(dirname "$SIM_ARM64_LIB")"

/usr/bin/libtool -static -o "$DEVICE_LIB" "$DEVICE_LIB_DIR"/*.a
/usr/bin/libtool -static -o "$SIM_ARM64_LIB" "$SIM_ARM64_LIB_DIR"/*.a
/usr/bin/libtool -static -o "$SIM_X86_64_LIB" "$SIM_X86_64_LIB_DIR"/*.a

SIM_LIB="$SIM_ARM64_LIB"
if [[ -f "$SIM_X86_64_LIB" ]]; then
  /usr/bin/lipo -create "$SIM_ARM64_LIB" "$SIM_X86_64_LIB" -output "$SIM_UNIVERSAL_LIB"
  SIM_LIB="$SIM_UNIVERSAL_LIB"
fi

INCLUDE_DIR="$DEVICE_PREFIX/include"

/usr/bin/xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$INCLUDE_DIR" \
  -library "$SIM_LIB" -headers "$INCLUDE_DIR" \
  -output "$XCFRAMEWORK_PATH"

cp "$SRC_DIR/LICENSE" "$OUT_DIR/Filament.LICENSE"
cp "$SRC_DIR/README.md" "$OUT_DIR/Filament.README.md"

rm -rf "$WORK_DIR"

if ! has_required_slices; then
  echo "Error: missing required slices after build."
  exit 1
fi

echo "Filament xcframework ready in $XCFRAMEWORK_PATH"
