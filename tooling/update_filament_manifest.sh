#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/tooling/filament_manifest.json"

android_hash=$(find "$ROOT_DIR/tooling/filament-android-maven" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
ios_hash=$(find "$ROOT_DIR/ios/Filament.xcframework" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
license_hash=$(shasum -a 256 "$ROOT_DIR/ios/Filament.LICENSE" | awk '{print $1}')
readme_hash=$(shasum -a 256 "$ROOT_DIR/ios/Filament.README.md" | awk '{print $1}')

printf '{\n  "filament_version": "1.68.4",\n  "generated_at": "%s",\n  "android_maven_sha256": "%s",\n  "ios_xcframework_sha256": "%s",\n  "ios_license_sha256": "%s",\n  "ios_readme_sha256": "%s"\n}\n' "$(date +%F)" "$android_hash" "$ios_hash" "$license_hash" "$readme_hash" > "$MANIFEST_PATH"

echo "Updated $MANIFEST_PATH"
