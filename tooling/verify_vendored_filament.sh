#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/tooling/filament_manifest.json"
IOS_RESOLVER="$ROOT_DIR/ios/Scripts/ensure_filament_xcframework.sh"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "Missing manifest: $MANIFEST_PATH" >&2
  exit 1
fi

python_cmd="python3"
if ! command -v "$python_cmd" >/dev/null 2>&1; then
  echo "python3 is required to parse $MANIFEST_PATH" >&2
  exit 1
fi

get_manifest_value() {
  local key="$1"
  "$python_cmd" -c "import json;print(json.load(open('$MANIFEST_PATH'))['$1'])"
}

dir_hash() {
  local dir="$1"
  LC_ALL=C find "$dir" -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
}

file_hash() {
  local file="$1"
  shasum -a 256 "$file" | awk '{print $1}'
}

has_lfs_pointers() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 1
  fi
  grep -R --fixed-strings "git-lfs.github.com/spec/v1" "$dir" >/dev/null 2>&1
}

expected_android_hash="$(get_manifest_value android_maven_sha256)"
expected_ios_hash="$(get_manifest_value ios_xcframework_sha256)"
expected_ios_zip_hash="$(get_manifest_value ios_xcframework_zip_sha256)"
expected_license_hash="$(get_manifest_value ios_license_sha256)"
expected_readme_hash="$(get_manifest_value ios_readme_sha256)"

if has_lfs_pointers "$ROOT_DIR/ios/Filament.xcframework"; then
  echo "iOS XCFramework contains Git LFS pointer files." >&2
  exit 1
fi

if has_lfs_pointers "$ROOT_DIR/tooling/filament-android-maven"; then
  echo "Android Maven mirror contains Git LFS pointer files." >&2
  exit 1
fi

if has_lfs_pointers "$ROOT_DIR/tooling/filament-tools"; then
  echo "Filament tools mirror contains Git LFS pointer files." >&2
  exit 1
fi

if [[ -x "$IOS_RESOLVER" ]]; then
  "$IOS_RESOLVER"
fi

if [[ -d "$ROOT_DIR/tooling/filament-android-maven" ]]; then
  actual_android_hash="$(dir_hash "$ROOT_DIR/tooling/filament-android-maven")"
else
  actual_android_hash=""
fi

if [[ -d "$ROOT_DIR/ios/Filament.xcframework" ]]; then
  actual_ios_hash="$(dir_hash "$ROOT_DIR/ios/Filament.xcframework")"
else
  actual_ios_hash=""
fi
actual_license_hash="$(file_hash "$ROOT_DIR/ios/Filament.LICENSE")"
actual_readme_hash="$(file_hash "$ROOT_DIR/ios/Filament.README.md")"

if [[ -n "$actual_android_hash" ]] && [[ "$expected_android_hash" != "$actual_android_hash" ]]; then
  echo "Android Filament Maven hash mismatch." >&2
  echo "Expected: $expected_android_hash" >&2
  echo "Actual:   $actual_android_hash" >&2
  exit 1
fi

if [[ -n "$actual_ios_hash" ]] && [[ "$expected_ios_hash" != "$actual_ios_hash" ]]; then
  echo "iOS Filament XCFramework hash mismatch." >&2
  echo "Expected: $expected_ios_hash" >&2
  echo "Actual:   $actual_ios_hash" >&2
  exit 1
fi

if [[ -n "$expected_ios_zip_hash" ]]; then
  cache_root="$HOME/.cache/filament_widget"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    cache_root="$HOME/Library/Caches/filament_widget"
  fi
  filament_version="$(get_manifest_value filament_version)"
  cache_zip="$cache_root/$filament_version/$expected_ios_zip_hash/Filament.xcframework.zip"
  if [[ -f "$cache_zip" ]]; then
    actual_zip_hash="$(file_hash "$cache_zip")"
    if [[ "$expected_ios_zip_hash" != "$actual_zip_hash" ]]; then
      echo "iOS XCFramework zip hash mismatch." >&2
      echo "Expected: $expected_ios_zip_hash" >&2
      echo "Actual:   $actual_zip_hash" >&2
      exit 1
    fi
  fi
fi

if [[ "$expected_license_hash" != "$actual_license_hash" ]]; then
  echo "Filament.LICENSE hash mismatch." >&2
  echo "Expected: $expected_license_hash" >&2
  echo "Actual:   $actual_license_hash" >&2
  exit 1
fi

if [[ "$expected_readme_hash" != "$actual_readme_hash" ]]; then
  echo "Filament.README.md hash mismatch." >&2
  echo "Expected: $expected_readme_hash" >&2
  echo "Actual:   $actual_readme_hash" >&2
  exit 1
fi

if [[ -n "$actual_ios_hash" ]] && [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-arm64" ]]; then
  echo "Missing required iOS device slice: ios-arm64" >&2
  exit 1
fi

if [[ -n "$actual_ios_hash" ]] && [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-arm64-simulator" ]] && [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-arm64_x86_64-simulator" ]] && [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-x86_64-simulator" ]]; then
  echo "Missing required iOS simulator slice." >&2
  exit 1
fi

echo "Vendored Filament artifacts verified."
