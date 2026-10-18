#!/usr/bin/env bash
# Source de test : mire H.264 envoyée en RTP/UDP unicast ou multicast, comme le serveur du client.
# Écrit le SDP correspondant dans tools/stream.sdp.
#
#   tools/stream.sh [ip_destination] [port]      (défaut : 127.0.0.1 5004)
#   INBAND=1 tools/stream.sh ...                 SPS/PPS dans le flux au lieu du SDP
#   tools/stream.sh 239.255.42.42 5004           multicast (TTL=1 par défaut ; TTL=0 : reste sur la machine)
#
# FFmpeg ne sert qu'à émettre sur le poste de dev ; il n'est jamais embarqué dans les applis.
set -euo pipefail

DEST=${1:-127.0.0.1}
PORT=${2:-5004}
FFMPEG=${FFMPEG:-ffmpeg}
HERE=$(cd "$(dirname "$0")" && pwd)
URL="rtp://$DEST:$PORT?pkt_size=1200"
FIRST_OCTET=${DEST%%.*}
if (( FIRST_OCTET >= 224 && FIRST_OCTET <= 239 )); then
  URL="$URL&ttl=${TTL:-1}"
fi

# SPS/PPS dans le SDP (sprop-parameter-sets) ; avec INBAND=1, répétés dans le flux et SDP sans sprop.
HEADER_FLAGS="+global_header"
[[ "${INBAND:-0}" == 1 ]] && HEADER_FLAGS="-global_header"

exec "$FFMPEG" -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc2=size=1280x720:rate=25" \
  -c:v libx264 -profile:v baseline -tune zerolatency -preset veryfast \
  -g 50 -bf 0 -pix_fmt yuv420p -flags "$HEADER_FLAGS" -an \
  -f rtp -sdp_file "$HERE/stream.sdp" "$URL"
