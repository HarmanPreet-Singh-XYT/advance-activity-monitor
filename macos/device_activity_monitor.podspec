Pod::Spec.new do |s|
  s.name             = 'device_activity_monitor'
  s.version          = '0.1.0'
  s.summary          = 'Monitors audio output, HID devices, and game controllers for user activity.'
  s.description      = <<-DESC
    A Flutter plugin that detects user activity via system audio output peak,
    HID device input (gamepads, drawing tablets, wheels, etc.), and game
    controllers (GameController framework). Designed as a companion to
    window_focus for screen-time inactivity detection. No microphone access
    is required or requested.
  DESC

  s.homepage         = 'https://github.com/HarmanPreet-Singh-XYT/device_activity_monitor'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'HarmanPreet-Singh-XYT' => 'expert@HarmanPreet-Singh-XYT' }

  # ── Source ────────────────────────────────────────────────────────────
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  # ── Platform ──────────────────────────────────────────────────────────
  # macOS 10.15+ required for:
  #   - IOHIDManager input value callbacks (available earlier but stable from 10.15)
  #   - GameController framework (GCController.controllers(), GCControllerDidConnect)
  #   - AudioObjectAddPropertyListenerBlock
  s.platform         = :osx, '10.15'

  # ── Flutter dependency ────────────────────────────────────────────────
  s.dependency 'FlutterMacOS'

  # ── Frameworks ────────────────────────────────────────────────────────
  # CoreAudio    — AudioUnit, AudioOutputUnit, AudioObjectGetPropertyData,
  #                AudioUnitAddRenderNotify, AudioObjectAddPropertyListenerBlock
  # AudioToolbox — AudioComponent*, kAudioUnitType_Output, kAudioUnitSubType_HALOutput
  # IOKit        — IOHIDManager, IOHIDManagerCreate, IOHIDValueCallback
  # GameController — GCController, GCControllerDidConnect notification
  s.frameworks = 'CoreAudio', 'AudioToolbox', 'IOKit', 'GameController'

  # ── Build settings ────────────────────────────────────────────────────
  s.pod_target_xcconfig = {
    # Required for Flutter plugin symbol visibility
    'DEFINES_MODULE'               => 'YES',

    # Exclude arm64 simulator slice — Flutter macOS does not support it yet
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',

    # Swift version
    'SWIFT_VERSION'                => '5.0',

    # Silence AudioToolbox deprecation warnings on newer SDKs.
    # AudioUnitAddRenderNotify and related HAL APIs are deprecated in
    # favour of AVAudioEngine on iOS, but remain the correct approach
    # on macOS for permission-free output monitoring.
    'GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS' => 'NO',
  }

  s.swift_version = '5.0'
end
