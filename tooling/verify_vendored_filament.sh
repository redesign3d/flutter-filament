#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/tooling/filament_manifest.json"

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
  find "$dir" -type f -print0 | sort -z | xargs -0 shasum -a 256 | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
}

file_hash() {
  local file="$1"
  shasum -a 256 "$file" | awk '{print $1}'
}

expected_android_hash="$(get_manifest_value android_maven_sha256)"
expected_ios_hash="$(get_manifest_value ios_xcframework_sha256)"
expected_license_hash="$(get_manifest_value ios_license_sha256)"
expected_readme_hash="$(get_manifest_value ios_readme_sha256)"

actual_android_hash="$(dir_hash "$ROOT_DIR/tooling/filament-android-maven")"
actual_ios_hash="$(dir_hash "$ROOT_DIR/ios/Filament.xcframework")"
actual_license_hash="$(file_hash "$ROOT_DIR/ios/Filament.LICENSE")"
actual_readme_hash="$(file_hash "$ROOT_DIR/ios/Filament.README.md")"

if [[ "$expected_android_hash" != "$actual_android_hash" ]]; then
  echo "Android Filament Maven hash mismatch." >&2
  echo "Expected: $expected_android_hash" >&2
  echo "Actual:   $actual_android_hash" >&2
  exit 1
fi

if [[ "$expected_ios_hash" != "$actual_ios_hash" ]]; then
  echo "iOS Filament XCFramework hash mismatch." >&2
  echo "Expected: $expected_ios_hash" >&2
  echo "Actual:   $actual_ios_hash" >&2
  exit 1
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

if [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-arm64" ]]; then
  echo "Missing required iOS device slice: ios-arm64" >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-arm64-simulator" ]] && [[ ! -d "$ROOT_DIR/ios/Filament.xcframework/ios-arm64_x86_64-simulator" ]]; then
  echo "Missing required iOS simulator slice." >&2
  exit 1
fi

echo "Vendored Filament artifacts verified."
