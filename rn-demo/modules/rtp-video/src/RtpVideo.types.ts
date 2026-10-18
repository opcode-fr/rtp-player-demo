import type { StyleProp, ViewStyle } from 'react-native';

export type RtpStats = {
  packets: number;
  lostPackets: number;
  frames: number;
  droppedFrames: number;
};

export type RtpVideoViewProps = {
  /** SDP du flux (port, type de charge utile, SPS/PPS). Unicast ; multicast pas encore géré. */
  sdp: string;
  /** Lecture en cours. Changer `sdp` pendant la lecture redémarre la session. */
  playing: boolean;
  /** Compteurs cumulés, envoyés chaque seconde pendant la lecture. */
  onStats?: (event: { nativeEvent: RtpStats }) => void;
  onError?: (event: { nativeEvent: { message: string } }) => void;
  style?: StyleProp<ViewStyle>;
};
