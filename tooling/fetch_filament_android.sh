#!/usr/bin/env bash
set -euo pipefail

VERSION="1.68.4"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT_DIR/tooling/filament-android-maven/com/google/android/filament"

mkdir -p "$DEST_DIR"

download_artifact() {
  local artifact_id="$1"
  local asset_name="$2"
  local artifact_dir="$DEST_DIR/$artifact_id/$VERSION"
  local aar_path="$artifact_dir/$artifact_id-$VERSION.aar"
  local pom_path="$artifact_dir/$artifact_id-$VERSION.pom"

  mkdir -p "$artifact_dir"

  if [[ ! -f "$aar_path" ]]; then
    curl -L -o "$aar_path" "https://github.com/google/filament/releases/download/v$VERSION/$asset_name"
  fi

  if [[ ! -f "$pom_path" ]]; then
    cat > "$pom_path" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.google.android.filament</groupId>
  <artifactId>$artifact_id</artifactId>
  <version>$VERSION</version>
  <packaging>aar</packaging>
</project>
EOF
  fi
}

download_artifact "filament-android" "filament-v$VERSION-android.aar"
download_artifact "gltfio-android" "gltfio-v$VERSION-android.aar"
download_artifact "filament-utils-android" "filament-utils-v$VERSION-android.aar"
download_artifact "filamat-android" "filamat-v$VERSION-android.aar"

echo "Filament Android artifacts ready in $DEST_DIR"
