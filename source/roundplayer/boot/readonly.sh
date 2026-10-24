#!/bin/bash
# readonly.sh - opt-in read-only root (overlayfs) so a pulled plug can never corrupt the SD card.
#
#   sudo ./boot/readonly.sh status            what is protected, what is not, and why
#   sudo ./boot/readonly.sh move-data /dev/sdX1   move /data (library cache, settings, playlists, play log) to a
#                                             USB drive / partition that stays writable, then mount it via fstab
#   sudo ./boot/readonly.sh enable            turn the overlay on (refuses while /data still lives on the root fs)
#   sudo ./boot/readonly.sh disable           turn it off again (reboot to apply)
#
# With the overlay on, everything written to / is kept in RAM and thrown away at reboot. That is the point for the
# OS, but /data must survive, so it has to be its own filesystem first. On this box /data is a directory on the
# root partition, hence "enable" refuses until move-data has been run.
set -euo pipefail
cmd="${1:-status}"
data_dev="$(findmnt -no SOURCE /data 2>/dev/null || true)"
root_dev="$(findmnt -no SOURCE / 2>/dev/null || true)"
overlay_on="$(raspi-config nonint get_overlay_now 2>/dev/null || echo 1)"   # 0 = on

case "$cmd" in
  status)
    echo "root      : $root_dev"
    echo "/data     : ${data_dev:-(directory on the root filesystem)}"
    echo "overlay   : $([ "$overlay_on" = 0 ] && echo ON || echo off)"
    if [ -z "$data_dev" ] || [ "$data_dev" = "$root_dev" ]; then
      echo "verdict   : NOT SAFE to enable - /data would be wiped at every reboot. Run move-data first."
    else
      echo "verdict   : safe to enable"
    fi
    ;;
  move-data)
    dev="${2:?usage: readonly.sh move-data /dev/sdX1}"
    [ -b "$dev" ] || { echo "$dev is not a block device"; exit 1; }
    echo "This will FORMAT $dev as ext4 and move /data onto it. Ctrl-C within 10 s to abort."; sleep 10
    systemctl stop roundplayer_daemon roundplayer_web roundplayer_dial || true
    mkfs.ext4 -F -L rpdata "$dev"
    mkdir -p /mnt/rpdata && mount "$dev" /mnt/rpdata
    rsync -aHAX /data/ /mnt/rpdata/
    umount /mnt/rpdata
    mv /data /data.old && mkdir /data
    uuid="$(blkid -s UUID -o value "$dev")"
    grep -q "$uuid" /etc/fstab || echo "UUID=$uuid /data ext4 defaults,noatime,commit=30,nofail 0 2" >> /etc/fstab
    mount /data
    chown -R "${SUDO_USER:-bouncer}:${SUDO_USER:-bouncer}" /data
    systemctl start roundplayer_daemon roundplayer_web roundplayer_dial
    echo "moved. The old copy is in /data.old - delete it once everything works."
    ;;
  enable)
    if [ -z "$data_dev" ] || [ "$data_dev" = "$root_dev" ]; then
      echo "Refusing: /data lives on the root filesystem and would be lost at every reboot. Run move-data first."; exit 1
    fi
    raspi-config nonint enable_overlayfs
    echo "overlay enabled - reboot to apply"
    ;;
  disable)
    raspi-config nonint disable_overlayfs
    echo "overlay disabled - reboot to apply"
    ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
