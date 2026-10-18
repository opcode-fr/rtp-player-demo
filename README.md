# rtp-player-demo

Démonstrateur de lecteur **RTP/UDP H.264** pour Android et iOS, sans VLC ni FFmpeg embarqué :
uniquement les API du système (sockets, MediaCodec, AVSampleBufferDisplayLayer / VideoToolbox).
Aucune dépendance d'exécution, donc aucune contrainte LGPL.

## Ce que ça fait

```
UDP (unicast) -> RTP (RFC 3550) -> remise en ordre -> H.264 (RFC 6184) -> décodeur matériel -> écran
```

- Le SDP du flux est collé dans l'appli : port, type de charge utile, SPS/PPS (`sprop-parameter-sets`).
  Sans SPS/PPS dans le SDP, ils sont pris dans le flux.
- Modes de paquets gérés : NAL simple, STAP-A, FU-A (packetization-mode 0 et 1).
- Perte de paquets : l'image abîmée est jetée, on reprend à l'image clé suivante.
- Compteurs à l'écran : paquets, perdus, images, jetées, images/s.

## Arborescence

- `android/` : appli Kotlin, une seule activité. Cœur RTP dans `app/src/main/java/.../rtp/` (pur Kotlin).
- `ios/RtpCore/` : cœur RTP en Swift Package, testable sur le Mac (`swift test`).
- `ios/App/` : appli SwiftUI ; `ios/project.yml` génère le projet Xcode (`xcodegen generate`).
- `tools/stream.sh` : source de test (mire ffmpeg -> RTP/UDP + SDP).
- `fixtures/` : 2 s de flux réel enregistré depuis ffmpeg, rejoué par les tests des deux plateformes.

Les deux cœurs ont la même structure (mêmes noms de classes) pour pouvoir les relire en parallèle.

## Lancer

Source de test (FFmpeg sert uniquement à émettre sur le poste de dev) :

```sh
tools/stream.sh <ip_du_téléphone> 5004          # SPS/PPS dans le SDP
INBAND=1 tools/stream.sh <ip_du_téléphone> 5004 # SPS/PPS dans le flux
```

Android :

```sh
cd android && ./gradlew testDebugUnitTest assembleDebug   # JDK 17 ou 21
adb install app/build/outputs/apk/debug/app-debug.apk
# Émulateur : rediriger l'UDP de l'hôte vers l'émulateur, puis émettre vers 127.0.0.1
adb emu redir add udp:5004:5004 && tools/stream.sh 127.0.0.1 5004
```

iOS :

```sh
cd ios/RtpCore && swift test
cd ios && xcodegen generate && open RtpPlayerDemo.xcodeproj   # signer avec l'équipe opcode, lancer sur iPhone
```

Le simulateur iOS partage le réseau du Mac : `tools/stream.sh 127.0.0.1 5004` suffit.
Sur un vrai iPhone, iOS demande l'autorisation « réseau local » au premier lancement.

## Préparer le multicast

L'entrée réseau passe par l'interface `RtpSource` ; `RtpSources.forSession()` choisit l'implémentation
selon la ligne `c=` du SDP (224.0.0.0/4 = multicast). Aujourd'hui le multicast lève une erreur explicite.
Pour l'ajouter :

- **Android** : `MulticastSocket(port).joinGroup(...)` + `WifiManager.MulticastLock` acquis pendant la
  lecture (permission `CHANGE_WIFI_MULTICAST_STATE`), sinon le Wi-Fi filtre les paquets.
- **iOS** : `setsockopt(IP_ADD_MEMBERSHIP)` sur la même socket POSIX, **et** l'entitlement
  `com.apple.developer.networking.multicast`, à demander à Apple (justification, délai, refus possible).
  À lancer tôt : c'est le chemin critique.
- Le Wi-Fi gère mal le multicast (débit bas, IGMP snooping) : tester sur le réseau réel du client.

## Limites connues (démonstrateur)

- Fenêtre de remise en ordre en nombre de paquets (32), pas en millisecondes.
- Pas de RTCP, pas de SRTP (le flux circule en clair sur le réseau : à réserver à un réseau privé).
- Pas d'audio, pas de packetization-mode 2 (STAP-B, MTAP, FU-B).
- Un seul flux à l'écran ; pas de gestion arrière-plan / changement de réseau.
