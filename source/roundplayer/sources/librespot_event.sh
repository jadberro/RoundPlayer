#!/bin/bash
# librespot --onevent hook: translate player events into daemon calls. Env: PLAYER_EVENT, NAME, ARTISTS, ALBUM,
# DURATION_MS, POSITION_MS, COVERS (newline-separated URLs, largest first), TRACK_ID.
API=http://127.0.0.1:8000
post() { curl -s -m 3 -X POST "$API$1" -H 'Content-Type: application/json' -d "$2" >/dev/null 2>&1; }
meta() {
  local cover; cover="$(printf '%s' "${COVERS:-}" | head -1)"
  local dur=$(( ${DURATION_MS:-0} / 1000 )) pos=$(( ${POSITION_MS:-0} / 1000 ))
  printf '{"title":%s,"artist":%s,"album":%s,"duration_s":%s,"position_s":%s,"cover_url":%s,"playing":%s}' \
    "$(printf '%s' "${NAME:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "${ARTISTS:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().replace("\n", ", ")))')" \
    "$(printf '%s' "${ALBUM:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$dur" "$pos" "$(printf '%s' "$cover" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" "$1"
}
case "${PLAYER_EVENT:-}" in
  session_connected|session_client_changed) post /api/source/spotify/start "{\"device\":\"${CLIENT_NAME:-Spotify}\"}" ;;
  playing|track_changed) post /api/source/spotify/start '{}'; post /api/source/spotify/meta "$(meta true)" ;;
  paused) post /api/source/spotify/meta "$(meta false)" ;;
  seeked|position_correction) post /api/source/spotify/meta "{\"position_s\":$(( ${POSITION_MS:-0} / 1000 )),\"playing\":true}" ;;
  stopped|session_disconnected|end_of_track) [ "${PLAYER_EVENT}" = end_of_track ] || post /api/source/spotify/stop '{}' ;;
esac
