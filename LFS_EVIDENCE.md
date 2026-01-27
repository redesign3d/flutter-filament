# LFS and vendored artifact checks (2026-01-27)

## LFS pointer checks
- ios/Filament.xcframework/ios-arm64/libfilament_all.a: not an LFS pointer (file begins with `!<arch>`).
- tooling/filament-android-maven/**/**/*.aar: not an LFS pointer (binary ZIP header present).

## LFS rules
- .gitattributes contains LFS filters for:
  - ios/Filament.xcframework/**
  - tooling/filament-android-maven/**
  - tooling/filament-tools/**

## CI
- .github/workflows/ci.yml checks out with `lfs: true` and runs `git lfs pull`.

## iOS podspec
- ios/filament_widget.podspec uses `s.vendored_frameworks = 'Filament.xcframework'`.

## Android Gradle
- android/build.gradle contains an `allprojects { repositories { ... file:// tooling/filament-android-maven ... } }` block.
