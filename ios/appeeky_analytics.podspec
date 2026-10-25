Pod::Spec.new do |s|
  s.name             = 'appeeky_analytics'
  s.version          = '0.1.0'
  s.summary          = 'Appeeky Analytics for Flutter: native side for iOS.'
  s.description      = 'Apple Search Ads attribution token, SKAdNetwork / AdAttributionKit conversion values and the launch URL for the appeeky_analytics Flutter plugin.'
  s.homepage         = 'https://appeeky.com'
  s.license          = { :type => 'FSL-1.1-MIT', :file => '../LICENSE' }
  s.author           = 'Appeeky'
  s.source           = { :path => '.' }
  s.source_files     = 'appeeky_analytics/Sources/appeeky_analytics/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'
  s.frameworks       = 'StoreKit'
  # AdServices (iOS 14.3) and AdAttributionKit (iOS 17.4) are newer than the
  # deployment target; every use is behind #available.
  s.weak_frameworks  = 'AdServices', 'AdAttributionKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
