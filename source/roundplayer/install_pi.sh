#!/bin/bash
# Round Media Player - one-shot installer for Raspberry Pi 4 (Raspberry Pi OS 64-bit, Bookworm or Trixie, desktop image)
#
#   sudo ./install_pi.sh                 full install (apt, pip, node, flutter, services, boot config)
#   sudo ./install_pi.sh --no-flutter    everything except the Flutter SDK / HUD build
#   sudo ./install_pi.sh --services-only just (re)write and restart the systemd units
#
# Idempotent: safe to re-run. Run it from the repo checkout, which must live at $HOME/roundplayer
# of the desktop user (the user that owns the labwc session), e.g. /home/bouncer/roundplayer.
set -euo pipefail

TARGET_USER="${TARGET_USER:-${SUDO_USER:-bouncer}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
APP_DIR="${APP_DIR:-$TARGET_HOME/roundplayer}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_CFG="/boot/firmware/config.txt"; [ -f "$BOOT_CFG" ] || BOOT_CFG="/boot/config.txt"
FLUTTER_DIR="${FLUTTER_DIR:-$TARGET_HOME/flutter}"
MODE="${1:-full}"

log() { echo -e "\e[1;36m[install]\e[0m $*"; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

if [ "$REPO_DIR" != "$APP_DIR" ]; then
  log "Repo is at $REPO_DIR, app dir is $APP_DIR -> syncing"
  mkdir -p "$APP_DIR"
  rsync -a --delete --exclude build/ --exclude .dart_tool/ --exclude node_modules/ --exclude __pycache__/ "$REPO_DIR/" "$APP_DIR/"
  chown -R "$TARGET_USER:$TARGET_USER" "$APP_DIR"
fi

# ---------------------------------------------------------------- packages ---
if [ "$MODE" != "--services-only" ]; then
  log "apt packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    python3-pip python3-numpy python3-aubio aubio-tools python3-pil python3-requests \
    ffmpeg alsa-utils pipewire pipewire-pulse pipewire-alsa wireplumber \
    libmpv2 libmpv-dev mpv \
    git curl unzip rsync ca-certificates avahi-daemon iptables gammastep python3-mutagen \
    clang cmake ninja-build pkg-config libgtk-3-dev libepoxy-dev libstdc++-12-dev 2>/dev/null || \
  apt-get install -y -qq \
    python3-pip python3-numpy python3-aubio aubio-tools python3-pil python3-requests \
    ffmpeg alsa-utils pipewire pipewire-pulse pipewire-alsa wireplumber \
    libmpv2 libmpv-dev mpv \
    git curl unzip rsync ca-certificates avahi-daemon iptables gammastep python3-mutagen \
    clang cmake ninja-build pkg-config libgtk-3-dev libepoxy-dev

  log "pip packages"
  sudo -u "$TARGET_USER" python3 -m pip install --quiet --break-system-packages --user \
    "fastapi" "uvicorn[standard]" "httpx" "yt-dlp" "ytmusicapi" "pydantic" "qrcode" "gdown" "websockets"

  # Node >= 20 (the cast receiver uses `import ... with { type: 'json' }`)
  NODE_MAJOR="$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0)"
  if [ "${NODE_MAJOR:-0}" -lt 20 ]; then
    log "Node.js 20 (NodeSource)"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
  fi
  log "yt-cast-receiver npm deps"
  sudo -u "$TARGET_USER" bash -c "cd '$APP_DIR/yt_receiver' && npm install --omit=dev --silent"
fi

# ------------------------------------------------------------- boot config ---
log "boot config ($BOOT_CFG)"
if ! grep -q "Round Media Player - Raspberry Pi 4 boot config fragment" "$BOOT_CFG"; then
  # Disable the stock audio line & stock kms line so ours win
  sed -i 's/^dtparam=audio=on/#dtparam=audio=on  # roundplayer: DAC Pro only/' "$BOOT_CFG"
  sed -i 's/^dtoverlay=vc4-kms-v3d$/#dtoverlay=vc4-kms-v3d  # roundplayer: see fragment below/' "$BOOT_CFG"
  printf "\n" >> "$BOOT_CFG"
  cat "$APP_DIR/pi/config-roundplayer.txt" >> "$BOOT_CFG"
  BOOT_CHANGED=1
fi

# ----------------------------------------------------------------- data dirs ---
log "data directories"
mkdir -p /data/roundplayer_cache /data/hifi_music/covers /data/hifi_cache /data/hifi_playlists /tmp/roundplayer_temp
chown -R "$TARGET_USER:$TARGET_USER" /data /tmp/roundplayer_temp

# yt-dlp from PyPI (the distro one goes stale and YouTube breaks it); streams need the [default] extras (EJS)
sudo -u "$TARGET_USER" python3 -m pip install -U --user --break-system-packages -q "yt-dlp[default]" || true

# ---------------------------------------------------------------- dacpro-ctl ---
log "dacpro-ctl"
install -m 0755 "$APP_DIR/dacpro-ctl" /usr/local/bin/dacpro-ctl
install -m 0755 "$APP_DIR/roundplayer-backup" /usr/local/bin/roundplayer-backup
install -m 0644 "$APP_DIR/services/91-dacpro.rules" /etc/udev/rules.d/91-dacpro.rules
udevadm control --reload 2>/dev/null || true
install -m 0755 "$APP_DIR/display-ctl" /usr/local/bin/display-ctl
# Reference defaults for the DAC Pro path: apodising filter, native-rate S32 output, no auto-mute, DAC does volume
[ -s /etc/dacpro.json ] || cat > /etc/dacpro.json <<'EOF2'
{"filter": "ringless", "auto-mute": "off", "pw-hires": "on", "pw-resample-quality": 14, "pw-dither": "none", "pw-keep-awake": "on"}
EOF2
cat > /etc/sudoers.d/roundplayer <<EOF
# playback_manager.py drives the DAC and restarts sibling services without a password
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/dacpro-ctl
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/roundplayer-backup
$TARGET_USER ALL=(root) NOPASSWD: /usr/sbin/iw reg set *, /usr/sbin/rfkill unblock wifi, /usr/sbin/iw * set power_save *
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/install -m0755 * /usr/local/bin/dacpro-ctl, /usr/bin/install -m0755 * /usr/local/bin/display-ctl, /usr/bin/install -m 0755 * /usr/local/bin/dacpro-ctl, /usr/bin/install -m 0755 * /usr/local/bin/display-ctl
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart roundplayer_dial roundplayer_web, /usr/bin/systemctl restart roundplayer_dial, /usr/bin/systemctl restart roundplayer_web, /usr/bin/systemctl restart roundplayer_daemon, /usr/bin/systemctl restart roundplayer_daemon roundplayer_web roundplayer_dial
EOF
chmod 0440 /etc/sudoers.d/roundplayer

# Disable Wi-Fi power saving on Raspberry Pi 4 to prevent dropouts
log "disabling Wi-Fi power save"
mkdir -p /etc/NetworkManager/conf.d
install -m 0644 "$APP_DIR/services/default-wifi-powersave-disable.conf" /etc/NetworkManager/conf.d/default-wifi-powersave-disable.conf

# Wi-Fi control from the HUD / web remote: let the daemon's user manage NetworkManager without a password
log "polkit rule for NetworkManager"
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-roundplayer-network.rules <<EOF
// Round Media Player: allow $TARGET_USER to scan / connect / modify Wi-Fi via nmcli (settings menu)
polkit.addRule(function(action, subject) {
  if (subject.user == "$TARGET_USER" && action.id.indexOf("org.freedesktop.NetworkManager.") == 0) {
    return polkit.Result.YES;
  }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/50-roundplayer-network.rules

# ------------------------------------------------------------------ services ---
log "systemd units"
for unit in roundplayer_daemon roundplayer_web roundplayer_dial dacpro; do
  sed "s#__USER__#$TARGET_USER#g; s#__HOME__#$TARGET_HOME#g" "$APP_DIR/services/$unit.service" > "/etc/systemd/system/$unit.service"
done
USER_UNIT_DIR="$TARGET_HOME/.config/systemd/user"
mkdir -p "$USER_UNIT_DIR"
sed "s#__USER__#$TARGET_USER#g; s#__HOME__#$TARGET_HOME#g" "$APP_DIR/services/round_hud.service" > "$USER_UNIT_DIR/round_hud.service"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/systemd"
loginctl enable-linger "$TARGET_USER"

# labwc autostart: hand the Wayland socket to the user systemd instance, then start the HUD
LABWC_DIR="$TARGET_HOME/.config/labwc"; mkdir -p "$LABWC_DIR"
AUTOSTART="$LABWC_DIR/autostart"; touch "$AUTOSTART"
if ! grep -q round_hud "$AUTOSTART"; then
  cat >> "$AUTOSTART" <<'EOF'
# roundplayer kiosk
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE
systemctl --user restart round_hud.service &
EOF
fi
chown -R "$TARGET_USER:$TARGET_USER" "$LABWC_DIR"

# port 80 -> 8080 so http://<host>.local works
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
cat > /etc/systemd/system/roundplayer_port80.service <<'EOF'
[Unit]
Description=Round Media Player - redirect :80 to the web remote on :8080
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dacpro roundplayer_daemon roundplayer_web roundplayer_dial roundplayer_port80 >/dev/null
systemctl restart roundplayer_daemon roundplayer_web roundplayer_dial || true

# Wi-Fi country -> unlocks the 5 GHz band on the Pi 4 radio (persisted by raspi-config; NetworkManager reads it)
if command -v raspi-config >/dev/null; then
  raspi-config nonint do_wifi_country "${WIFI_COUNTRY:-GB}" || true
fi
command -v iw >/dev/null && iw reg set "${WIFI_COUNTRY:-GB}" 2>/dev/null || true
rfkill unblock wifi 2>/dev/null || true
[ -s /data/roundplayer_wifi.json ] || echo '{"band": "5", "hotspot_band": "5"}' > /data/roundplayer_wifi.json
chown "$TARGET_USER:$TARGET_USER" /data/roundplayer_wifi.json

# desktop autologin + no blanking (kiosk)
if command -v raspi-config >/dev/null; then
  raspi-config nonint do_boot_behaviour B4 || true
  raspi-config nonint do_blanking 1 || true
fi

# ------------------------------------------------------------------- flutter ---
if [ "$MODE" = "full" ]; then
  if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
    log "Flutter SDK (stable, arm64 via git) -> $FLUTTER_DIR"
    sudo -u "$TARGET_USER" git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
  fi
  grep -q 'flutter/bin' "$TARGET_HOME/.profile" || echo 'export PATH="$HOME/flutter/bin:$PATH"' >> "$TARGET_HOME/.profile"
  log "Building the Round HUD (first build pulls the Dart SDK + engine, ~10-20 min on a Pi 4)"
  sudo -u "$TARGET_USER" bash -c "export PATH='$FLUTTER_DIR/bin:\$PATH'; cd '$APP_DIR/round_hud_app' && flutter config --enable-linux-desktop >/dev/null && ./tools/vendor_media_kit_video.sh && flutter pub get && flutter build linux --release --no-tree-shake-icons"
fi

log "done."
echo
echo "  DAC check : aplay -l            (expect snd_rpi_hifiberry_dacplus)"
echo "  Mixer     : dacpro-ctl show"
echo "  Services  : systemctl status roundplayer_daemon roundplayer_web roundplayer_dial"
echo "  HUD       : systemctl --user status round_hud   (starts with the desktop session)"
echo "  Remote    : http://$(hostname).local/"
if [ "${BOOT_CHANGED:-0}" = 1 ]; then echo; echo "  >>> config.txt changed - reboot to bring up the DAC Pro and KMS display."; fi
