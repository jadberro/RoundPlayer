#!/bin/bash
# Push this checkout to the Pi and (optionally) rebuild / restart.
#
#   ./deploy.sh sync              rsync the repo to the Pi
#   ./deploy.sh install           sync + run install_pi.sh on the Pi (first-time setup, needs sudo there)
#   ./deploy.sh hud               sync + rebuild the Flutter HUD + restart it
#   ./deploy.sh restart           sync + restart the Python/Node services (no HUD rebuild)
#
# PI_HOST / PI_USER env vars override the defaults.
set -euo pipefail
PI_HOST="${PI_HOST:-roundplayer.local}"
PI_USER="${PI_USER:-pi}"
REMOTE_DIR="roundplayer"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-sync}"

sync() {
  echo ">>> rsync -> $PI_USER@$PI_HOST:~/$REMOTE_DIR"
  rsync -az --delete --info=stats1 \
    --exclude build/ --exclude .dart_tool/ --exclude node_modules/ --exclude __pycache__/ \
    --exclude .git/ --exclude .DS_Store --exclude '*.mp4' --exclude '*.wav' \
    "$HERE/" "$PI_USER@$PI_HOST:$REMOTE_DIR/"
}

case "$ACTION" in
  sync)    sync ;;
  install) sync; ssh -t "$PI_USER@$PI_HOST" "cd $REMOTE_DIR && sudo ./install_pi.sh" ;;
  hud)     sync; ssh "$PI_USER@$PI_HOST" "export PATH=\$HOME/flutter/bin:\$PATH; cd $REMOTE_DIR/round_hud_app && ./tools/vendor_media_kit_video.sh && flutter build linux --release --no-tree-shake-icons && systemctl --user restart round_hud.service; sleep 2; systemctl --user --no-pager status round_hud.service | head -5" ;;
  restart) sync; ssh "$PI_USER@$PI_HOST" "sudo systemctl restart roundplayer_daemon roundplayer_web roundplayer_dial && systemctl --no-pager status roundplayer_daemon roundplayer_web roundplayer_dial | grep -E 'service|Active'" ;;
  *) echo "usage: $0 sync|install|hud|restart"; exit 1 ;;
esac
