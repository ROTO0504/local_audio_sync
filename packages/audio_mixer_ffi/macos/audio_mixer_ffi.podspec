Pod::Spec.new do |s|
  s.name             = 'audio_mixer_ffi'
  s.version          = '1.0.0'
  s.summary          = 'miniaudio-based cross-platform audio mixer exposed via Dart FFI.'
  s.description      = <<-DESC
Cross-platform audio mixer (hub playback) built on miniaudio, exposed to Dart
via FFI. The shared C++ implementation lives in ../src and is compiled as
Objective-C++ for consistency with the iOS build.
                       DESC
  s.homepage         = 'https://github.com/example/local-audio-sync'
  s.license          = { :type => 'MIT' }
  s.author           = { 'local-audio-sync' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '13.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.frameworks = 'AudioToolbox', 'CoreAudio'
  s.library = 'c++'
end
