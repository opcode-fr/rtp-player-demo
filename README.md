# rtp-player-demo

Démonstrateur de lecteur **RTP/UDP H.264** pour **React Native (Expo)**, Android et iOS, sans VLC
ni FFmpeg embarqué : uniquement les API du système (sockets, MediaCodec, AVSampleBufferDisplayLayer /
VideoToolbox). Aucune dépendance d'exécution, donc aucune contrainte LGPL.

## Ce que ça fait

```
UDP (unicast) -> RTP (RFC 3550) -> remise en ordre -> H.264 (RFC 6184) -> décodeur matériel -> écran
```

- Toute la vidéo reste native : JavaScript ne voit passer ni paquet ni image.
- Le SDP du flux donne le port, le type de charge utile et les SPS/PPS (`sprop-parameter-sets`).
  Sans SPS/PPS dans le SDP, ils sont pris dans le flux.
- Modes de paquets gérés : NAL simple, STAP-A, FU-A (packetization-mode 0 et 1).
- Perte de paquets : l'image abîmée est jetée, on reprend à l'image clé suivante.

## Utilisation côté React Native

```tsx
import { RtpVideoView } from './modules/rtp-video';

<RtpVideoView
  style={{ width: '100%', aspectRatio: 16 / 9 }}
  sdp={sdpText}                 // SDP du serveur
  playing={true}                // false = arrêt ; changer le SDP redémarre la session
  onStats={(e) => console.log(e.nativeEvent)}   // { packets, lostPackets, frames, droppedFrames }, chaque seconde
  onError={(e) => console.warn(e.nativeEvent.message)}
/>
```

Le module est un **module Expo local** (Expo Modules API) : pour l'intégrer à l'appli du client, copier
`rn-demo/modules/rtp-video/` dans son dossier `modules/`, puis `npx expo prebuild` (ou `pod install`
dans une appli React Native sans Expo, avec le paquet `expo` installé). Il ne marche pas dans Expo Go :
il faut un « development build ».

Sur iOS, ajouter dans `app.json` la clé `ios.infoPlist.NSLocalNetworkUsageDescription` (déjà faite dans
la démo) : iOS demande l'autorisation « réseau local » au premier lancement.

## Arborescence

- `rn-demo/` : appli Expo de démonstration (SDP à coller, Lire/Arrêter, vidéo, compteurs).
- `rn-demo/modules/rtp-video/` : le module, **seule source** du code natif.
  - `android/.../core/` : cœur RTP + décodeur MediaCodec (pur Kotlin, sans Expo).
  - `ios/RtpCore/` : cœur RTP + rendu VideoToolbox (pur Swift, sans Expo) ; c'est aussi un Swift
    Package (`ios/Package.swift`) pour les tests sur Mac.
  - `RtpVideoModule` / `RtpVideoView` : la liaison Expo, sur chaque plateforme.
- `android/`, `ios/` : petites applis natives sans React Native qui compilent le même cœur. Elles
  servent de banc de test (tests unitaires Kotlin, débogage natif isolé).
- `tools/stream.sh` : source de test (mire ffmpeg -> RTP/UDP + SDP).
- `fixtures/` : 2 s de flux réel enregistré depuis ffmpeg, rejoué par les tests des deux plateformes.

## Lancer

Source de test (FFmpeg sert uniquement à émettre sur le poste de dev) :

```sh
tools/stream.sh <ip_du_téléphone> 5004          # SPS/PPS dans le SDP
INBAND=1 tools/stream.sh <ip_du_téléphone> 5004 # SPS/PPS dans le flux
```

Démo React Native :

```sh
cd rn-demo && npm install
npx expo run:android          # ou : npx expo run:ios --device
# Émulateur Android : rediriger l'UDP de l'hôte, puis émettre vers 127.0.0.1
adb emu redir add udp:5004:5004 && tools/stream.sh 127.0.0.1 5004
```

Tests du cœur :

```sh
cd rn-demo/modules/rtp-video/ios && swift test        # Swift, sur le Mac
cd android && ./gradlew testDebugUnitTest             # Kotlin (JDK 17 ou 21)
```

## Préparer le multicast

L'entrée réseau passe par l'interface `RtpSource` ; `RtpSources.forSession()` choisit l'implémentation
selon la ligne `c=` du SDP (224.0.0.0/4 = multicast). Aujourd'hui le multicast lève une erreur explicite
(remontée en `onError`). Pour l'ajouter :

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
- Pas de gestion arrière-plan / changement de réseau ; plusieurs vues = plusieurs ports.
