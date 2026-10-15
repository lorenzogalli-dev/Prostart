Pod::Spec.new do |s|
  s.name             = 'photofinish_camera'
  s.version          = '0.0.1'
  s.summary          = 'ProStart photofinish camera.'
  s.description      = 'High-fps camera with host-clock frame stamps and MediaPipe Pose torso crossing.'
  s.homepage         = 'https://github.com/lorenzogalli-dev'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'ProStart' => 'lorenzo.galli155@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'photofinish_camera/Sources/photofinish_camera/**/*.swift'
  s.dependency 'Flutter'
  # Same model family as the colleagues' Python (MediaPipe Pose Landmarker).
  s.dependency 'MediaPipeTasksVision', '1.0.0'
  s.platform = :ios, '15.0'
  s.static_framework = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
