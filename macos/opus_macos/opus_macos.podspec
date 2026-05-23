Pod::Spec.new do |s|
  s.name             = 'opus_macos'
  s.version          = '1.6.1'
  s.summary          = 'Bundled libopus framework for macOS.'
  s.description      = 'libopus dynamic framework so opus_dart can use DynamicLibrary.process() on macOS.'
  s.homepage         = 'https://opus-codec.org'
  s.license          = { :type => 'BSD' }
  s.author           = { 'opus' => 'opus@opus-codec.org' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '10.15'
  s.vendored_frameworks = 'opus.framework'
end
