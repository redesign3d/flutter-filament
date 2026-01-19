#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint filament_widget.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'filament_widget'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.vendored_frameworks = 'Filament.xcframework'
  s.frameworks = ['Metal', 'MetalKit', 'QuartzCore', 'CoreVideo', 'CoreGraphics', 'UIKit']
  s.libraries = 'c++'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Filament.xcframework/ios-arm64/Headers" "$(PODS_TARGET_SRCROOT)/Filament.xcframework/ios-x86_64-simulator/Headers"'
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'filament_widget_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
