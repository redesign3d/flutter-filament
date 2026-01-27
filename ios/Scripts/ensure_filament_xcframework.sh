#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[filament_widget] $*"
}

fail() {
  echo "[filament_widget] ERROR: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PODS_TARGET_SRCROOT:-}" ]]; then
  ROOT_DIR="$PODS_TARGET_SRCROOT"
else
  ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

MANIFEST_PATH="$ROOT_DIR/tooling/filament_manifest.json"
TARGET_DIR="$ROOT_DIR/ios/Filament.xcframework"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  fail "Missing manifest: $MANIFEST_PATH"
fi

python_cmd="python3"
if ! command -v "$python_cmd" >/dev/null 2>&1; then
  fail "python3 is required to parse $MANIFEST_PATH"
fi

get_manifest_value() {
  local key="$1"
  "$python_cmd" -c "import json;print(json.load(open('$MANIFEST_PATH')).get('$key',''))"
}

has_lfs_pointers() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 1
  fi
  grep -R --fixed-strings "git-lfs.github.com/spec/v1" "$dir" >/dev/null 2>&1
}

validate_slices() {
  local dir="$1"
  [[ -d "$dir/ios-arm64" ]] || fail "Missing required iOS device slice: ios-arm64"
  if [[ ! -d "$dir/ios-arm64_x86_64-simulator" ]] && [[ ! -d "$dir/ios-arm64-simulator" ]] && [[ ! -d "$dir/ios-x86_64-simulator" ]]; then
    fail "Missing required iOS simulator slice (ios-arm64_x86_64-simulator, ios-arm64-simulator, or ios-x86_64-simulator)."
  fi
}

hash_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    fail "Missing sha256 tool (shasum or sha256sum)."
  fi
}

hash_dir() {
  local dir="$1"
  if command -v shasum >/dev/null 2>&1; then
    LC_ALL=C find "$dir" -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    LC_ALL=C find "$dir" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | awk '{print $1}' | sha256sum | awk '{print $1}'
  else
    fail "Missing sha256 tool (shasum or sha256sum)."
  fi
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" ]] || [[ "$value" == "REPLACE_ME" ]] || [[ "$value" == *"example.com"* ]]
}

filament_version="$(get_manifest_value filament_version)"
zip_url="$(get_manifest_value ios_xcframework_zip_url)"
zip_sha="$(get_manifest_value ios_xcframework_zip_sha256)"
expected_dir_sha="$(get_manifest_value ios_xcframework_sha256)"

if [[ -n "${FILAMENT_WIDGET_IOS_XCFRAMEWORK_URL:-}" ]]; then
  zip_url="$FILAMENT_WIDGET_IOS_XCFRAMEWORK_URL"
fi

if [[ -n "${FILAMENT_WIDGET_LOCAL_XCFRAMEWORK:-}" ]]; then
  local_src="$FILAMENT_WIDGET_LOCAL_XCFRAMEWORK"
  [[ -d "$local_src" ]] || fail "FILAMENT_WIDGET_LOCAL_XCFRAMEWORK does not exist: $local_src"
  has_lfs_pointers "$local_src" && fail "Local XCFramework contains Git LFS pointer files."
  validate_slices "$local_src"
  rm -rf "$TARGET_DIR"
  cp -R "$local_src" "$TARGET_DIR"
  validate_slices "$TARGET_DIR"
  log "Using local Filament.xcframework override."
  exit 0
fi

if [[ -d "$TARGET_DIR" ]]; then
  if has_lfs_pointers "$TARGET_DIR"; then
    log "Detected Git LFS pointers in $TARGET_DIR; will re-download."
    rm -rf "$TARGET_DIR"
  else
    validate_slices "$TARGET_DIR"
    if ! is_placeholder "$expected_dir_sha"; then
      actual_dir_sha="$(hash_dir "$TARGET_DIR")"
      if [[ "$actual_dir_sha" != "$expected_dir_sha" ]]; then
        log "XCFramework checksum mismatch; will re-download."
        rm -rf "$TARGET_DIR"
      else
        log "Filament.xcframework is present and verified."
        exit 0
      fi
    else
      log "Filament.xcframework is present."
      exit 0
    fi
  fi
fi

