#!/bin/bash
# Round Player boot look: black everywhere, custom Plymouth splash, no rainbow square, no kernel chatter,
# black desktop under the kiosk. Run as root from the roundplayer dir:  sudo ./boot/install_boot_theme.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-bouncer}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

# 1. Plymouth theme
install -d /usr/share/plymouth/themes/roundplayer
install -m0644 "$HERE"/plymouth-roundplayer/* /usr/share/plymouth/themes/roundplayer/
plymouth-set-default-theme roundplayer
# make sure the theme is in the initramfs so it shows from the very first frame
if command -v update-initramfs >/dev/null; then update-initramfs -u >/dev/null 2>&1 || true; fi

# 2. Firmware: no rainbow splash; kernel: quiet, no cursor, no logo, no console blanking
CFG=/boot/firmware/config.txt; CMD=/boot/firmware/cmdline.txt
grep -q '^disable_splash=1' $CFG || sed -i '/^\[all\]/a disable_splash=1' $CFG
line="$(cat $CMD)"
for opt in "loglevel=0" "logo.nologo" "vt.global_cursor_blink=0" "consoleblank=0" "plymouth.ignore-serial-consoles" "quiet" "splash"; do
  case " $line " in *" $opt "*) ;; *) line="$line $opt";; esac
done
printf '%s\n' "$line" > $CMD

# 3. Greeter (autologin flashes it for a moment): black, no wallpaper
GR=/etc/lightdm/pi-greeter.conf
sed -i 's/^desktop_bg=.*/desktop_bg=#000000000000/; s/^wallpaper=.*/wallpaper=/; s/^wallpaper_mode=.*/wallpaper_mode=color/' $GR

# 4. Desktop under the kiosk (pcmanfm draws it): plain black, no icons
PC="$USER_HOME/.config/pcmanfm/default"
install -d -o "$USER_NAME" -g "$USER_NAME" "$PC"
cat > "$PC/desktop-items-0.conf" <<'CONF'
[*]
wallpaper_mode=color
wallpaper_common=1
wallpaper=
desktop_bg=#000000
desktop_fg=#000000
desktop_shadow=#000000
show_wm_menu=0
show_documents=0
show_trash=0
show_mounts=0
CONF
chown "$USER_NAME:$USER_NAME" "$PC/desktop-items-0.conf"

echo "boot theme installed: plymouth=$(plymouth-set-default-theme)  cmdline: $(cat $CMD)"
