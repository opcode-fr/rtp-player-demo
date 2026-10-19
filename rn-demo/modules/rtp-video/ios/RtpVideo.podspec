Pod::Spec.new do |s|
  s.name           = 'RtpVideo'
  s.version        = '0.1.0'
  s.summary        = 'Lecteur RTP/UDP H.264 natif pour React Native'
  s.description    = 'Réception RTP/UDP, dépaquetage H.264 et décodage VideoToolbox, sans dépendance tierce.'
  s.author         = 'opcode'
  s.homepage       = 'https://github.com/opcode-fr/rtp-player-demo'
  s.license        = { type: 'MIT', file: '../../../../LICENSE' }
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  # RtpCore/ est aussi un Swift Package (Package.swift) pour les tests sur Mac : on l'exclut ici.
  s.source_files  = '*.swift', 'RtpCore/**/*.swift'
  s.exclude_files = 'Package.swift', 'Tests/**/*'
end