if [[ "${FILAMENT_WIDGET_DISABLE_BINARY_DOWNLOAD:-}" == "1" ]]; then
  fail "Binary download disabled. Set FILAMENT_WIDGET_LOCAL_XCFRAMEWORK to a local Filament.xcframework or unset FILAMENT_WIDGET_DISABLE_BINARY_DOWNLOAD."
fi

if is_placeholder "$zip_url" || is_placeholder "$zip_sha"; then
  fail "ios_xcframework_zip_url and ios_xcframework_zip_sha256 must be set in tooling/filament_manifest.json (or override with FILAMENT_WIDGET_IOS_XCFRAMEWORK_URL)."
fi

cache_root="$HOME/.cache/filament_widget"
if [[ "$(uname -s)" == "Darwin" ]]; then
  cache_root="$HOME/Library/Caches/filament_widget"
fi

cache_dir="$cache_root/$filament_version/$zip_sha"
cache_zip="$cache_dir/Filament.xcframework.zip"
mkdir -p "$cache_dir"

if [[ ! -f "$cache_zip" ]]; then
  log "Downloading Filament.xcframework..."
  curl -fL --retry 2 --retry-delay 1 -o "$cache_zip" "$zip_url"
fi

actual_zip_sha="$(hash_file "$cache_zip")"
if [[ "$actual_zip_sha" != "$zip_sha" ]]; then
  rm -f "$cache_zip"
  fail "XCFramework zip checksum mismatch. Expected $zip_sha, got $actual_zip_sha."
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
archive_type="zip"
if [[ "$zip_url" == *.tgz ]] || [[ "$zip_url" == *.tar.gz ]]; then
  archive_type="tgz"
fi

if [[ "$archive_type" == "zip" ]]; then
  unzip -q "$cache_zip" -d "$work_dir"
else
  tar -xzf "$cache_zip" -C "$work_dir"
fi

xcframework_path=""
if [[ -d "$work_dir/Filament.xcframework" ]]; then
  xcframework_path="$work_dir/Filament.xcframework"
else
  xcframework_path="$(find "$work_dir" -maxdepth 3 -type d -name "Filament.xcframework" | head -n 1)"
fi

if [[ -z "$xcframework_path" ]]; then
  filament_root="$(find "$work_dir" -maxdepth 2 -type d -name "filament" | head -n 1)"
  if [[ -z "$filament_root" ]]; then
    fail "Downloaded archive does not contain Filament.xcframework or a filament/ directory."
  fi
  lib_dir="$filament_root/lib/universal"
  include_dir="$filament_root/include"
  [[ -d "$lib_dir" ]] || fail "Missing Filament libraries at $lib_dir"
  [[ -d "$include_dir" ]] || fail "Missing Filament headers at $include_dir"

  log "Building Filament.xcframework from release archive."
  combined_lib="$work_dir/libfilament_all.a"
  /usr/bin/libtool -static -o "$combined_lib" "$lib_dir"/*.a

  device_lib="$work_dir/libfilament_all_device.a"
  sim_lib="$work_dir/libfilament_all_sim.a"
  lipo -thin arm64 "$combined_lib" -output "$device_lib"
  lipo -thin x86_64 "$combined_lib" -output "$sim_lib"

  xcodebuild -create-xcframework \
    -library "$device_lib" -headers "$include_dir" \
    -library "$sim_lib" -headers "$include_dir" \
    -output "$work_dir/Filament.xcframework" >/dev/null

  xcframework_path="$work_dir/Filament.xcframework"
fi

validate_slices "$xcframework_path"
has_lfs_pointers "$xcframework_path" && fail "Downloaded XCFramework contains Git LFS pointer files."

rm -rf "$TARGET_DIR"
mkdir -p "$(dirname "$TARGET_DIR")"
mv "$xcframework_path" "$TARGET_DIR"

validate_slices "$TARGET_DIR"
if ! is_placeholder "$expected_dir_sha"; then
  actual_dir_sha="$(hash_dir "$TARGET_DIR")"
  if [[ "$actual_dir_sha" != "$expected_dir_sha" ]]; then
    rm -rf "$TARGET_DIR"
    fail "XCFramework directory checksum mismatch. Expected $expected_dir_sha, got $actual_dir_sha."
  fi
fi

log "Filament.xcframework is ready."
