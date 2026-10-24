#!/bin/bash
# AirPlay + Spotify Connect receivers as user services feeding PipeWire (so EQ/DAC settings apply), plus the
# bs2b crossfeed LADSPA plugin and MQTT client. Run as the player user:  ./install_sources.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
sudo apt-get install -y shairport-sync python3-paho-mqtt curl >/dev/null
# shairport: Debian's system service runs as its own user and cannot reach our PipeWire; use a user unit
sudo systemctl disable --now shairport-sync.service 2>/dev/null || true
mkdir -p ~/.config/systemd/user ~/.config
cp "$HERE/sources/shairport-sync.conf" ~/.config/shairport-sync.conf
cp "$HERE/services/shairport-sync.service" "$HERE/services/airplay-meta.service" "$HERE/services/librespot.service" ~/.config/systemd/user/
# librespot via the raspotify package (prebuilt for the Pi); we run our own user unit with the pulse backend
if ! command -v librespot >/dev/null; then
  curl -sL https://dtcooper.github.io/raspotify/install.sh | sh || echo "raspotify install failed - Spotify Connect unavailable"
fi
sudo systemctl disable --now raspotify.service 2>/dev/null || true
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
systemctl --user enable --now shairport-sync.service airplay-meta.service
if command -v librespot >/dev/null; then systemctl --user enable --now librespot.service; fi
echo "sources installed: $(systemctl --user is-active shairport-sync airplay-meta librespot 2>/dev/null | tr '\n' ' ')"
