#!/usr/bin/env bash
# Source de test : mire H.264 envoyée en RTP/UDP unicast, comme le serveur du client.
# Écrit le SDP correspondant dans tools/stream.sdp.
#
#   tools/stream.sh [ip_destination] [port]      (défaut : 127.0.0.1 5004)
#   INBAND=1 tools/stream.sh ...                 SPS/PPS dans le flux au lieu du SDP
#
# FFmpeg ne sert qu'à émettre sur le poste de dev ; il n'est jamais embarqué dans les applis.
set -euo pipefail

DEST=${1:-127.0.0.1}
PORT=${2:-5004}
FFMPEG=${FFMPEG:-ffmpeg}
HERE=$(cd "$(dirname "$0")" && pwd)

# SPS/PPS dans le SDP (sprop-parameter-sets) ; avec INBAND=1, répétés dans le flux et SDP sans sprop.
HEADER_FLAGS="+global_header"
[[ "${INBAND:-0}" == 1 ]] && HEADER_FLAGS="-global_header"

exec "$FFMPEG" -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc2=size=1280x720:rate=25" \
  -c:v libx264 -profile:v baseline -tune zerolatency -preset veryfast \
  -g 50 -bf 0 -pix_fmt yuv420p -flags "$HEADER_FLAGS" -an \
  -f rtp -sdp_file "$HERE/stream.sdp" "rtp://$DEST:$PORT?pkt_size=1200"
