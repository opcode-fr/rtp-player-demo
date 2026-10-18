import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { Button, SafeAreaView, StyleSheet, Text, TextInput, View } from 'react-native';

import { RtpStats, RtpVideoView } from './modules/rtp-video';

/** Les SDP produits par tools/stream.sh (unicast vers 127.0.0.1, ou multicast 239.255.42.42). */
const sdpFor = (address: string) => `v=0
o=- 0 0 IN IP4 127.0.0.1
s=No Name
c=IN IP4 ${address}
t=0 0
m=video 5004 RTP/AVP 96
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1; sprop-parameter-sets=Z0LAH9oBQBbsBEAAAAMAQAAADKPGDKg=,aM4PyA==; profile-level-id=42C01F`;
const DEFAULT_SDP = sdpFor('127.0.0.1');
const MULTICAST_SDP = sdpFor('239.255.42.42/1');

export default function App() {
  const [sdp, setSdp] = useState(DEFAULT_SDP);
  const [playing, setPlaying] = useState(false);
  const [stats, setStats] = useState<RtpStats | null>(null);
  const [fps, setFps] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const onStats = (s: RtpStats) => {
    setFps(stats ? s.frames - stats.frames : 0);
    setStats(s);
  };

  const toggle = () => {
    setError(null);
    setStats(null);
    setPlaying((p) => !p);
  };

  return (
    <SafeAreaView style={styles.container}>
      <RtpVideoView
        style={styles.video}
        sdp={sdp}
        playing={playing}
        onStats={(e) => onStats(e.nativeEvent)}
        onError={(e) => {
          setError(e.nativeEvent.message);
          setPlaying(false);
        }}
      />
      <Text style={styles.stats}>
        {error
          ? `Erreur : ${error}`
          : stats
            ? `paquets ${stats.packets} · perdus ${stats.lostPackets} · images ${stats.frames} · jetées ${stats.droppedFrames} · ${fps} img/s`
            : playing
              ? 'En attente du flux…'
              : 'Arrêté'}
      </Text>
      <View style={styles.button}>
        <Button title={playing ? 'Arrêter' : 'Lire'} onPress={toggle} />
      </View>
      <View style={styles.presets}>
        <Button title="SDP unicast" onPress={() => setSdp(DEFAULT_SDP)} disabled={playing} />
        <Button title="SDP multicast" onPress={() => setSdp(MULTICAST_SDP)} disabled={playing} />
      </View>
      <Text style={styles.label}>SDP du flux</Text>
      <TextInput
        style={styles.sdp}
        value={sdp}
        onChangeText={setSdp}
        multiline
        autoCapitalize="none"
        autoCorrect={false}
      />
      <StatusBar style="auto" />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff', paddingTop: 48 },
  video: { width: '100%', aspectRatio: 16 / 9, backgroundColor: '#000' },
  stats: { padding: 12, fontVariant: ['tabular-nums'] },
  button: { marginHorizontal: 12 },
  presets: { flexDirection: 'row', justifyContent: 'space-around', marginTop: 8 },
  label: { marginHorizontal: 12, marginTop: 16, color: '#666', fontSize: 12 },
  sdp: {
    flex: 1,
    margin: 12,
    padding: 8,
    borderWidth: 1,
    borderColor: '#ccc',
    fontFamily: 'monospace',
    fontSize: 11,
    textAlignVertical: 'top',
  },
});
