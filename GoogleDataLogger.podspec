Pod::Spec.new do |s|
  s.name             = 'GoogleDataLogger'
  s.version          = '0.1.0'
  s.summary          = 'Google Data Logging iOS SDK.'


  s.description      = <<-DESC
Shared library for iOS SDK data logging needs.
                       DESC

  s.homepage         = 'https://developers.google.com/'
  s.license          = { :type => 'Apache', :file => 'LICENSE' }
  s.authors          = 'Google, Inc.'
  s.source           = {
    :git => 'https://github.com/firebase/firebase-ios-sdk.git',
    :tag => 'GoogleDataLogger-' + s.version.to_s
  }

  s.ios.deployment_target = '8.0'

  s.cocoapods_version = '>= 1.6.0.rc.2'

  s.static_framework = true
  s.prefix_header_file = false

  s.source_files = 'GoogleDataLogger/GoogleDataLogger/**/*'
  s.public_header_files = 'GoogleDataLogger/GoogleDataLogger/Classes/Public/*.h'
  s.private_header_files = 'GoogleDataLogger/GoogleDataLogger/Classes/Private/*.h'

  s.dependency 'GoogleUtilities/Logger'

  s.pod_target_xcconfig = {
    'GCC_C_LANGUAGE_STANDARD' => 'c99',
    'GCC_TREAT_WARNINGS_AS_ERRORS' => 'YES',
    'CLANG_UNDEFINED_BEHAVIOR_SANITIZER_NULLABILITY' => 'YES'
  }

  common_test_sources = ['GoogleDataLogger/Tests/Common/**/*.{h,m}']

  # Unit test specs
  s.test_spec 'TestsUnit' do |test_spec|
    test_spec.requires_app_host = false
    test_spec.source_files = ['GoogleDataLogger/Tests/Unit/**/*.{h,m}'] + common_test_sources
  end
end