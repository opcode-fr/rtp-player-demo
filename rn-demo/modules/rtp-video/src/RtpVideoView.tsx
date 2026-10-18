import { requireNativeView } from 'expo';
import * as React from 'react';

import { RtpVideoViewProps } from './RtpVideo.types';

const NativeView: React.ComponentType<RtpVideoViewProps> = requireNativeView('RtpVideo');

export default function RtpVideoView(props: RtpVideoViewProps) {
  return <NativeView {...props} />;
}
